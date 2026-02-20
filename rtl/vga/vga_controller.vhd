LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY vga_controller IS
    PORT (
        rst : IN STD_LOGIC;
        pxl_clk : IN STD_LOGIC;
        VGA_HS_O : OUT STD_LOGIC;
        VGA_VS_O : OUT STD_LOGIC;
        VGA_R : OUT STD_LOGIC_VECTOR (3 DOWNTO 0);
        VGA_B : OUT STD_LOGIC_VECTOR (3 DOWNTO 0);
        VGA_G : OUT STD_LOGIC_VECTOR (3 DOWNTO 0);

        --   FIFO   --
        empty : IN STD_LOGIC;
        pxl_data : IN STD_LOGIC_VECTOR(15 DOWNTO 0);
        rd_en : OUT STD_LOGIC;
        rd_rst_busy_i : IN STD_LOGIC;

        -- Status/sync outputs
        in_vblank_o : OUT STD_LOGIC;
        frame_start_o : OUT STD_LOGIC;
        underrun_o : OUT STD_LOGIC
    );
END vga_controller;

ARCHITECTURE rtl OF vga_controller IS
    --***640x480@60Hz***--  Requires 25 MHz clock
    CONSTANT FRAME_WIDTH : NATURAL := 640;
    CONSTANT FRAME_HEIGHT : NATURAL := 480;
    CONSTANT DRAIN_LINES_C : NATURAL := 5;

    CONSTANT H_FRONT_PORCH : NATURAL := 16;
    CONSTANT H_SYNC_PULSE_WIDTH : NATURAL := 96;
    CONSTANT H_TOTAL_LINE : NATURAL := 800;

    CONSTANT V_FRONT_PORCH : NATURAL := 10;
    CONSTANT V_SYNC_PULSE_WIDTH : NATURAL := 2;
    CONSTANT V_MAX_LINE : NATURAL := 525;

    SIGNAL hsync_reg, hsync_next : INTEGER RANGE 0 TO H_TOTAL_LINE - 1 := 0;
    SIGNAL vsync_reg, vsync_next : INTEGER RANGE 0 TO V_MAX_LINE - 1 := 0;

    SIGNAL line_finished : STD_LOGIC := '0';
    SIGNAL frame_finished : STD_LOGIC := '0';

    SIGNAL rd_en_int : STD_LOGIC := '0';
    SIGNAL in_active_video : STD_LOGIC := '0';
    SIGNAL in_vblank, in_vblank_reg : STD_LOGIC := '0';
    SIGNAL in_drain_window : STD_LOGIC := '0';
    SIGNAL underrun_sticky : STD_LOGIC := '0';

BEGIN
    -- Output port assignments
    rd_en <= rd_en_int;
    in_vblank_o <= in_vblank_reg;
    frame_start_o <= line_finished AND frame_finished;
    underrun_o <= underrun_sticky;

    -- Horizontal counter
    line_finished <= '1' WHEN hsync_reg = H_TOTAL_LINE - 1 ELSE '0';
    hsync_next <= 0 WHEN hsync_reg = H_TOTAL_LINE - 1 ELSE hsync_reg + 1;

    -- Vertical counter
    frame_finished <= '1' WHEN vsync_reg = V_MAX_LINE - 1 ELSE '0';
    vsync_next <= 0 WHEN vsync_reg = V_MAX_LINE - 1 AND hsync_reg = H_TOTAL_LINE - 1 ELSE
        vsync_reg + 1 WHEN hsync_reg = H_TOTAL_LINE - 1 ELSE
        vsync_reg;

    -- Sync pulse generation (active-low for 640x480@60Hz)
    VGA_HS_O <= '0' WHEN hsync_reg >= (H_FRONT_PORCH + FRAME_WIDTH) AND hsync_reg < (H_FRONT_PORCH + FRAME_WIDTH + H_SYNC_PULSE_WIDTH) ELSE
        '1';

    VGA_VS_O <= '0' WHEN vsync_reg >= (V_FRONT_PORCH + FRAME_HEIGHT) AND vsync_reg < (V_FRONT_PORCH + FRAME_HEIGHT + V_SYNC_PULSE_WIDTH) ELSE
        '1';

    -- Active video region
    in_active_video <= '1' WHEN hsync_reg < FRAME_WIDTH AND vsync_reg < FRAME_HEIGHT ELSE '0';
    in_vblank <= '1' WHEN vsync_reg >= FRAME_HEIGHT ELSE '0';
    in_drain_window <= '1' WHEN vsync_reg >= FRAME_HEIGHT AND vsync_reg < FRAME_HEIGHT + DRAIN_LINES_C ELSE '0';

    -- FIFO read enable (FWFT mode: dout valid when empty='0', rd_en advances)
    rd_en_int <= '1' WHEN rst = '1'
                      AND rd_rst_busy_i = '0'
                      AND empty = '0'
                      AND (in_active_video = '1' OR in_drain_window = '1')
                 ELSE '0';

    -- RGB565 -> RGB444 (take top 4 bits of each channel)
    vga_r <= pxl_data(15 DOWNTO 12) WHEN in_active_video = '1' AND empty = '0' AND rst = '1' ELSE "0000";
    vga_g <= pxl_data(10 DOWNTO 7) WHEN in_active_video = '1' AND empty = '0' AND rst = '1' ELSE "0000";
    vga_b <= pxl_data(4 DOWNTO 1) WHEN in_active_video = '1' AND empty = '0' AND rst = '1' ELSE "0000";

    -- Counter/state update with synchronous active-low reset
    PROCESS (pxl_clk)
    BEGIN
        IF rising_edge(pxl_clk) THEN
            IF rst = '0' THEN
                hsync_reg <= 0;
                vsync_reg <= 0;
                underrun_sticky <= '0';
                in_vblank_reg <= '0';
            ELSE
                hsync_reg <= hsync_next;
                vsync_reg <= vsync_next;
                in_vblank_reg <= in_vblank;
                IF in_active_video = '1' AND empty = '1' AND rd_rst_busy_i = '0' THEN
                    underrun_sticky <= '1';
                END IF;
            END IF;
        END IF;
    END PROCESS;
END ARCHITECTURE;
