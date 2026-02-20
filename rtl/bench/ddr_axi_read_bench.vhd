LIBRARY ieee;

USE ieee.numeric_std.ALL;
USE ieee.std_logic_1164.ALL;

ENTITY ddr_axi_read_bench IS
    GENERIC (
        BURST_BEATS_G : POSITIVE := 64;
        START_ADDR_G : STD_LOGIC_VECTOR(31 DOWNTO 0) := x"10000000";
        TOTAL_BYTES_G : POSITIVE := 64 * 1024 * 1024;
        CLK_FREQ_HZ_G : POSITIVE := 81000000;
        UART_BAUD_G : POSITIVE := 115200;
        AUTO_REPEAT_G : BOOLEAN := FALSE;
        REPEAT_PAUSE_CYCLES_G : NATURAL := 10000000
    );
    PORT (
        clk : IN STD_LOGIC;
        rstn : IN STD_LOGIC;
        init_calib_complete : IN STD_LOGIC;
        -- Write Address Channel (unused) --
        m_axi_awaddr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_awlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_awsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_awcache : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_awprot : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_awvalid : OUT STD_LOGIC;
        m_axi_awready : IN STD_LOGIC;
        -- Write Data Channel (unused) --
        m_axi_wdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_wstrb : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_wlast : OUT STD_LOGIC;
        m_axi_wvalid : OUT STD_LOGIC;
        m_axi_wready : IN STD_LOGIC;
        -- Read Address Channel --
        m_axi_araddr : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_arlen : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
        m_axi_arsize : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arburst : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_arcache : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        m_axi_arprot : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
        m_axi_arvalid : OUT STD_LOGIC;
        m_axi_arready : IN STD_LOGIC;
        -- Read Data Channel --
        m_axi_rdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
        m_axi_rresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_rlast : IN STD_LOGIC;
        m_axi_rvalid : IN STD_LOGIC;
        m_axi_rready : OUT STD_LOGIC;
        -- Write Response Channel --
        m_axi_bresp : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
        m_axi_bvalid : IN STD_LOGIC;
        m_axi_bready : OUT STD_LOGIC;
        -- Legacy FIFO pins (unused in benchmark mode) --
        pxl_data : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        wr_en : OUT STD_LOGIC;
        almost_full : IN STD_LOGIC;
        full : IN STD_LOGIC;
        -- UART benchmark output --
        uart_txd_o : OUT STD_LOGIC
    );
END ddr_axi_read_bench;

ARCHITECTURE rtl OF ddr_axi_read_bench IS

    COMPONENT uart_tx_own IS
        GENERIC (
            g_CLKS_PER_BIT : INTEGER := 868
        );
        PORT (
            clk : IN STD_LOGIC;
            rst : IN STD_LOGIC;
            i_start : IN STD_LOGIC;
            i_byte : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
            o_serial : OUT STD_LOGIC;
            o_done : OUT STD_LOGIC
        );
    END COMPONENT;

    CONSTANT AXI_BEAT_BYTES_C : POSITIVE := 4;
    CONSTANT BURST_BYTES_C : POSITIVE := BURST_BEATS_G * AXI_BEAT_BYTES_C;
    CONSTANT TOTAL_BURSTS_C : POSITIVE := TOTAL_BYTES_G / BURST_BYTES_C;
    CONSTANT ARLEN_C : STD_LOGIC_VECTOR(7 DOWNTO 0) :=
        STD_LOGIC_VECTOR(to_unsigned(BURST_BEATS_G - 1, 8));
    CONSTANT UART_CLKS_PER_BIT_C : POSITIVE := CLK_FREQ_HZ_G / UART_BAUD_G;
    CONSTANT CLK_FREQ_HEX_C : unsigned(31 DOWNTO 0) := to_unsigned(CLK_FREQ_HZ_G, 32);

    TYPE bench_state_t IS (WAIT_CALIB, RUN_PREP, SEND_AR, READ_BURST, BENCH_DONE, REPEAT_WAIT);
    TYPE tx_state_t IS (
        TX_IDLE,
        TX_HDR, TX_HDR_CR, TX_HDR_LF,
        TX_BYTES_LABEL, TX_BYTES_HEX, TX_BYTES_CR, TX_BYTES_LF,
        TX_CYC_LABEL, TX_CYC_HEX, TX_CYC_CR, TX_CYC_LF,
        TX_CLK_LABEL, TX_CLK_HEX, TX_CLK_CR, TX_CLK_LF,
        TX_NOTE, TX_NOTE_CR, TX_NOTE_LF,
        TX_DONE
    );

    CONSTANT MSG_HDR_C : STRING := "DDR AXI READ BENCH";
    CONSTANT MSG_BYTES_C : STRING := "bytes=0x";
    CONSTANT MSG_CYCLES_C : STRING := "cycles=0x";
    CONSTANT MSG_CLK_C : STRING := "clk_hz=0x";
    CONSTANT MSG_NOTE_C : STRING := "MBps=bytes*clk/(cycles*1048576)";

    SIGNAL bench_state : bench_state_t := WAIT_CALIB;
    SIGNAL read_addr : unsigned(31 DOWNTO 0) := unsigned(START_ADDR_G);
    SIGNAL beat_idx : INTEGER RANGE 0 TO BURST_BEATS_G - 1 := 0;
    SIGNAL burst_idx : INTEGER RANGE 0 TO TOTAL_BURSTS_C - 1 := 0;
    SIGNAL cycle_count : unsigned(63 DOWNTO 0) := (OTHERS => '0');
    SIGNAL byte_count : unsigned(63 DOWNTO 0) := (OTHERS => '0');
    SIGNAL latched_cycles : unsigned(63 DOWNTO 0) := (OTHERS => '0');
    SIGNAL latched_bytes : unsigned(63 DOWNTO 0) := (OTHERS => '0');
    SIGNAL run_active : STD_LOGIC := '0';
    SIGNAL repeat_count : NATURAL RANGE 0 TO REPEAT_PAUSE_CYCLES_G := 0;
    SIGNAL tx_start_pulse : STD_LOGIC := '0';

    SIGNAL tx_state : tx_state_t := TX_IDLE;
    SIGNAL tx_char_idx : INTEGER RANGE 0 TO 64 := 0;
    SIGNAL tx_hex_idx : INTEGER RANGE 0 TO 15 := 0;
    SIGNAL uart_start : STD_LOGIC := '0';
    SIGNAL uart_done : STD_LOGIC;
    SIGNAL uart_busy : STD_LOGIC := '0';
    SIGNAL uart_byte : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');

    FUNCTION is_pow2(value : POSITIVE) RETURN BOOLEAN IS
        VARIABLE value_u : unsigned(31 DOWNTO 0);
    BEGIN
        value_u := to_unsigned(value, value_u'length);
        RETURN (value_u /= 0) AND ((value_u AND (value_u - 1)) = 0);
    END FUNCTION;

    FUNCTION char_to_slv(c : CHARACTER) RETURN STD_LOGIC_VECTOR IS
    BEGIN
        RETURN STD_LOGIC_VECTOR(to_unsigned(CHARACTER'pos(c), 8));
    END FUNCTION;

    FUNCTION nibble_to_ascii(nib : unsigned(3 DOWNTO 0)) RETURN STD_LOGIC_VECTOR IS
        VARIABLE nib_i : INTEGER RANGE 0 TO 15;
    BEGIN
        nib_i := to_integer(nib);
        IF nib_i < 10 THEN
            RETURN STD_LOGIC_VECTOR(to_unsigned(CHARACTER'pos('0') + nib_i, 8));
        ELSE
            RETURN STD_LOGIC_VECTOR(to_unsigned(CHARACTER'pos('A') + (nib_i - 10), 8));
        END IF;
    END FUNCTION;

    FUNCTION hex_nibble_64(data : unsigned(63 DOWNTO 0); idx : NATURAL) RETURN unsigned IS
        VARIABLE shifted : unsigned(63 DOWNTO 0);
    BEGIN
        shifted := shift_right(data, (15 - idx) * 4);
        RETURN shifted(3 DOWNTO 0);
    END FUNCTION;

    FUNCTION hex_nibble_32(data : unsigned(31 DOWNTO 0); idx : NATURAL) RETURN unsigned IS
        VARIABLE shifted : unsigned(31 DOWNTO 0);
    BEGIN
        shifted := shift_right(data, (7 - idx) * 4);
        RETURN shifted(3 DOWNTO 0);
    END FUNCTION;

BEGIN

    ASSERT BURST_BEATS_G <= 256
        REPORT "BURST_BEATS_G must be <= 256"
        SEVERITY failure;

    ASSERT is_pow2(BURST_BEATS_G)
        REPORT "BURST_BEATS_G must be a power of two"
        SEVERITY failure;

    ASSERT TOTAL_BYTES_G >= BURST_BYTES_C
        REPORT "TOTAL_BYTES_G must be >= burst size"
        SEVERITY failure;

    ASSERT TOTAL_BYTES_G MOD BURST_BYTES_C = 0
        REPORT "TOTAL_BYTES_G must be divisible by BURST_BYTES_G*4"
        SEVERITY failure;

    ASSERT to_integer(unsigned(START_ADDR_G(11 DOWNTO 0))) MOD BURST_BYTES_C = 0
        REPORT "START_ADDR_G must be burst-size aligned"
        SEVERITY failure;

    ASSERT UART_CLKS_PER_BIT_C >= 4
        REPORT "CLK/UART baud ratio too small"
        SEVERITY failure;

    -- Write channels are unused.
    m_axi_awaddr <= (OTHERS => '0');
    m_axi_awlen <= (OTHERS => '0');
    m_axi_awsize <= (OTHERS => '0');
    m_axi_awburst <= (OTHERS => '0');
    m_axi_awcache <= (OTHERS => '0');
    m_axi_awprot <= (OTHERS => '0');
    m_axi_awvalid <= '0';
    m_axi_wdata <= (OTHERS => '0');
    m_axi_wstrb <= (OTHERS => '0');
    m_axi_wlast <= '0';
    m_axi_wvalid <= '0';
    m_axi_bready <= '1';

    -- Read channels.
    m_axi_araddr <= STD_LOGIC_VECTOR(read_addr);
    m_axi_arlen <= ARLEN_C;
    m_axi_arsize <= "010"; -- 4 bytes/beat
    m_axi_arburst <= "01"; -- INCR
    m_axi_arcache <= "0011";
    m_axi_arprot <= "000";
    m_axi_arvalid <= '1' WHEN bench_state = SEND_AR ELSE
        '0';
    m_axi_rready <= '1' WHEN bench_state = READ_BURST ELSE
        '0';

    -- Keep legacy FIFO outputs quiet.
    pxl_data <= (OTHERS => '0');
    wr_en <= '0';

    -- AXI benchmark state machine.
    PROCESS (clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                bench_state <= WAIT_CALIB;
                read_addr <= unsigned(START_ADDR_G);
                beat_idx <= 0;
                burst_idx <= 0;
                cycle_count <= (OTHERS => '0');
                byte_count <= (OTHERS => '0');
                latched_cycles <= (OTHERS => '0');
                latched_bytes <= (OTHERS => '0');
                run_active <= '0';
                repeat_count <= 0;
                tx_start_pulse <= '0';
            ELSE
                tx_start_pulse <= '0';

                IF run_active = '1' THEN
                    cycle_count <= cycle_count + 1;
                END IF;

                CASE bench_state IS
                    WHEN WAIT_CALIB =>
                        IF init_calib_complete = '1' THEN
                            bench_state <= RUN_PREP;
                        END IF;

                    WHEN RUN_PREP =>
                        read_addr <= unsigned(START_ADDR_G);
                        beat_idx <= 0;
                        burst_idx <= 0;
                        cycle_count <= (OTHERS => '0');
                        byte_count <= (OTHERS => '0');
                        run_active <= '1';
                        bench_state <= SEND_AR;

                    WHEN SEND_AR =>
                        IF m_axi_arready = '1' THEN
                            bench_state <= READ_BURST;
                        END IF;

                    WHEN READ_BURST =>
                        IF (m_axi_rvalid = '1') THEN
                            ASSERT m_axi_rresp = "00"
                                REPORT "AXI read response error"
                                SEVERITY warning;

                            byte_count <= byte_count + AXI_BEAT_BYTES_C;

                            IF beat_idx = BURST_BEATS_G - 1 THEN
                                ASSERT m_axi_rlast = '1'
                                    REPORT "Expected RLAST on final beat"
                                    SEVERITY warning;

                                IF burst_idx = TOTAL_BURSTS_C - 1 THEN
                                    run_active <= '0';
                                    latched_bytes <= byte_count + AXI_BEAT_BYTES_C;
                                    latched_cycles <= cycle_count + 1;
                                    tx_start_pulse <= '1';
                                    bench_state <= BENCH_DONE;
                                ELSE
                                    beat_idx <= 0;
                                    burst_idx <= burst_idx + 1;
                                    read_addr <= read_addr + BURST_BYTES_C;
                                    bench_state <= SEND_AR;
                                END IF;
                            ELSE
                                ASSERT m_axi_rlast = '0'
                                    REPORT "RLAST arrived before final beat"
                                    SEVERITY warning;
                                beat_idx <= beat_idx + 1;
                            END IF;
                        END IF;

                    WHEN BENCH_DONE =>
                        IF AUTO_REPEAT_G THEN
                            repeat_count <= 0;
                            bench_state <= REPEAT_WAIT;
                        END IF;

                    WHEN REPEAT_WAIT =>
                        IF repeat_count = REPEAT_PAUSE_CYCLES_G THEN
                            bench_state <= RUN_PREP;
                        ELSE
                            repeat_count <= repeat_count + 1;
                        END IF;
                END CASE;
            END IF;
        END IF;
    END PROCESS;

    -- UART formatter and transmitter.
    PROCESS (clk)
        VARIABLE nib : unsigned(3 DOWNTO 0);
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                tx_state <= TX_IDLE;
                tx_char_idx <= 0;
                tx_hex_idx <= 0;
                uart_start <= '0';
                uart_busy <= '0';
                uart_byte <= (OTHERS => '0');
            ELSE
                uart_start <= '0';

                IF uart_done = '1' THEN
                    uart_busy <= '0';
                END IF;

                CASE tx_state IS
                    WHEN TX_IDLE =>
                        IF tx_start_pulse = '1' THEN
                            tx_state <= TX_HDR;
                            tx_char_idx <= MSG_HDR_C'low;
                        END IF;

                    WHEN TX_HDR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= char_to_slv(MSG_HDR_C(tx_char_idx));
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_char_idx = MSG_HDR_C'high THEN
                                tx_state <= TX_HDR_CR;
                            ELSE
                                tx_char_idx <= tx_char_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_HDR_CR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0D";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_HDR_LF;
                        END IF;

                    WHEN TX_HDR_LF =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0A";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_BYTES_LABEL;
                            tx_char_idx <= MSG_BYTES_C'low;
                        END IF;

                    WHEN TX_BYTES_LABEL =>
                        IF uart_busy = '0' THEN
                            uart_byte <= char_to_slv(MSG_BYTES_C(tx_char_idx));
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_char_idx = MSG_BYTES_C'high THEN
                                tx_state <= TX_BYTES_HEX;
                                tx_hex_idx <= 0;
                            ELSE
                                tx_char_idx <= tx_char_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_BYTES_HEX =>
                        IF uart_busy = '0' THEN
                            nib := hex_nibble_64(latched_bytes, tx_hex_idx);
                            uart_byte <= nibble_to_ascii(nib);
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_hex_idx = 15 THEN
                                tx_state <= TX_BYTES_CR;
                            ELSE
                                tx_hex_idx <= tx_hex_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_BYTES_CR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0D";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_BYTES_LF;
                        END IF;

                    WHEN TX_BYTES_LF =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0A";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_CYC_LABEL;
                            tx_char_idx <= MSG_CYCLES_C'low;
                        END IF;

                    WHEN TX_CYC_LABEL =>
                        IF uart_busy = '0' THEN
                            uart_byte <= char_to_slv(MSG_CYCLES_C(tx_char_idx));
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_char_idx = MSG_CYCLES_C'high THEN
                                tx_state <= TX_CYC_HEX;
                                tx_hex_idx <= 0;
                            ELSE
                                tx_char_idx <= tx_char_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_CYC_HEX =>
                        IF uart_busy = '0' THEN
                            nib := hex_nibble_64(latched_cycles, tx_hex_idx);
                            uart_byte <= nibble_to_ascii(nib);
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_hex_idx = 15 THEN
                                tx_state <= TX_CYC_CR;
                            ELSE
                                tx_hex_idx <= tx_hex_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_CYC_CR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0D";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_CYC_LF;
                        END IF;

                    WHEN TX_CYC_LF =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0A";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_CLK_LABEL;
                            tx_char_idx <= MSG_CLK_C'low;
                        END IF;

                    WHEN TX_CLK_LABEL =>
                        IF uart_busy = '0' THEN
                            uart_byte <= char_to_slv(MSG_CLK_C(tx_char_idx));
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_char_idx = MSG_CLK_C'high THEN
                                tx_state <= TX_CLK_HEX;
                                tx_hex_idx <= 0;
                            ELSE
                                tx_char_idx <= tx_char_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_CLK_HEX =>
                        IF uart_busy = '0' THEN
                            nib := hex_nibble_32(CLK_FREQ_HEX_C, tx_hex_idx);
                            uart_byte <= nibble_to_ascii(nib);
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_hex_idx = 7 THEN
                                tx_state <= TX_CLK_CR;
                            ELSE
                                tx_hex_idx <= tx_hex_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_CLK_CR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0D";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_CLK_LF;
                        END IF;

                    WHEN TX_CLK_LF =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0A";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_NOTE;
                            tx_char_idx <= MSG_NOTE_C'low;
                        END IF;

                    WHEN TX_NOTE =>
                        IF uart_busy = '0' THEN
                            uart_byte <= char_to_slv(MSG_NOTE_C(tx_char_idx));
                            uart_start <= '1';
                            uart_busy <= '1';
                            IF tx_char_idx = MSG_NOTE_C'high THEN
                                tx_state <= TX_NOTE_CR;
                            ELSE
                                tx_char_idx <= tx_char_idx + 1;
                            END IF;
                        END IF;

                    WHEN TX_NOTE_CR =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0D";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_NOTE_LF;
                        END IF;

                    WHEN TX_NOTE_LF =>
                        IF uart_busy = '0' THEN
                            uart_byte <= x"0A";
                            uart_start <= '1';
                            uart_busy <= '1';
                            tx_state <= TX_DONE;
                        END IF;

                    WHEN TX_DONE =>
                        IF AUTO_REPEAT_G = FALSE THEN
                            tx_state <= TX_DONE;
                        ELSE
                            tx_state <= TX_IDLE;
                        END IF;
                END CASE;
            END IF;
        END IF;
    END PROCESS;

    uart_tx_i : uart_tx_own
    GENERIC MAP(
        g_CLKS_PER_BIT => UART_CLKS_PER_BIT_C
    )
    PORT MAP(
        clk => clk,
        rst => NOT rstn,
        i_start => uart_start,
        i_byte => uart_byte,
        o_serial => uart_txd_o,
        o_done => uart_done
    );

END ARCHITECTURE;
