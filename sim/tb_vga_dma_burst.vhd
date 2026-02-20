-- tb_vga_dma_burst.vhd
-- VUnit + OSVVM testbench for vga_dma_engine burst read verification
--
-- Tests the AXI4 burst read functionality against OSVVM's protocol-correct
-- Axi4Memory verification component.
--
-- Parameterized by BURST_BEATS generic (default 16). Use VUnit add_config()
-- to run with different burst lengths (16, 32, 64).

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY osvvm;
CONTEXT osvvm.OsvvmContext;

LIBRARY osvvm_axi4;
CONTEXT osvvm_axi4.Axi4Context;

LIBRARY vunit_lib;
CONTEXT vunit_lib.vunit_context;

LIBRARY dut_lib;

ENTITY tb_vga_dma_burst IS
    GENERIC (
        runner_cfg : STRING;
        BURST_BEATS : NATURAL := 16
    );
END ENTITY;

ARCHITECTURE sim OF tb_vga_dma_burst IS

    -- Clock period for ~81 MHz (MIG ui_clk)
    CONSTANT CLK_PERIOD : TIME := 12.3 ns;

    -- AXI data/address widths
    CONSTANT AXI_ADDR_WIDTH : INTEGER := 32;
    CONSTANT AXI_DATA_WIDTH : INTEGER := 32;
    CONSTANT AXI_ID_WIDTH : INTEGER := 4;
    CONSTANT AXI_USER_WIDTH : INTEGER := 1;

    -- Burst-length derived constants (mirror DUT formulas)
    CONSTANT BURST_BEATS_C : POSITIVE := BURST_BEATS;
    CONSTANT BURST_BYTES_C : POSITIVE := BURST_BEATS_C * 4;
    CONSTANT FRAME_BYTES_C : POSITIVE := 640 * 480 * 2; -- 614400
    CONSTANT BURSTS_PER_FRAME_C : POSITIVE := FRAME_BYTES_C / BURST_BYTES_C;
    CONSTANT MID_BURST_STALL_BEAT : POSITIVE := BURST_BEATS_C / 3;
    CONSTANT DRAIN_WAIT_C : POSITIVE := 16000;

    -- Signals
    SIGNAL clk : STD_LOGIC := '0';
    SIGNAL rstn : STD_LOGIC := '0';
    SIGNAL init_calib_complete : STD_LOGIC := '0';
    SIGNAL in_vblank : STD_LOGIC := '0';

    -- FIFO interface signals
    SIGNAL pxl_data : STD_LOGIC_VECTOR(31 DOWNTO 0);
    SIGNAL wr_en : STD_LOGIC;
    SIGNAL almost_full : STD_LOGIC := '0'; -- Default: FIFO has space
    SIGNAL full : STD_LOGIC := '0'; -- Default: FIFO not full

    -- AXI Write Address Channel (directly tie off - DUT doesn't use)
    SIGNAL m_axi_awaddr : STD_LOGIC_VECTOR(31 DOWNTO 0);
    SIGNAL m_axi_awlen : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL m_axi_awsize : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL m_axi_awburst : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL m_axi_awcache : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL m_axi_awprot : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL m_axi_awvalid : STD_LOGIC;
    SIGNAL m_axi_awready : STD_LOGIC := '0';

    -- AXI Write Data Channel
    SIGNAL m_axi_wdata : STD_LOGIC_VECTOR(31 DOWNTO 0);
    SIGNAL m_axi_wstrb : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL m_axi_wlast : STD_LOGIC;
    SIGNAL m_axi_wvalid : STD_LOGIC;
    SIGNAL m_axi_wready : STD_LOGIC := '0';

    -- AXI Write Response Channel
    SIGNAL m_axi_bresp : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";
    SIGNAL m_axi_bvalid : STD_LOGIC := '0';
    SIGNAL m_axi_bready : STD_LOGIC;

    -- AXI Read Address Channel
    SIGNAL m_axi_araddr : STD_LOGIC_VECTOR(31 DOWNTO 0);
    SIGNAL m_axi_arlen : STD_LOGIC_VECTOR(7 DOWNTO 0);
    SIGNAL m_axi_arsize : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL m_axi_arburst : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL m_axi_arcache : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL m_axi_arprot : STD_LOGIC_VECTOR(2 DOWNTO 0);
    SIGNAL m_axi_arvalid : STD_LOGIC;
    SIGNAL m_axi_arready : STD_LOGIC;

    -- AXI Read Data Channel
    SIGNAL m_axi_rdata : STD_LOGIC_VECTOR(31 DOWNTO 0);
    SIGNAL m_axi_rresp : STD_LOGIC_VECTOR(1 DOWNTO 0);
    SIGNAL m_axi_rlast : STD_LOGIC;
    SIGNAL m_axi_rvalid : STD_LOGIC;
    SIGNAL m_axi_rready : STD_LOGIC;

    -- OSVVM AXI4 bus record (directly drives/receives flat signals)
    SIGNAL AxiBus : Axi4RecType(
    WriteAddress(
    Addr(AXI_ADDR_WIDTH - 1 DOWNTO 0),
    ID(AXI_ID_WIDTH - 1 DOWNTO 0),
    User(AXI_USER_WIDTH - 1 DOWNTO 0)
    ),
    WriteData(
    Data(AXI_DATA_WIDTH - 1 DOWNTO 0),
    Strb(AXI_DATA_WIDTH/8 - 1 DOWNTO 0),
    User(AXI_USER_WIDTH - 1 DOWNTO 0),
    ID(AXI_ID_WIDTH - 1 DOWNTO 0)
    ),
    WriteResponse(
    ID(AXI_ID_WIDTH - 1 DOWNTO 0),
    User(AXI_USER_WIDTH - 1 DOWNTO 0)
    ),
    ReadAddress(
    Addr(AXI_ADDR_WIDTH - 1 DOWNTO 0),
    ID(AXI_ID_WIDTH - 1 DOWNTO 0),
    User(AXI_USER_WIDTH - 1 DOWNTO 0)
    ),
    ReadData(
    Data(AXI_DATA_WIDTH - 1 DOWNTO 0),
    ID(AXI_ID_WIDTH - 1 DOWNTO 0),
    User(AXI_USER_WIDTH - 1 DOWNTO 0)
    )
    );

    -- OSVVM transaction interface for memory control
    SIGNAL MemRec : AddressBusRecType(
    Address(AXI_ADDR_WIDTH - 1 DOWNTO 0),
    DataToModel(AXI_DATA_WIDTH - 1 DOWNTO 0),
    DataFromModel(AXI_DATA_WIDTH - 1 DOWNTO 0)
    );

    -- Test constants
    CONSTANT FRAME_BUF_BASE_0_C : STD_LOGIC_VECTOR(31 DOWNTO 0) := x"10200000";
    CONSTANT FRAME_BUF_BASE_1_C : STD_LOGIC_VECTOR(31 DOWNTO 0) := x"10296000";
    CONSTANT READ_ADDR : STD_LOGIC_VECTOR(31 DOWNTO 0) := FRAME_BUF_BASE_0_C;

    SIGNAL swap_req_seq_i : STD_LOGIC := '0'; -- signal new frame, ready to change frame buffers
    SIGNAL swap_ack_seq_o : STD_LOGIC; -- ack frame buffer change
    SIGNAL swap_buf_sel_i : STD_LOGIC := '0';

BEGIN

    ----------------------------------------------------------------------------
    -- Clock generation
    ----------------------------------------------------------------------------
    clk <= NOT clk AFTER CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- DUT: vga_dma_engine
    ----------------------------------------------------------------------------
    dut : ENTITY dut_lib.vga_dma_engine
        GENERIC MAP(
            BURST_BEATS_G => BURST_BEATS_C,
            FRAME_BUF_BASE_0 => FRAME_BUF_BASE_0_C,
            FRAME_BUF_BASE_1 => FRAME_BUF_BASE_1_C
        )
        PORT MAP(
            clk => clk,
            rstn => rstn,
            init_calib_complete => init_calib_complete,
            in_vblank_i => in_vblank,
            -- Write Address Channel
            m_axi_awaddr => m_axi_awaddr,
            m_axi_awlen => m_axi_awlen,
            m_axi_awsize => m_axi_awsize,
            m_axi_awburst => m_axi_awburst,
            m_axi_awcache => m_axi_awcache,
            m_axi_awprot => m_axi_awprot,
            m_axi_awvalid => m_axi_awvalid,
            m_axi_awready => m_axi_awready,
            -- Write Data Channel
            m_axi_wdata => m_axi_wdata,
            m_axi_wstrb => m_axi_wstrb,
            m_axi_wlast => m_axi_wlast,
            m_axi_wvalid => m_axi_wvalid,
            m_axi_wready => m_axi_wready,
            -- Write Response Channel
            m_axi_bresp => m_axi_bresp,
            m_axi_bvalid => m_axi_bvalid,
            m_axi_bready => m_axi_bready,
            -- Read Address Channel
            m_axi_araddr => m_axi_araddr,
            m_axi_arlen => m_axi_arlen,
            m_axi_arsize => m_axi_arsize,
            m_axi_arburst => m_axi_arburst,
            m_axi_arcache => m_axi_arcache,
            m_axi_arprot => m_axi_arprot,
            m_axi_arvalid => m_axi_arvalid,
            m_axi_arready => m_axi_arready,
            -- Read Data Channel
            m_axi_rdata => m_axi_rdata,
            m_axi_rresp => m_axi_rresp,
            m_axi_rlast => m_axi_rlast,
            m_axi_rvalid => m_axi_rvalid,
            m_axi_rready => m_axi_rready,
            -- FIFO Interface
            pxl_data => pxl_data,
            wr_en => wr_en,
            almost_full => almost_full,
            full => full,
            swap_req_seq_i => swap_req_seq_i,
            swap_ack_seq_o => swap_ack_seq_o,
            swap_buf_sel_i => swap_buf_sel_i
        );

    ----------------------------------------------------------------------------
    -- Connect DUT flat signals <-> OSVVM record
    ----------------------------------------------------------------------------
    -- Read Address Channel (DUT is master, OSVVM is subordinate)
    AxiBus.ReadAddress.Addr <= m_axi_araddr;
    AxiBus.ReadAddress.Len <= m_axi_arlen;
    AxiBus.ReadAddress.Size <= m_axi_arsize;
    AxiBus.ReadAddress.Burst <= m_axi_arburst;
    AxiBus.ReadAddress.ID <= (OTHERS => '0');
    AxiBus.ReadAddress.Lock <= '0';
    AxiBus.ReadAddress.Cache <= m_axi_arcache;
    AxiBus.ReadAddress.Prot <= m_axi_arprot;
    AxiBus.ReadAddress.QOS <= (OTHERS => '0');
    AxiBus.ReadAddress.Region <= (OTHERS => '0');
    AxiBus.ReadAddress.User <= (OTHERS => '0');
    AxiBus.ReadAddress.Valid <= m_axi_arvalid;
    m_axi_arready <= AxiBus.ReadAddress.Ready;

    -- Read Data Channel (OSVVM is subordinate, DUT is master)
    m_axi_rdata <= AxiBus.ReadData.Data;
    m_axi_rresp <= AxiBus.ReadData.Resp;
    m_axi_rlast <= AxiBus.ReadData.Last;
    m_axi_rvalid <= AxiBus.ReadData.Valid;
    AxiBus.ReadData.Ready <= m_axi_rready;

    -- Write channels (DUT doesn't use, but OSVVM needs them driven)
    AxiBus.WriteAddress.Addr <= m_axi_awaddr;
    AxiBus.WriteAddress.Len <= m_axi_awlen;
    AxiBus.WriteAddress.Size <= m_axi_awsize;
    AxiBus.WriteAddress.Burst <= m_axi_awburst;
    AxiBus.WriteAddress.ID <= (OTHERS => '0');
    AxiBus.WriteAddress.Lock <= '0';
    AxiBus.WriteAddress.Cache <= m_axi_awcache;
    AxiBus.WriteAddress.Prot <= m_axi_awprot;
    AxiBus.WriteAddress.QOS <= (OTHERS => '0');
    AxiBus.WriteAddress.Region <= (OTHERS => '0');
    AxiBus.WriteAddress.User <= (OTHERS => '0');
    AxiBus.WriteAddress.Valid <= m_axi_awvalid;
    m_axi_awready <= AxiBus.WriteAddress.Ready;

    AxiBus.WriteData.Data <= m_axi_wdata;
    AxiBus.WriteData.Strb <= m_axi_wstrb;
    AxiBus.WriteData.Last <= m_axi_wlast;
    AxiBus.WriteData.User <= (OTHERS => '0');
    AxiBus.WriteData.ID <= (OTHERS => '0');
    AxiBus.WriteData.Valid <= m_axi_wvalid;
    m_axi_wready <= AxiBus.WriteData.Ready;

    m_axi_bresp <= AxiBus.WriteResponse.Resp;
    m_axi_bvalid <= AxiBus.WriteResponse.Valid;
    AxiBus.WriteResponse.Ready <= m_axi_bready;

    ----------------------------------------------------------------------------
    -- OSVVM AXI4 Memory Subordinate
    -- This is the protocol-correct "golden reference" implementation
    ----------------------------------------------------------------------------
    Axi4MemSubordinate : ENTITY osvvm_axi4.Axi4Memory
        PORT MAP(
            Clk => clk,
            nReset => rstn,
            AxiBus => AxiBus,
            TransRec => MemRec
        );

    ----------------------------------------------------------------------------
    -- OSVVM Initialization
    ----------------------------------------------------------------------------
    OsvvmInit : PROCESS
    BEGIN
        -- Set OSVVM alert log name
        SetAlertLogName("tb_vga_dma_burst");
        WAIT;
    END PROCESS;

    ----------------------------------------------------------------------------
    -- Test Sequencer
    ----------------------------------------------------------------------------
    TestSequencer : PROCESS
        VARIABLE addr : STD_LOGIC_VECTOR(31 DOWNTO 0);
        VARIABLE data : STD_LOGIC_VECTOR(31 DOWNTO 0);
        VARIABLE timeout_cycles : INTEGER;
        VARIABLE beat_count : INTEGER;
        VARIABLE ar_count : INTEGER;
        VARIABLE expected_addr : unsigned(31 DOWNTO 0);
        VARIABLE next_req_seq : STD_LOGIC;
        VARIABLE ack_seq_before : STD_LOGIC;
        VARIABLE swap_issued : BOOLEAN;
    BEGIN
        test_runner_setup(runner, runner_cfg);

        -- Wait for OSVVM components to initialize
        WAIT FOR 0 ns;

        WHILE test_suite LOOP

            -- Reset sequence (common to all tests)
            rstn <= '0';
            init_calib_complete <= '0';
            in_vblank <= '0';
            almost_full <= '0';
            full <= '0';
            swap_req_seq_i <= '0';
            swap_buf_sel_i <= '0';
            WAIT FOR CLK_PERIOD * 10;
            rstn <= '1';
            WAIT FOR CLK_PERIOD * 5;

            ----------------------------------------------------------------
            -- Test: Single burst read
            ----------------------------------------------------------------
            IF run("test_single_read") THEN
                info("Testing single AXI burst read");

                -- Pre-fill memory with test pattern (full burst)
                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    Write(MemRec, addr, x"DEADBE" & STD_LOGIC_VECTOR(to_unsigned(i, 8)));
                END LOOP;

                -- Signal DDR calibration complete (triggers DUT)
                init_calib_complete <= '1';

                -- Wait for DUT to complete burst (wr_en pulses indicate data transfer)
                timeout_cycles := 200;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;

                check(timeout_cycles > 0, "Timeout waiting for burst to start");

                -- Wait for burst to complete
                WAIT FOR CLK_PERIOD * (BURST_BEATS_C + 4);

                info("Single burst read test PASSED");

                ----------------------------------------------------------------
                -- Test: Verify correct read address
                ----------------------------------------------------------------
            ELSIF run("test_read_address") THEN
                info("Verifying DUT issues correct read address");

                -- Fill addresses with unique patterns for full burst
                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    Write(MemRec, addr, x"AAAA" & STD_LOGIC_VECTOR(to_unsigned(i, 16)));
                END LOOP;

                init_calib_complete <= '1';

                -- Wait for burst to start
                timeout_cycles := 200;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;

                check(timeout_cycles > 0, "Timeout waiting for read to start");

                -- Verify first word of burst matches expected data
                check_equal(pxl_data, STD_LOGIC_VECTOR'(x"AAAA0000"),
                "First burst word should be 0xAAAA0000");

                info("Address test PASSED");

                ----------------------------------------------------------------
                -- Test: Multiple burst cycles (back-to-back)
                ----------------------------------------------------------------
            ELSIF run("test_multiple_reads") THEN
                info("Testing multiple consecutive burst cycles");

                -- Fill memory for first burst
                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    data := STD_LOGIC_VECTOR(to_unsigned(16#11110000# + i, 32));
                    Write(MemRec, addr, data);
                END LOOP;

                init_calib_complete <= '1';

                -- Wait for first burst to start
                timeout_cycles := 200;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "First burst started");

                -- Wait for first burst to complete and second to start
                -- (DUT goes IDLE -> SEND_AR -> WAIT_R immediately if FIFO not full)
                WAIT FOR CLK_PERIOD * (BURST_BEATS_C * 3 + 2);

                -- Verify DUT continues reading (address should have incremented)
                check(wr_en = '1' OR m_axi_arvalid = '1', "Second burst in progress");

                info("Multiple reads test PASSED");

                ----------------------------------------------------------------
                -- Test: Verify full burst read
                ----------------------------------------------------------------
            ELSIF run("test_burst_read_full") THEN
                info("Testing full burst read (" & INTEGER'IMAGE(BURST_BEATS_C) & " beats)");

                -- Pre-fill memory with consecutive words with known pattern
                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    data := STD_LOGIC_VECTOR(to_unsigned(16#0EAD0000# + i, 32));
                    Write(MemRec, addr, data);
                END LOOP;

                init_calib_complete <= '1';

                -- Wait for burst to start
                timeout_cycles := 200;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;

                check(timeout_cycles > 0, "Burst read started");

                -- Wait for burst to complete
                WAIT FOR CLK_PERIOD * (BURST_BEATS_C * 2);

                info("Burst read test PASSED");

                ----------------------------------------------------------------
                -- Test: FIFO backpressure handling
                ----------------------------------------------------------------
            ELSIF run("test_fifo_backpressure") THEN
                info("Testing FIFO backpressure - DMA should stop when almost_full asserted");

                -- Pre-fill memory for multiple bursts (at least 2)
                FOR i IN 0 TO BURST_BEATS_C * 2 - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    data := STD_LOGIC_VECTOR(to_unsigned(16#0AFE0000# + i, 32));
                    Write(MemRec, addr, data);
                END LOOP;

                init_calib_complete <= '1';

                -- Wait for first burst to start
                timeout_cycles := 200;
                WHILE m_axi_arvalid = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "First burst AR phase started");

                -- Let first burst complete
                WAIT UNTIL m_axi_rlast = '1' AND m_axi_rvalid = '1';
                WAIT FOR CLK_PERIOD * 2;

                -- Assert almost_full to simulate FIFO filling up
                almost_full <= '1';

                -- Wait several cycles and verify DMA does NOT issue new AR
                FOR i IN 0 TO 50 LOOP
                    WAIT FOR CLK_PERIOD;
                    check(m_axi_arvalid = '0', "arvalid should remain low while almost_full");
                END LOOP;

                info("DMA correctly paused during almost_full");

                -- De-assert almost_full
                almost_full <= '0';

                -- Verify DMA resumes (issues new AR)
                timeout_cycles := 50;
                WHILE m_axi_arvalid = '0' AND timeout_cycles > 0 LOOP
                    WAIT FOR CLK_PERIOD;
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "DMA resumed after almost_full de-asserted");

                info("FIFO backpressure test PASSED");

                ----------------------------------------------------------------
                -- Test: Address wraps after one full frame
                ----------------------------------------------------------------
            ELSIF run("test_address_wrap_after_full_frame") THEN
                info("Testing DMA address wrap after " & INTEGER'IMAGE(BURSTS_PER_FRAME_C) & " bursts");

                init_calib_complete <= '1';
                ar_count := 0;
                expected_addr := unsigned(READ_ADDR);

                -- Observe exactly one frame worth of AR handshakes.
                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "AR address did not match expected frame progression");
                        ar_count := ar_count + 1;
                        IF ar_count < BURSTS_PER_FRAME_C THEN
                            expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);
                        END IF;
                    END IF;
                END LOOP;

                check_equal(ar_count, BURSTS_PER_FRAME_C,
                "Did not observe full-frame AR traffic");

                -- DMA must be parked in WAIT_SOF until vblank is asserted.
                FOR i IN 0 TO 50 LOOP
                    WAIT UNTIL rising_edge(clk);
                    check_equal(m_axi_arvalid, '0', "DMA should remain parked before in_vblank");
                END LOOP;

                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for wrap burst after drain wait");
                check_equal(m_axi_araddr, READ_ADDR, "First AR after frame sync must wrap to READ_ADDR");
                in_vblank <= '0';

                info("Address wrap test PASSED");

                ----------------------------------------------------------------
                -- Test: WAIT_SOF parks until in_vblank is asserted
                ----------------------------------------------------------------
            ELSIF run("test_wait_sof_parks_until_vblank") THEN
                info("Testing WAIT_SOF park and resume behavior");

                init_calib_complete <= '1';
                ar_count := 0;

                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        ar_count := ar_count + 1;
                    END IF;
                END LOOP;
                check_equal(ar_count, BURSTS_PER_FRAME_C, "Did not complete one frame before WAIT_SOF");

                FOR i IN 0 TO 200 LOOP
                    WAIT UNTIL rising_edge(clk);
                    check_equal(m_axi_arvalid, '0', "AR must stay low while parked in WAIT_SOF");
                END LOOP;

                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "DMA did not resume after in_vblank + drain wait");
                check_equal(m_axi_araddr, READ_ADDR, "Resumed frame must start at READ_ADDR");
                in_vblank <= '0';

                info("WAIT_SOF park test PASSED");

                ----------------------------------------------------------------
                -- Test: in_vblank must be ignored while not in WAIT_SOF
                ----------------------------------------------------------------
            ELSIF run("test_vblank_ignored_outside_wait_sof") THEN
                info("Testing in_vblank is ignored during normal active DMA");

                init_calib_complete <= '1';
                ar_count := 0;
                expected_addr := unsigned(READ_ADDR);
                timeout_cycles := 5000;

                WHILE ar_count < 3 AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "AR address progression should not be disturbed by early in_vblank");
                        ar_count := ar_count + 1;
                        expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);

                        IF ar_count = 2 THEN
                            in_vblank <= '1';
                            WAIT UNTIL rising_edge(clk);
                            in_vblank <= '0';
                        END IF;
                    END IF;
                END LOOP;

                check_equal(ar_count, 3, "Did not observe first 3 AR handshakes");
                info("Early in_vblank ignored test PASSED");

                ----------------------------------------------------------------
                -- Test: Multiple frame cycles with vblank-gated restart
                ----------------------------------------------------------------
            ELSIF run("test_multiple_frame_cycles") THEN
                info("Testing two frame cycles across WAIT_SOF restart");

                init_calib_complete <= '1';
                ar_count := 0;

                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        ar_count := ar_count + 1;
                    END IF;
                END LOOP;
                check_equal(ar_count, BURSTS_PER_FRAME_C, "Frame 1 did not complete");

                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Frame 2 did not start after vblank");
                check_equal(m_axi_araddr, READ_ADDR, "Frame 2 must restart at READ_ADDR");

                -- Already observed first AR of frame 2 above; verify the next 4.
                ar_count := 1;
                expected_addr := unsigned(READ_ADDR) + to_unsigned(BURST_BYTES_C, 32);
                timeout_cycles := 5000;
                WHILE ar_count < 5 AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "Frame 2 AR progression should increment by BURST_BYTES_C");
                        expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);
                        ar_count := ar_count + 1;
                    END IF;
                END LOOP;
                check_equal(ar_count, 5, "Did not observe 5 AR handshakes in frame 2");
                in_vblank <= '0';
                info("Multiple frame cycles test PASSED");

                ----------------------------------------------------------------
                -- Test: Default frame buffer base must be buffer 0
                ----------------------------------------------------------------
            ELSIF run("test_default_frame_buffer_base_0") THEN
                info("Testing default frame buffer base selection");

                init_calib_complete <= '1';

                timeout_cycles := 400;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for first AR handshake");
                check_equal(m_axi_araddr, FRAME_BUF_BASE_0_C,
                "Initial frame must start at FRAME_BUF_BASE_0");

                info("Default frame buffer base test PASSED");

                ----------------------------------------------------------------
                -- Test: Swap to buffer 1 commits at frame boundary
                ----------------------------------------------------------------
            ELSIF run("test_swap_to_buffer_1_on_frame_boundary") THEN
                info("Testing queued swap to buffer 1 and boundary commit");

                init_calib_complete <= '1';
                ar_count := 0;
                expected_addr := unsigned(FRAME_BUF_BASE_0_C);
                swap_issued := FALSE;
                ack_seq_before := swap_ack_seq_o;
                next_req_seq := swap_req_seq_i;

                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "Current frame must stay on FRAME_BUF_BASE_0 while swap is pending");
                        ar_count := ar_count + 1;

                        IF ar_count = 3 THEN
                            swap_buf_sel_i <= '1';
                            next_req_seq := NOT swap_req_seq_i;
                            swap_req_seq_i <= next_req_seq;
                            swap_issued := TRUE;
                        ELSIF ar_count = 4 THEN
                            -- Prove buffer select is sampled with request edge.
                            swap_buf_sel_i <= '0';
                        END IF;

                        IF swap_issued THEN
                            check_equal(swap_ack_seq_o, ack_seq_before,
                            "ack must not toggle before boundary commit");
                        END IF;

                        IF ar_count < BURSTS_PER_FRAME_C THEN
                            expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);
                        END IF;
                    END IF;
                END LOOP;
                check_equal(ar_count, BURSTS_PER_FRAME_C,
                "Did not observe one full frame before swap commit");
                check(swap_issued, "Swap request was not issued during frame");

                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for first AR after swap request");
                check_equal(m_axi_araddr, FRAME_BUF_BASE_1_C,
                "First AR after commit must start at FRAME_BUF_BASE_1");
                check_equal(swap_ack_seq_o, next_req_seq,
                "ack must match req after swap commits");
                in_vblank <= '0';

                info("Swap-to-buffer-1 boundary commit test PASSED");

                ----------------------------------------------------------------
                -- Test: Second swap request after ack returns to buffer 0
                ----------------------------------------------------------------
            ELSIF run("test_swap_back_to_buffer_0_after_ack") THEN
                info("Testing two sequential swaps with one request in flight");

                init_calib_complete <= '1';

                -- Frame 0 on buffer 0, queue swap to buffer 1.
                ar_count := 0;
                expected_addr := unsigned(FRAME_BUF_BASE_0_C);
                swap_issued := FALSE;
                ack_seq_before := swap_ack_seq_o;
                next_req_seq := swap_req_seq_i;

                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "Frame 0 must use FRAME_BUF_BASE_0");
                        ar_count := ar_count + 1;

                        IF ar_count = 2 THEN
                            swap_buf_sel_i <= '1';
                            next_req_seq := NOT swap_req_seq_i;
                            swap_req_seq_i <= next_req_seq;
                            swap_issued := TRUE;
                        END IF;

                        IF swap_issued THEN
                            check_equal(swap_ack_seq_o, ack_seq_before,
                            "ack must stay unchanged until first swap commits");
                        END IF;

                        IF ar_count < BURSTS_PER_FRAME_C THEN
                            expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);
                        END IF;
                    END IF;
                END LOOP;
                check_equal(ar_count, BURSTS_PER_FRAME_C,
                "Did not observe full frame before first swap commit");
                check(swap_issued, "First swap request was not issued");

                -- Start frame 1 and verify buffer 1 selected.
                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Frame 1 did not start after first swap request");
                check_equal(m_axi_araddr, FRAME_BUF_BASE_1_C,
                "Frame 1 must start at FRAME_BUF_BASE_1");
                check_equal(swap_ack_seq_o, next_req_seq,
                "First swap must be acknowledged before second request");
                in_vblank <= '0';

                -- During frame 1, queue swap back to buffer 0.
                ar_count := 1;
                expected_addr := unsigned(FRAME_BUF_BASE_1_C) + to_unsigned(BURST_BYTES_C, 32);
                ack_seq_before := swap_ack_seq_o;
                swap_issued := FALSE;

                timeout_cycles := BURSTS_PER_FRAME_C * (BURST_BEATS_C + 20);
                WHILE ar_count < BURSTS_PER_FRAME_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;

                    IF m_axi_arvalid = '1' AND m_axi_arready = '1' THEN
                        check_equal(m_axi_araddr, STD_LOGIC_VECTOR(expected_addr),
                        "Frame 1 AR progression must stay on FRAME_BUF_BASE_1");
                        ar_count := ar_count + 1;

                        IF ar_count = 3 THEN
                            swap_buf_sel_i <= '0';
                            next_req_seq := NOT swap_req_seq_i;
                            swap_req_seq_i <= next_req_seq;
                            swap_issued := TRUE;
                        END IF;

                        IF swap_issued THEN
                            check_equal(swap_ack_seq_o, ack_seq_before,
                            "ack must stay unchanged until second swap commits");
                        END IF;

                        IF ar_count < BURSTS_PER_FRAME_C THEN
                            expected_addr := expected_addr + to_unsigned(BURST_BYTES_C, 32);
                        END IF;
                    END IF;
                END LOOP;
                check_equal(ar_count, BURSTS_PER_FRAME_C,
                "Did not observe full frame on FRAME_BUF_BASE_1 before second commit");
                check(swap_issued, "Second swap request was not issued");

                -- Start frame 2 and verify buffer 0 selected again.
                in_vblank <= '1';
                timeout_cycles := DRAIN_WAIT_C + 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Frame 2 did not start after second swap request");
                check_equal(m_axi_araddr, FRAME_BUF_BASE_0_C,
                "Frame 2 must restart at FRAME_BUF_BASE_0");
                check_equal(swap_ack_seq_o, next_req_seq,
                "Second swap must be acknowledged on commit");
                in_vblank <= '0';

                info("Sequential swap test PASSED");

                ----------------------------------------------------------------
                -- Test: No writes/progress while FIFO full is asserted
                ----------------------------------------------------------------
            ELSIF run("test_no_write_when_full") THEN
                info("Testing no writes while full='1'");

                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    Write(MemRec, addr, x"CAFE" & STD_LOGIC_VECTOR(to_unsigned(i, 16)));
                END LOOP;

                full <= '1';
                init_calib_complete <= '1';

                -- Wait for first AR handshake into WAIT_R.
                timeout_cycles := 400;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for first AR handshake");

                -- While full is high, no beat may be accepted and address must not advance.
                FOR i IN 0 TO 8 LOOP
                    WAIT UNTIL rising_edge(clk);
                    check_equal(m_axi_rready, '0', "rready must stay low while full");
                    check_equal(wr_en, '0', "wr_en must stay low while full");
                    check_equal(m_axi_arvalid, '0', "AR channel must stay idle while waiting for data beat acceptance");
                    check_equal(m_axi_araddr, READ_ADDR, "Address must not advance while full");
                END LOOP;

                full <= '0';

                timeout_cycles := 400;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for first accepted beat after full de-assert");
                check_equal(pxl_data, STD_LOGIC_VECTOR'(x"CAFE0000"),
                "First accepted beat after stall must still be beat 0");

                info("No-write-when-full test PASSED");

                ----------------------------------------------------------------
                -- Test: Mid-burst backpressure and resume without drops/dupes
                ----------------------------------------------------------------
            ELSIF run("test_backpressure_resume_mid_burst") THEN
                info("Testing mid-burst full backpressure and resume");

                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    Write(MemRec, addr, x"BEEF" & STD_LOGIC_VECTOR(to_unsigned(i, 16)));
                END LOOP;

                init_calib_complete <= '1';
                beat_count := 0;

                -- Consume first MID_BURST_STALL_BEAT beats normally.
                timeout_cycles := 2000;
                WHILE beat_count < MID_BURST_STALL_BEAT AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                    IF wr_en = '1' THEN
                        data := x"BEEF" & STD_LOGIC_VECTOR(to_unsigned(beat_count, 16));
                        check_equal(pxl_data, data, "Unexpected beat sequence before stall");
                        beat_count := beat_count + 1;
                    END IF;
                END LOOP;
                check_equal(beat_count, MID_BURST_STALL_BEAT, "Did not receive expected beats before stall");

                -- Stall in middle of burst.
                full <= '1';
                FOR i IN 0 TO 8 LOOP
                    WAIT UNTIL rising_edge(clk);
                    check_equal(m_axi_rready, '0', "rready must be low during full stall");
                    check_equal(wr_en, '0', "wr_en must remain low during full stall");
                    check_equal(m_axi_araddr, READ_ADDR, "Address must remain on current burst while stalled");
                END LOOP;

                -- Resume and verify remaining beats are in-order and complete.
                full <= '0';
                timeout_cycles := 3000;
                WHILE beat_count < BURST_BEATS_C AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                    IF wr_en = '1' THEN
                        data := x"BEEF" & STD_LOGIC_VECTOR(to_unsigned(beat_count, 16));
                        check_equal(pxl_data, data, "Unexpected beat sequence after stall release");
                        beat_count := beat_count + 1;
                    END IF;
                END LOOP;
                check_equal(beat_count, BURST_BEATS_C,
                "Burst must complete with exactly " & INTEGER'IMAGE(BURST_BEATS_C) & " accepted beats");

                info("Mid-burst backpressure test PASSED");

                ----------------------------------------------------------------
                -- Test: Burst counter advances only on accepted last beat
                ----------------------------------------------------------------
            ELSIF run("test_burst_counter_increments_only_on_accepted_last_beat") THEN
                info("Testing burst progression only on accepted final beat");

                FOR i IN 0 TO BURST_BEATS_C - 1 LOOP
                    addr := STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(i * 4, 32));
                    Write(MemRec, addr, x"FACE" & STD_LOGIC_VECTOR(to_unsigned(i, 16)));
                END LOOP;

                init_calib_complete <= '1';
                beat_count := 0;

                -- Accept all beats except the last.
                timeout_cycles := 3000;
                WHILE beat_count < BURST_BEATS_C - 1 AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                    IF wr_en = '1' THEN
                        data := x"FACE" & STD_LOGIC_VECTOR(to_unsigned(beat_count, 16));
                        check_equal(pxl_data, data, "Unexpected beat sequence before last-beat stall");
                        beat_count := beat_count + 1;
                    END IF;
                END LOOP;
                check_equal(beat_count, BURST_BEATS_C - 1,
                "Failed to reach beat " & INTEGER'IMAGE(BURST_BEATS_C - 1));

                -- Block the final beat; DMA must not advance burst/address yet.
                full <= '1';
                FOR i IN 0 TO 8 LOOP
                    WAIT UNTIL rising_edge(clk);
                    check_equal(wr_en, '0', "No beat may be accepted while final beat is stalled");
                    check_equal(m_axi_arvalid, '0', "No next burst request allowed before final beat is accepted");
                    check_equal(m_axi_araddr, READ_ADDR, "Address must remain at current burst while last beat is blocked");
                END LOOP;

                -- Allow final beat, then verify next burst starts at +BURST_BYTES_C.
                full <= '0';
                timeout_cycles := 500;
                WHILE wr_en = '0' AND timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for accepted final beat");
                check_equal(pxl_data,
                x"FACE" & STD_LOGIC_VECTOR(to_unsigned(BURST_BEATS_C - 1, 16)),
                "Accepted beat after stall must be the final beat of the burst");

                timeout_cycles := 600;
                WHILE timeout_cycles > 0 LOOP
                    WAIT UNTIL rising_edge(clk);
                    EXIT WHEN m_axi_arvalid = '1' AND m_axi_arready = '1';
                    timeout_cycles := timeout_cycles - 1;
                END LOOP;
                check(timeout_cycles > 0, "Timed out waiting for next burst AR handshake");
                check_equal(m_axi_araddr,
                STD_LOGIC_VECTOR(unsigned(READ_ADDR) + to_unsigned(BURST_BYTES_C, 32)),
                "Next burst must start at base+" & INTEGER'IMAGE(BURST_BYTES_C) &
                " only after accepted last beat");

                info("Accepted-last-beat progression test PASSED");

            END IF;
        END LOOP;

        test_runner_cleanup(runner);
    END PROCESS;

    ----------------------------------------------------------------------------
    -- rlast protocol assertion
    -- Verifies rlast alignment with beat count on every accepted beat.
    ----------------------------------------------------------------------------
    RlastCheck : PROCESS (clk)
        VARIABLE beat : INTEGER RANGE 0 TO BURST_BEATS_C - 1 := 0;
    BEGIN
        IF rising_edge(clk) THEN
            IF rstn = '0' THEN
                beat := 0;
            ELSIF m_axi_rvalid = '1' AND m_axi_rready = '1' THEN
                IF beat = BURST_BEATS_C - 1 THEN
                    check_equal(m_axi_rlast, '1', "rlast not asserted on final beat of burst");
                    beat := 0;
                ELSE
                    check_equal(m_axi_rlast, '0', "rlast asserted before final beat of burst");
                    beat := beat + 1;
                END IF;
            END IF;
        END IF;
    END PROCESS;

    ----------------------------------------------------------------------------
    -- Watchdog timeout
    ----------------------------------------------------------------------------
    test_runner_watchdog(runner, 10 ms);

END ARCHITECTURE;
