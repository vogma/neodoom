LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY vunit_lib;
CONTEXT vunit_lib.vunit_context;

LIBRARY dut_lib;

ENTITY tb_vga_controller IS
    GENERIC (
        runner_cfg : STRING
    );
END ENTITY;

ARCHITECTURE sim OF tb_vga_controller IS
    CONSTANT CLK_PERIOD : TIME := 40 ns;

    CONSTANT FRAME_WIDTH : NATURAL := 640;
    CONSTANT FRAME_HEIGHT : NATURAL := 480;
    CONSTANT H_FRONT_PORCH : NATURAL := 16;
    CONSTANT H_SYNC_PULSE_WIDTH : NATURAL := 96;
    CONSTANT H_TOTAL_LINE : NATURAL := 800;
    CONSTANT V_FRONT_PORCH : NATURAL := 10;
    CONSTANT V_SYNC_PULSE_WIDTH : NATURAL := 2;
    CONSTANT V_MAX_LINE : NATURAL := 525;
    CONSTANT DRAIN_LINES_C : NATURAL := 5;

    -- Letterbox constants (DOOM renders 640x400, centered in 640x480)
    CONSTANT LETTERBOX_TOP : NATURAL := 40;
    CONSTANT GAME_HEIGHT : NATURAL := 400;
    CONSTANT GAME_BOTTOM : NATURAL := LETTERBOX_TOP + GAME_HEIGHT; -- 440

    SIGNAL pxl_clk : STD_LOGIC := '0';
    SIGNAL rst : STD_LOGIC := '1';

    SIGNAL vga_hs : STD_LOGIC;
    SIGNAL vga_vs : STD_LOGIC;
    SIGNAL vga_r : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL vga_g : STD_LOGIC_VECTOR(3 DOWNTO 0);
    SIGNAL vga_b : STD_LOGIC_VECTOR(3 DOWNTO 0);

    SIGNAL empty : STD_LOGIC := '0';
    SIGNAL pxl_data : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
    SIGNAL rd_en : STD_LOGIC;
    SIGNAL rd_rst_busy : STD_LOGIC := '0';

    SIGNAL frame_start : STD_LOGIC;
    SIGNAL underrun : STD_LOGIC;
    SIGNAL in_vblank : STD_LOGIC;
BEGIN
    pxl_clk <= NOT pxl_clk AFTER CLK_PERIOD / 2;

    dut : ENTITY dut_lib.vga_controller
        PORT MAP(
            rst => rst,
            pxl_clk => pxl_clk,
            VGA_HS_O => vga_hs,
            VGA_VS_O => vga_vs,
            VGA_R => vga_r,
            VGA_G => vga_g,
            VGA_B => vga_b,
            empty => empty,
            pxl_data => pxl_data,
            rd_en => rd_en,
            rd_rst_busy_i => rd_rst_busy,
            in_vblank_o => in_vblank,
            frame_start_o => frame_start,
            underrun_o => underrun
        );

    TestSequencer : PROCESS
        VARIABLE cycle_count : INTEGER;
        VARIABLE hs_low_count : INTEGER;
        VARIABLE rd_count : INTEGER;
        VARIABLE hs_went_low : BOOLEAN;
        VARIABLE vs_went_low : BOOLEAN;
        VARIABLE t_start : TIME;
        VARIABLE vblank_high_count : INTEGER;
        PROCEDURE reset_and_start IS
        BEGIN
            rst <= '0';
            empty <= '1';
            rd_rst_busy <= '0';
            pxl_data <= (OTHERS => '0');
            WAIT FOR CLK_PERIOD * 4;
            WAIT UNTIL rising_edge(pxl_clk);
            rst <= '1';
            empty <= '0';
            WAIT UNTIL rising_edge(pxl_clk);
        END PROCEDURE;
    BEGIN
        test_runner_setup(runner, runner_cfg);

        WHILE test_suite LOOP
            rst <= '1';
            empty <= '0';
            rd_rst_busy <= '0';
            pxl_data <= (OTHERS => '0');

            IF run("test_reset_polarity_active_low") THEN
                rst <= '0';
                empty <= '0';
                rd_rst_busy <= '0';
                pxl_data <= x"00FFFFFF";
                WAIT UNTIL rising_edge(pxl_clk);

                FOR i IN 0 TO 10 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    check_equal(vga_hs, '1', "hsync must stay high in reset");
                    check_equal(vga_vs, '1', "vsync must stay high in reset");
                    check_equal(vga_r, STD_LOGIC_VECTOR'(x"0"), "red must be blanked in reset");
                    check_equal(vga_g, STD_LOGIC_VECTOR'(x"0"), "green must be blanked in reset");
                    check_equal(vga_b, STD_LOGIC_VECTOR'(x"0"), "blue must be blanked in reset");
                    check_equal(rd_en, '0', "rd_en must stay low in reset");
                    check_equal(frame_start, '0', "frame_start must stay low in reset");
                    check_equal(underrun, '0', "underrun must clear in reset");
                END LOOP;

                rst <= '1';
                cycle_count := 0;
                WHILE vga_hs = '1' AND cycle_count < H_TOTAL_LINE * 2 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    cycle_count := cycle_count + 1;
                END LOOP;
                check(cycle_count < H_TOTAL_LINE * 2, "hsync should toggle after reset release");

            ELSIF run("test_sync_signals_active") THEN
                reset_and_start;
                hs_went_low := FALSE;
                FOR i IN 0 TO H_TOTAL_LINE * 3 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    IF vga_hs = '0' THEN
                        hs_went_low := TRUE;
                        EXIT;
                    END IF;
                END LOOP;
                check(hs_went_low, "HSync should go low within 3 lines");

            ELSIF run("test_hsync_pulse_width") THEN
                reset_and_start;
                WHILE vga_hs = '1' LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                hs_low_count := 0;
                WHILE vga_hs = '0' LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    hs_low_count := hs_low_count + 1;
                END LOOP;
                check_equal(hs_low_count, H_SYNC_PULSE_WIDTH, "hsync pulse must be 96 clocks");

            ELSIF run("test_hline_period") THEN
                reset_and_start;
                WAIT UNTIL falling_edge(vga_hs);
                t_start := now;
                WAIT UNTIL falling_edge(vga_hs);
                cycle_count := INTEGER((now - t_start) / CLK_PERIOD);
                check_equal(cycle_count, H_TOTAL_LINE, "horizontal line period must be 800 clocks");

            ELSIF run("test_vsync_occurs") THEN
                reset_and_start;
                vs_went_low := FALSE;
                FOR i IN 0 TO H_TOTAL_LINE * (V_MAX_LINE + 10) LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    IF vga_vs = '0' THEN
                        vs_went_low := TRUE;
                        EXIT;
                    END IF;
                END LOOP;
                check(vs_went_low, "vsync should go low within one frame");

            ELSIF run("test_rgb888_mapping") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Advance to game region (line 40) to test RGB mapping
                -- Skip top letterbox lines where output is always black
                FOR i IN 0 TO LETTERBOX_TOP * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                -- Now in game region, test RGB888 -> RGB444 conversion
                -- Format: 0x00RRGGBB, we take bits [23:20], [15:12], [7:4]
                pxl_data <= x"00FF0000"; -- Pure red
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(vga_r, STD_LOGIC_VECTOR'(x"F"), "00FF0000 red");
                check_equal(vga_g, STD_LOGIC_VECTOR'(x"0"), "00FF0000 green");
                check_equal(vga_b, STD_LOGIC_VECTOR'(x"0"), "00FF0000 blue");

                pxl_data <= x"0000FF00"; -- Pure green
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(vga_r, STD_LOGIC_VECTOR'(x"0"), "0000FF00 red");
                check_equal(vga_g, STD_LOGIC_VECTOR'(x"F"), "0000FF00 green");
                check_equal(vga_b, STD_LOGIC_VECTOR'(x"0"), "0000FF00 blue");

                pxl_data <= x"000000FF"; -- Pure blue
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(vga_r, STD_LOGIC_VECTOR'(x"0"), "000000FF red");
                check_equal(vga_g, STD_LOGIC_VECTOR'(x"0"), "000000FF green");
                check_equal(vga_b, STD_LOGIC_VECTOR'(x"F"), "000000FF blue");

                pxl_data <= x"00FFFFFF"; -- White
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(vga_r, STD_LOGIC_VECTOR'(x"F"), "00FFFFFF red");
                check_equal(vga_g, STD_LOGIC_VECTOR'(x"F"), "00FFFFFF green");
                check_equal(vga_b, STD_LOGIC_VECTOR'(x"F"), "00FFFFFF blue");

            ELSIF run("test_blanking") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';
                pxl_data <= x"00FFFFFF";

                -- Advance to game region first, then past active horizontal
                FOR i IN 0 TO LETTERBOX_TOP * H_TOTAL_LINE + FRAME_WIDTH + 10 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                check_equal(vga_r, STD_LOGIC_VECTOR'(x"0"), "red must blank outside active");
                check_equal(vga_g, STD_LOGIC_VECTOR'(x"0"), "green must blank outside active");
                check_equal(vga_b, STD_LOGIC_VECTOR'(x"0"), "blue must blank outside active");
                check_equal(rd_en, '0', "rd_en must deassert outside active");

            ELSIF run("test_rd_en_count_per_line") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Advance to game region (line 40+) where rd_en is active
                FOR i IN 0 TO LETTERBOX_TOP * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                WAIT UNTIL falling_edge(vga_hs);
                rd_count := 0;
                FOR i IN 0 TO H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    IF rd_en = '1' THEN
                        rd_count := rd_count + 1;
                    END IF;
                END LOOP;

                check_equal(rd_count, FRAME_WIDTH, "rd_en must assert 640 times per game line");

            ELSIF run("test_rd_en_gating_empty_and_busy") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Advance to game region (line 40+) where rd_en can be active
                FOR i IN 0 TO LETTERBOX_TOP * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '1', "rd_en should assert when in game region and data present");

                empty <= '1';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '0', "rd_en must deassert when empty");

                empty <= '0';
                rd_rst_busy <= '1';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '0', "rd_en must deassert while rd_rst_busy");

                rd_rst_busy <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '1', "rd_en must reassert when ready");

            ELSIF run("test_underrun_sticky") THEN
                reset_and_start;
                check_equal(underrun, '0', "underrun should start low");

                -- Advance to game region (line 40+) where underrun can trigger
                FOR i IN 0 TO LETTERBOX_TOP * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                empty <= '1';
                rd_rst_busy <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(underrun, '1', "underrun should latch high on game-region empty");

                empty <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(underrun, '1', "underrun should stay high until reset");

                rst <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                WAIT FOR 1 ps;
                check_equal(underrun, '0', "underrun should clear on reset");
                rst <= '1';
                WAIT UNTIL rising_edge(pxl_clk);

            ELSIF run("test_frame_start_pulse") THEN
                reset_and_start;
                WAIT UNTIL rising_edge(frame_start);
                t_start := now;

                WAIT FOR CLK_PERIOD / 2;
                check_equal(frame_start, '1', "frame_start should be high for one cycle");
                WAIT FOR CLK_PERIOD;
                check_equal(frame_start, '0', "frame_start should return low after one cycle");

                WAIT UNTIL rising_edge(frame_start);
                cycle_count := INTEGER((now - t_start) / CLK_PERIOD);
                check_equal(cycle_count, H_TOTAL_LINE * V_MAX_LINE, "frame_start period must be one frame");

            ELSIF run("test_frame_timing") THEN
                reset_and_start;
                WAIT UNTIL falling_edge(vga_vs);
                t_start := now;
                WAIT UNTIL falling_edge(vga_vs);
                cycle_count := INTEGER((now - t_start) / (CLK_PERIOD * H_TOTAL_LINE));
                check_equal(cycle_count, V_MAX_LINE, "frame period must be 525 lines");

            ELSIF run("test_in_vblank_level") THEN
                reset_and_start;

                WHILE in_vblank = '0' LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                vblank_high_count := 0;
                WHILE in_vblank = '1' LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    vblank_high_count := vblank_high_count + 1;
                END LOOP;

                check_equal(vblank_high_count,
                            (V_MAX_LINE - FRAME_HEIGHT) * H_TOTAL_LINE,
                            "in_vblank must be high for full vblank interval");
                check_equal(in_vblank, '0', "in_vblank must deassert at line 0");

            ELSIF run("test_bottom_letterbox_drain_fifo") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Advance to bottom letterbox drain window (line 440)
                FOR i IN 0 TO GAME_BOTTOM * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '1', "rd_en must assert while draining in bottom letterbox");

                empty <= '1';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '0', "rd_en must deassert when FIFO is empty");

                empty <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(rd_en, '1', "rd_en must reassert when data returns in drain window");

            ELSIF run("test_drain_limited_to_n_lines") THEN
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Advance to bottom letterbox drain window (line 440)
                FOR i IN 0 TO GAME_BOTTOM * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                -- Skip past drain window (5 lines)
                FOR i IN 1 TO DRAIN_LINES_C * H_TOTAL_LINE LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                -- Now at line 445, still in bottom letterbox but past drain window
                check_equal(in_vblank, '0', "still in active region after drain window");
                check_equal(rd_en, '0', "rd_en must deassert after drain window expires");

            ELSIF run("test_drain_no_underrun") THEN
                reset_and_start;

                -- Advance to bottom letterbox drain window (line 440)
                FOR i IN 0 TO GAME_BOTTOM * H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                END LOOP;

                empty <= '1';
                rd_rst_busy <= '0';
                WAIT UNTIL rising_edge(pxl_clk);
                WAIT UNTIL rising_edge(pxl_clk);
                check_equal(underrun, '0', "underrun must remain low during drain window");

            ELSIF run("test_top_letterbox_no_rd_en") THEN
                -- Verify no FIFO reads during top letterbox (lines 0-39)
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';

                -- Check first line of top letterbox
                rd_count := 0;
                FOR i IN 0 TO H_TOTAL_LINE - 1 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    IF rd_en = '1' THEN
                        rd_count := rd_count + 1;
                    END IF;
                END LOOP;
                check_equal(rd_count, 0, "rd_en must not assert during top letterbox");

            ELSIF run("test_top_letterbox_no_underrun") THEN
                -- Verify underrun does NOT latch during top letterbox empty
                reset_and_start;
                empty <= '1';
                rd_rst_busy <= '0';

                -- Stay in top letterbox (lines 0-39) with empty FIFO
                FOR i IN 0 TO 100 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    check_equal(underrun, '0', "underrun must not latch in top letterbox");
                END LOOP;

            ELSIF run("test_letterbox_outputs_black") THEN
                -- Verify top letterbox outputs black even with valid pixel data
                reset_and_start;
                empty <= '0';
                rd_rst_busy <= '0';
                pxl_data <= x"00FFFFFF"; -- White pixel data

                -- Check output during top letterbox
                FOR i IN 0 TO 10 LOOP
                    WAIT UNTIL rising_edge(pxl_clk);
                    check_equal(vga_r, STD_LOGIC_VECTOR'(x"0"), "red must be black in top letterbox");
                    check_equal(vga_g, STD_LOGIC_VECTOR'(x"0"), "green must be black in top letterbox");
                    check_equal(vga_b, STD_LOGIC_VECTOR'(x"0"), "blue must be black in top letterbox");
                END LOOP;
            END IF;
        END LOOP;

        test_runner_cleanup(runner);
    END PROCESS;

    test_runner_watchdog(runner, 100 ms);
END ARCHITECTURE;
