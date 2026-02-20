LIBRARY ieee;

USE ieee.numeric_std.ALL;
USE ieee.std_logic_1164.ALL;

ENTITY vga_dma_engine IS
    GENERIC (
        BURST_BEATS_G : POSITIVE := 16;
        FRAME_BUF_BASE_0 : STD_LOGIC_VECTOR(31 DOWNTO 0) := x"10200000";
        FRAME_BUF_BASE_1 : STD_LOGIC_VECTOR(31 DOWNTO 0) := x"10296000"
    );
    PORT (
        clk : IN STD_LOGIC;
        rstn : IN STD_LOGIC;
        init_calib_complete : IN STD_LOGIC;
        in_vblank_i : IN STD_LOGIC := '0';
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
        -- Async FIFO --
        pxl_data : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
        wr_en : OUT STD_LOGIC;
        almost_full : IN STD_LOGIC;
        full : IN STD_LOGIC;
        -- NEORV32 Signals -- 
        swap_req_seq_i : IN STD_LOGIC; -- signal new frame, ready to change frame buffers
        swap_ack_seq_o : OUT STD_LOGIC; -- ack frame buffer change
        swap_buf_sel_i : IN STD_LOGIC -- selects which frame buffer to read from 
    );
END vga_dma_engine;

ARCHITECTURE rtl OF vga_dma_engine IS

    -- Derived constants (declared before reg_type so ranges are visible)
    CONSTANT AXI_BEAT_BYTES_C : POSITIVE := 4;
    CONSTANT FRAME_BYTES_C : POSITIVE := 640 * 480 * 2; -- 614400
    CONSTANT BURST_BYTES_C : POSITIVE := BURST_BEATS_G * AXI_BEAT_BYTES_C;
    CONSTANT BURSTS_PER_FRAME_C : POSITIVE := FRAME_BYTES_C / BURST_BYTES_C;
    CONSTANT DRAIN_WAIT_C : POSITIVE := 16000;
    CONSTANT ARLEN_C : STD_LOGIC_VECTOR(7 DOWNTO 0) :=
    STD_LOGIC_VECTOR(to_unsigned(BURST_BEATS_G - 1, 8));

    TYPE state_type IS (WAIT_CALIB, IDLE, SEND_AR, WAIT_R, WAIT_SOF, SET_ADDRESS);

    TYPE reg_type IS RECORD
        state : state_type;
        beat_cnt : INTEGER RANGE 0 TO BURST_BEATS_G - 1;
        read_address : unsigned(31 DOWNTO 0);
        burst_cnt : INTEGER RANGE 0 TO BURSTS_PER_FRAME_C - 1;
        drain_cnt : INTEGER RANGE 0 TO DRAIN_WAIT_C;
    END RECORD reg_type;

    CONSTANT INIT_REG_FILE : reg_type := (
        state => WAIT_CALIB,
        beat_cnt => 0,
        read_address => unsigned(FRAME_BUF_BASE_0),
        burst_cnt => 0,
        drain_cnt => 0
    );

    SIGNAL reg, reg_next : reg_type := INIT_REG_FILE;
    SIGNAL vblank_sync_ff1 : STD_LOGIC := '0';
    SIGNAL vblank_sync_ff2 : STD_LOGIC := '0';
    SIGNAL vblank_sync_ff3 : STD_LOGIC := '0';
    SIGNAL frame_sync_pulse : STD_LOGIC := '0';

    SIGNAL swap_req_reg : STD_LOGIC := '0'; -- last seen value of swap_req_seq_i
    SIGNAL swap_req_pending : STD_LOGIC := '0'; -- buffer change request registered (waiting for commit_buffer_switch before acknowledging)
    SIGNAL frame_buffer_reg : STD_LOGIC := '0'; -- current selection of frame buffer
    SIGNAL pending_buffer_reg : STD_LOGIC := '0'; -- pending selection of frame buffer (waiting for commit_buffer_switch)
    SIGNAL commit_buffer_switch : STD_LOGIC := '0'; -- safe to change frame buffer

    SIGNAL frame_buffer_address : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');

    -- CDC --
    ATTRIBUTE async_reg : STRING;
    ATTRIBUTE shreg_extract : STRING;
    ATTRIBUTE async_reg OF vblank_sync_ff1 : SIGNAL IS "TRUE";
    ATTRIBUTE async_reg OF vblank_sync_ff2 : SIGNAL IS "TRUE";
    ATTRIBUTE shreg_extract OF vblank_sync_ff1 : SIGNAL IS "NO";
    ATTRIBUTE shreg_extract OF vblank_sync_ff2 : SIGNAL IS "NO";

BEGIN
    -- Static assertions (fire at elaboration / time 0 in simulation)
    ASSERT BURST_BEATS_G >= 1 AND BURST_BEATS_G <= 256
    REPORT "BURST_BEATS_G must be between 1 and 256"
        SEVERITY failure;

    ASSERT BURST_BEATS_G = 1 OR BURST_BEATS_G = 2 OR BURST_BEATS_G = 4
    OR BURST_BEATS_G = 8 OR BURST_BEATS_G = 16 OR BURST_BEATS_G = 32
    OR BURST_BEATS_G = 64 OR BURST_BEATS_G = 128 OR BURST_BEATS_G = 256
    REPORT "BURST_BEATS_G must be a power of two (AXI 4KB boundary requirement)"
        SEVERITY failure;

    ASSERT FRAME_BYTES_C MOD BURST_BYTES_C = 0
    REPORT "Frame size must be evenly divisible by burst size"
        SEVERITY failure;

    frame_buffer_address <= FRAME_BUF_BASE_0 WHEN frame_buffer_reg = '0' ELSE
        FRAME_BUF_BASE_1;

    -- Handshake (1-bit toggle protocol, one request in flight)
    --
    --   NEORV32 (writer)                                VGA_DMA (reader)
    --   ----------------                                ----------------
    --   1) write swap_buf_sel  ----------------------->  (input sampled on req edge)
    --   2) toggle swap_req_seq (0->1 or 1->0) ------->  if req /= req_reg and pending=0:
    --                                                    - req_reg <= req
    --                                                    - pending_buffer_reg <= swap_buf_sel
    --                                                    - swap_req_pending <= '1'
    --                                                    (request is now queued)
    --
    --                                                    wait until commit_buffer_switch='1'
    --                                                    (safe point: end-of-frame / boundary)
    --
    --                                                    on commit:
    --                                                    - frame_buffer_reg <= pending_buffer_reg
    --                                                    - swap_ack_seq_o   <= req_reg
    --                                                    - swap_req_pending <= '0'
    --
    --   3) poll until swap_ack_seq_o = swap_req_seq  <--- commit acknowledged
    --   4) only then start writing next frame into the other buffer
    PROCESS (clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                swap_req_reg <= '0';
                swap_req_pending <= '0';
                frame_buffer_reg <= '0';
                swap_ack_seq_o <= '0';
                pending_buffer_reg <= '0';
            ELSE
                IF commit_buffer_switch = '1' AND swap_req_pending = '1' THEN -- we are ready to switch frame buffers
                    frame_buffer_reg <= pending_buffer_reg; -- change frame buffer
                    swap_ack_seq_o <= swap_req_reg; -- software waits for ack==req
                    swap_req_pending <= '0'; -- clear pending swap request
                ELSIF swap_req_pending = '0' AND swap_req_seq_i /= swap_req_reg THEN -- signal swap_req_seq_i has changed value
                    swap_req_reg <= swap_req_seq_i; -- register new signal
                    swap_req_pending <= '1'; -- set framebuffer switch pending
                    pending_buffer_reg <= swap_buf_sel_i; -- register next frame buffer selection value
                END IF;
            END IF;
        END IF;
    END PROCESS;

    -- Write channels (unused, tie off)
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

    -- Read address channel constants
    m_axi_araddr <= STD_LOGIC_VECTOR(reg.read_address);
    m_axi_arlen <= ARLEN_C;
    m_axi_arsize <= "010"; -- 4 bytes per beat
    m_axi_arburst <= "01"; -- INCR
    m_axi_arcache <= "0011";
    m_axi_arprot <= "000";

    -- CDC sync from pixel clock domain (in_vblank_i) to AXI clock domain (clk)
    cdc_sync : PROCESS (clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                vblank_sync_ff1 <= '0';
                vblank_sync_ff2 <= '0';
                vblank_sync_ff3 <= '0';
            ELSE
                vblank_sync_ff1 <= in_vblank_i;
                vblank_sync_ff2 <= vblank_sync_ff1;
                vblank_sync_ff3 <= vblank_sync_ff2;
            END IF;
        END IF;
    END PROCESS;

    frame_sync_pulse <= vblank_sync_ff2 AND NOT vblank_sync_ff3;

    -- Registered process
    PROCESS (clk)
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                reg <= INIT_REG_FILE;
            ELSE
                reg <= reg_next;
            END IF;
        END IF;
    END PROCESS;

    -- Combinational next-state
    PROCESS (reg, m_axi_arready, m_axi_rvalid, init_calib_complete, m_axi_rdata, m_axi_rlast, almost_full, full, frame_sync_pulse, vblank_sync_ff2, frame_buffer_address)
    BEGIN
        reg_next <= reg;
        m_axi_rready <= '0';
        m_axi_arvalid <= '0';
        commit_buffer_switch <= '0';
        pxl_data <= (OTHERS => '0');
        wr_en <= '0';

        CASE reg.state IS
            WHEN WAIT_CALIB =>
                IF init_calib_complete = '1' THEN
                    reg_next.state <= IDLE;
                END IF;

            WHEN IDLE =>
                IF almost_full = '0' THEN
                    reg_next.state <= SEND_AR;
                END IF;

            WHEN SEND_AR =>
                m_axi_arvalid <= '1';
                IF m_axi_arready = '1' THEN
                    reg_next.state <= WAIT_R;
                END IF;

            WHEN WAIT_R =>
                m_axi_rready <= NOT full;
                IF m_axi_rvalid = '1' AND full = '0' THEN
                    pxl_data <= m_axi_rdata;
                    wr_en <= '1';

                    IF reg.beat_cnt = BURST_BEATS_G - 1 THEN
                        reg_next.state <= IDLE;
                        reg_next.beat_cnt <= 0;

                        IF reg.burst_cnt = BURSTS_PER_FRAME_C - 1 THEN
                            reg_next.state <= WAIT_SOF;
                            reg_next.burst_cnt <= 0;
                            reg_next.drain_cnt <= 0;
                        ELSE
                            reg_next.read_address <= reg.read_address + BURST_BYTES_C;
                            reg_next.burst_cnt <= reg.burst_cnt + 1;
                        END IF;
                    ELSE
                        reg_next.beat_cnt <= reg.beat_cnt + 1;
                    END IF;
                END IF;

            WHEN WAIT_SOF =>
                -- Start drain wait once vblank is seen in this clock domain.
                IF reg.drain_cnt = 0 THEN
                    IF frame_sync_pulse = '1' OR vblank_sync_ff2 = '1' THEN
                        reg_next.drain_cnt <= 1;
                    END IF;
                ELSIF reg.drain_cnt < DRAIN_WAIT_C THEN
                    reg_next.drain_cnt <= reg.drain_cnt + 1;
                ELSE
                    commit_buffer_switch <= '1';
                    reg_next.state <= SET_ADDRESS;
                    reg_next.drain_cnt <= 0;
                END IF;

            WHEN SET_ADDRESS =>
                reg_next.read_address <= unsigned(frame_buffer_address);
                reg_next.state <= IDLE;

            WHEN OTHERS =>
                reg_next.state <= WAIT_CALIB;
        END CASE;
    END PROCESS;
END ARCHITECTURE;
