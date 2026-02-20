// ============================================================================ //
// NEORV32 VGA Plasma Demo                                                      //
// Animated color plasma effect with full-screen repaint each frame.            //
// Classic demoscene-style effect using integer sine lookup tables.             //
// ============================================================================ //

#include <neorv32.h>
#include <stdint.h>

/**********************************************************************//**
 * @name Configuration
 **************************************************************************/
/**@{*/
#define BAUD_RATE           19200u
#define FRAME_BUF_BASE_0    0x10200000u
#define FRAME_BUF_BASE_1    0x10296000u
#define FRAME_WIDTH         640u
#define FRAME_HEIGHT        480u
#define FRAME_PIXELS        (FRAME_WIDTH * FRAME_HEIGHT)
#define FRAME_WORDS         (FRAME_PIXELS / 2u)

#define GPIO_SWAP_REQ_BIT   4u
#define GPIO_SWAP_SEL_BIT   5u
#define GPIO_SWAP_ACK_BIT   0u
#define SWAP_TIMEOUT_MS     100u

#define LOG_INTERVAL        60u
/**@}*/

// ---------------------------------------------------------------------------
// Sine lookup table (256 entries, values 0-255)
// Used for plasma wave calculations
// ---------------------------------------------------------------------------
static const uint8_t sine_lut[256] = {
    128,131,134,137,140,143,146,149,152,155,158,162,165,167,170,173,
    176,179,182,185,188,190,193,196,198,201,203,206,208,211,213,215,
    218,220,222,224,226,228,230,232,234,235,237,238,240,241,243,244,
    245,246,248,249,250,250,251,252,253,253,254,254,254,255,255,255,
    255,255,255,255,254,254,254,253,253,252,251,250,250,249,248,246,
    245,244,243,241,240,238,237,235,234,232,230,228,226,224,222,220,
    218,215,213,211,208,206,203,201,198,196,193,190,188,185,182,179,
    176,173,170,167,165,162,158,155,152,149,146,143,140,137,134,131,
    128,124,121,118,115,112,109,106,103,100, 97, 93, 90, 88, 85, 82,
     79, 76, 73, 70, 67, 65, 62, 59, 57, 54, 52, 49, 47, 44, 42, 40,
     37, 35, 33, 31, 29, 27, 25, 23, 21, 20, 18, 17, 15, 14, 12, 11,
     10,  9,  7,  6,  5,  5,  4,  3,  2,  2,  1,  1,  1,  0,  0,  0,
      0,  0,  0,  0,  1,  1,  1,  2,  2,  3,  4,  5,  5,  6,  7,  9,
     10, 11, 12, 14, 15, 17, 18, 20, 21, 23, 25, 27, 29, 31, 33, 35,
     37, 40, 42, 44, 47, 49, 52, 54, 57, 59, 62, 65, 67, 70, 73, 76,
     79, 82, 85, 88, 90, 93, 97,100,103,106,109,112,115,118,121,124
};

// ---------------------------------------------------------------------------
// Color palette (32 colors for smooth gradients)
// RGB565 format: RRRRRGGGGGGBBBBB
// ---------------------------------------------------------------------------
static const uint16_t palette[32] = {
    // Deep blue -> cyan -> green -> yellow -> red -> magenta -> back to blue
    0x0010, 0x0030, 0x0050, 0x0070,  // dark blue to blue
    0x0090, 0x00B0, 0x00D0, 0x00F0,  // blue to cyan
    0x07F0, 0x0FE0, 0x1FE0, 0x3FE0,  // cyan to green
    0x5FE0, 0x7FE0, 0x9FE0, 0xBFE0,  // green
    0xDFE0, 0xFFE0, 0xFFC0, 0xFF80,  // green to yellow
    0xFF40, 0xFF00, 0xFE00, 0xFC00,  // yellow to red
    0xFA00, 0xF800, 0xF802, 0xF804,  // red
    0xF808, 0xF80C, 0xF810, 0xF014   // red to magenta
};

// ---------------------------------------------------------------------------
// Swap handshake (same as bounce demo)
// ---------------------------------------------------------------------------

enum {
    SWAP_OK = 0,
    SWAP_ERR_IDLE_TIMEOUT = 1,
    SWAP_ERR_ACK_TIMEOUT  = 2
};

static uint32_t front_buf      = 0u;
static uint32_t back_buf       = 1u;
static uint32_t req_seq_shadow = 0u;

static inline uint32_t framebuffer_base(uint32_t buf) {
    return (buf == 0u) ? FRAME_BUF_BASE_0 : FRAME_BUF_BASE_1;
}

static inline void mem_barrier(void) {
    asm volatile ("fence rw, rw" ::: "memory");
}

static inline uint32_t vga_ack_get(void) {
    return (neorv32_gpio_port_get() >> GPIO_SWAP_ACK_BIT) & 1u;
}

static inline void vga_req_drive(uint32_t seq) {
    neorv32_gpio_pin_set((int)GPIO_SWAP_REQ_BIT, (int)(seq & 1u));
}

static inline void vga_sel_drive(uint32_t buf) {
    neorv32_gpio_pin_set((int)GPIO_SWAP_SEL_BIT, (int)(buf & 1u));
}

static uint64_t swap_timeout_cycles(uint32_t clk_hz) {
    uint64_t t = ((uint64_t)clk_hz * (uint64_t)SWAP_TIMEOUT_MS) / 1000ULL;
    return t ? t : 1ULL;
}

static int wait_for_ack_eq_req(uint64_t timeout_cycles) {
    uint64_t start = neorv32_cpu_get_cycle();
    while (vga_ack_get() != req_seq_shadow) {
        if ((neorv32_cpu_get_cycle() - start) >= timeout_cycles) {
            return -1;
        }
    }
    return 0;
}

static int vga_request_swap(uint32_t target_buf, uint64_t timeout_cycles) {
    if (wait_for_ack_eq_req(timeout_cycles) != 0) {
        return SWAP_ERR_IDLE_TIMEOUT;
    }
    vga_sel_drive(target_buf);
    mem_barrier();
    req_seq_shadow ^= 1u;
    vga_req_drive(req_seq_shadow);
    if (wait_for_ack_eq_req(timeout_cycles) != 0) {
        return SWAP_ERR_ACK_TIMEOUT;
    }
    return SWAP_OK;
}

static void vga_resync_req_to_ack(void) {
    req_seq_shadow = vga_ack_get();
    vga_req_drive(req_seq_shadow);
}

// ---------------------------------------------------------------------------
// Plasma rendering
// ---------------------------------------------------------------------------

// Render a full frame of animated plasma
// The plasma is created by combining multiple sine waves at different frequencies
// and using the result to index into a color palette.
static void render_plasma(uint32_t base, uint32_t frame) {
    volatile uint16_t *fb = (volatile uint16_t *)base;

    // Pre-calculate time-varying offsets for the plasma waves
    uint8_t t1 = (uint8_t)(frame * 3);       // slow rotation
    uint8_t t2 = (uint8_t)(frame * 5);       // medium rotation
    uint8_t t3 = (uint8_t)(frame * 2);       // another slow component

    for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
        uint32_t row_offset = y * FRAME_WIDTH;

        // Pre-calculate y-dependent sine values
        uint8_t sin_y1 = sine_lut[(uint8_t)(y + t1)];
        uint8_t sin_y2 = sine_lut[(uint8_t)((y >> 1) + t2)];

        for (uint32_t x = 0; x < FRAME_WIDTH; x++) {
            // Combine multiple sine waves for the plasma effect:
            // 1. Horizontal wave
            uint8_t sin_x1 = sine_lut[(uint8_t)(x + t2)];

            // 2. Diagonal wave
            uint8_t sin_diag = sine_lut[(uint8_t)((x >> 1) + (y >> 1) + t3)];

            // 3. Radial component (approximated with x+y for speed)
            uint8_t sin_rad = sine_lut[(uint8_t)(((x >> 2) ^ (y >> 2)) + t1)];

            // Combine all components and map to palette
            uint32_t plasma_val = (uint32_t)sin_x1 + (uint32_t)sin_y1 +
                                  (uint32_t)sin_y2 + (uint32_t)sin_diag +
                                  (uint32_t)sin_rad;

            // Scale to palette index (0-31)
            uint8_t color_idx = (uint8_t)((plasma_val >> 5) & 0x1F);

            fb[row_offset + x] = palette[color_idx];
        }
    }
}

// Faster version: renders diagonal rainbow stripes that animate
// Uses 32-bit writes for better throughput
static void render_diagonal_stripes(uint32_t base, uint32_t frame) {
    volatile uint32_t *fb = (volatile uint32_t *)base;
    uint32_t half_pitch = FRAME_WIDTH / 2u;

    for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
        volatile uint32_t *row = fb + y * half_pitch;

        for (uint32_t x = 0; x < FRAME_WIDTH; x += 2) {
            // Diagonal stripe pattern with animation
            uint8_t idx1 = (uint8_t)((x + y + frame * 4) >> 4) & 0x1F;
            uint8_t idx2 = (uint8_t)((x + 1 + y + frame * 4) >> 4) & 0x1F;

            // Pack two pixels into one 32-bit word (little-endian: px0 in low bits)
            uint32_t packed = ((uint32_t)palette[idx2] << 16) | (uint32_t)palette[idx1];
            row[x >> 1] = packed;
        }
    }
}

// Hypnotic concentric rings that pulse outward from center
static void render_rings(uint32_t base, uint32_t frame) {
    volatile uint16_t *fb = (volatile uint16_t *)base;

    int32_t cx = FRAME_WIDTH / 2;
    int32_t cy = FRAME_HEIGHT / 2;

    for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
        uint32_t row_offset = y * FRAME_WIDTH;
        int32_t dy = (int32_t)y - cy;
        int32_t dy2 = dy * dy;

        for (uint32_t x = 0; x < FRAME_WIDTH; x++) {
            int32_t dx = (int32_t)x - cx;

            // Approximate distance from center (using dx^2 + dy^2, then rough sqrt via shift)
            int32_t dist_sq = dx * dx + dy2;

            // Rough distance approximation (we just need relative values)
            // Use the squared distance directly, scaled down
            uint8_t dist = (uint8_t)(dist_sq >> 8);

            // Create ring pattern: distance + time offset
            uint8_t ring_val = sine_lut[(uint8_t)(dist - frame * 6)];

            // Map to palette
            uint8_t color_idx = ring_val >> 3;  // 0-31

            fb[row_offset + x] = palette[color_idx];
        }
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(void) {
    if (neorv32_uart0_available() == 0) {
        return 1;
    }

    neorv32_rte_setup();
    neorv32_uart0_setup(BAUD_RATE, 0);

    uint32_t clk_hz         = neorv32_sysinfo_get_clk();
    uint64_t timeout_cycles = swap_timeout_cycles(clk_hz);

    if (neorv32_gpio_available() == 0) {
        neorv32_uart0_printf("ERROR: GPIO not synthesized.\n");
        return 1;
    }

    // Sync req shadow to current ack
    req_seq_shadow = vga_ack_get();
    vga_req_drive(req_seq_shadow);
    front_buf = 0u;
    back_buf  = 1u;
    vga_sel_drive(back_buf);

    neorv32_uart0_printf("\n<<< NEORV32 VGA Plasma Demo >>>\n");
    neorv32_uart0_printf("clock:      %u Hz\n", clk_hz);
    neorv32_uart0_printf("fb0 base:   0x%x\n", FRAME_BUF_BASE_0);
    neorv32_uart0_printf("fb1 base:   0x%x\n", FRAME_BUF_BASE_1);
    neorv32_uart0_printf("resolution: %u x %u\n", FRAME_WIDTH, FRAME_HEIGHT);
    neorv32_uart0_printf("\nEffects: 1=plasma, 2=stripes, 3=rings\n");
    neorv32_uart0_printf("Press key to switch effect.\n");

    uint32_t frame_cnt = 0u;
    uint32_t effect = 1u;  // Start with plasma

    neorv32_uart0_printf("starting animation...\n");

    while (1) {
        uint32_t b    = back_buf;
        uint32_t base = framebuffer_base(b);

        uint64_t render_start = neorv32_cpu_get_cycle();

        // Render the selected effect
        switch (effect) {
            case 1:
                render_plasma(base, frame_cnt);
                break;
            case 2:
                render_diagonal_stripes(base, frame_cnt);
                break;
            case 3:
                render_rings(base, frame_cnt);
                break;
            default:
                render_plasma(base, frame_cnt);
                break;
        }

        uint64_t render_cycles = neorv32_cpu_get_cycle() - render_start;

        mem_barrier();

        // Request buffer swap
        int rc = vga_request_swap(b, timeout_cycles);
        if (rc != SWAP_OK) {
            neorv32_uart0_printf("swap TIMEOUT rc=%d frame=%u\n", rc, frame_cnt);
            vga_resync_req_to_ack();
            continue;
        }

        // Commit swap
        {
            uint32_t tmp = front_buf;
            front_buf    = b;
            back_buf     = tmp;
        }

        frame_cnt++;

        // Log every N frames
        if ((frame_cnt % LOG_INTERVAL) == 0u) {
            uint32_t render_us = (uint32_t)((render_cycles * 1000000ULL) / (uint64_t)clk_hz);
            neorv32_uart0_printf("frame=%u effect=%u render=%u us\n",
                                 frame_cnt, effect, render_us);
        }

        // Check for keypress to switch effects (non-blocking)
        if (neorv32_uart0_char_received()) {
            char c = neorv32_uart0_getc();
            if (c == '1') {
                effect = 1;
                neorv32_uart0_printf("switched to: plasma\n");
            } else if (c == '2') {
                effect = 2;
                neorv32_uart0_printf("switched to: diagonal stripes\n");
            } else if (c == '3') {
                effect = 3;
                neorv32_uart0_printf("switched to: rings\n");
            }
        }
    }

    return 0;
}
