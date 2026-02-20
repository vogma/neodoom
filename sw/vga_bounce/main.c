// ============================================================================ //
// NEORV32 VGA bounce demo                                                      //
// Bouncing rectangle on a black background via double-buffer DMA handshake.   //
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
#define FRAME_WORDS         (FRAME_PIXELS / 2u)    // 2x RGB565 per 32-bit word

#define GPIO_SWAP_REQ_BIT   4u
#define GPIO_SWAP_SEL_BIT   5u
#define GPIO_SWAP_ACK_BIT   0u
#define SWAP_TIMEOUT_MS     100u

// Rectangle size.  Both RECT_W and starting X must be even so that
// all row writes stay 32-bit-word-aligned in the frame buffer.
#define RECT_W              80u
#define RECT_H              60u
#define RECT_DX_INIT        4     // pixels per frame (even keeps X even)
#define RECT_DY_INIT        3     // pixels per frame

// Print a one-line status to UART every this many successfully swapped frames.
#define LOG_INTERVAL        120u
/**@}*/

// ---------------------------------------------------------------------------
// Swap handshake
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
// Drawing primitives
// ---------------------------------------------------------------------------

// Fill entire buffer with a solid color using 32-bit (2-pixel) writes.
static void fb_fill_solid(uint32_t base, uint16_t color) {
    volatile uint32_t *fb = (volatile uint32_t *)base;
    uint32_t packed = ((uint32_t)color << 16) | (uint32_t)color;
    for (uint32_t i = 0u; i < FRAME_WORDS; i++) {
        fb[i] = packed;
    }
}

// Fill a rectangle with a solid color using 32-bit (2-pixel) writes.
// Precondition: x and w must both be even (guaranteed by design).
static void fb_fill_rect(uint32_t base,
                         int32_t  x,  int32_t  y,
                         uint32_t w,  uint32_t h,
                         uint16_t color) {
    volatile uint32_t *fb = (volatile uint32_t *)base;
    uint32_t packed     = ((uint32_t)color << 16) | (uint32_t)color;
    uint32_t half_pitch = FRAME_WIDTH / 2u;   // words per row
    uint32_t x32        = (uint32_t)x / 2u;
    uint32_t w32        = w / 2u;

    for (uint32_t row = (uint32_t)y; row < (uint32_t)y + h; row++) {
        volatile uint32_t *dst = fb + row * half_pitch + x32;
        for (uint32_t col = 0u; col < w32; col++) {
            dst[col] = packed;
        }
    }
}

// ---------------------------------------------------------------------------
// Rectangle bounce state
// ---------------------------------------------------------------------------

// Colors the rectangle cycles through on each bounce (RGB565).
static const uint16_t rect_colors[] = {
    0xFFFFu,   // white
    0xFFE0u,   // yellow
    0x07FFu,   // cyan
    0xF81Fu,   // magenta
    0xF800u,   // red
    0x07E0u,   // green
    0x001Fu,   // blue
};
#define NUM_COLORS ((uint32_t)(sizeof(rect_colors) / sizeof(rect_colors[0])))

// Per-buffer record of the last rectangle position drawn into it.
// Needed because the back buffer is two swaps old: we erase the old
// rectangle in that buffer before drawing the new position.
typedef struct {
    int32_t  x;
    int32_t  y;
    uint32_t valid;  // 0 = nothing drawn yet, no erase needed
} rect_stamp_t;

static rect_stamp_t stamp[2];

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

    // Sync req shadow to current ack so no spurious toggle at boot.
    req_seq_shadow = vga_ack_get();
    vga_req_drive(req_seq_shadow);
    front_buf = 0u;
    back_buf  = 1u;
    vga_sel_drive(back_buf);

    neorv32_uart0_printf("\n<<< NEORV32 VGA Bounce Demo >>>\n");
    neorv32_uart0_printf("clock:      %u Hz\n", clk_hz);
    neorv32_uart0_printf("fb0 base:   0x%x\n", FRAME_BUF_BASE_0);
    neorv32_uart0_printf("fb1 base:   0x%x\n", FRAME_BUF_BASE_1);
    neorv32_uart0_printf("rect:       %u x %u, dx=%d dy=%d\n",
                         RECT_W, RECT_H, RECT_DX_INIT, RECT_DY_INIT);
    neorv32_uart0_printf("gpio:       req=o[%u] sel=o[%u] ack=i[%u]\n",
                         GPIO_SWAP_REQ_BIT, GPIO_SWAP_SEL_BIT, GPIO_SWAP_ACK_BIT);

    // Fill both buffers with black so there is no stale content on first display.
    fb_fill_solid(FRAME_BUF_BASE_0, 0x0000u);
    fb_fill_solid(FRAME_BUF_BASE_1, 0x0000u);
    mem_barrier();

    stamp[0].valid = 0u;
    stamp[1].valid = 0u;

    // Starting position: centered, must be even in X.
    int32_t  rx        = (int32_t)((FRAME_WIDTH  - RECT_W) / 2u);  // 280, even
    int32_t  ry        = (int32_t)((FRAME_HEIGHT - RECT_H) / 2u);  // 210
    int32_t  rdx       = RECT_DX_INIT;
    int32_t  rdy       = RECT_DY_INIT;
    uint32_t color_idx = 0u;
    uint32_t frame_cnt = 0u;

    neorv32_uart0_printf("starting animation...\n");

    while (1) {
        uint32_t b    = back_buf;
        uint32_t base = framebuffer_base(b);

        // 1. Erase the rectangle's previous position in this buffer.
        if (stamp[b].valid) {
            fb_fill_rect(base, stamp[b].x, stamp[b].y, RECT_W, RECT_H, 0x0000u);
        }

        // 2. Draw the rectangle at its current position.
        fb_fill_rect(base, rx, ry, RECT_W, RECT_H, rect_colors[color_idx]);

        // 3. Record draw position so it can be erased next time this buffer is used.
        stamp[b].x     = rx;
        stamp[b].y     = ry;
        stamp[b].valid = 1u;

        mem_barrier();

        // 4. Request a buffer swap.
        int rc = vga_request_swap(b, timeout_cycles);
        if (rc != SWAP_OK) {
            neorv32_uart0_printf("swap TIMEOUT rc=%d frame=%u req=%u ack=%u\n",
                                 rc, frame_cnt, req_seq_shadow, vga_ack_get());
            vga_resync_req_to_ack();
            // Retry the same frame position rather than advancing.
            continue;
        }

        // 5. Commit swap in software.
        {
            uint32_t tmp = front_buf;
            front_buf    = b;
            back_buf     = tmp;
        }
        // vga_sel_drive(back_buf);

        // 6. Advance rectangle position and bounce off walls.
        rx += rdx;
        ry += rdy;

        int bounced = 0;

        if (rx < 0) {
            rx   = 0;
            rdx  = -rdx;
            bounced = 1;
        } else if (rx + (int32_t)RECT_W > (int32_t)FRAME_WIDTH) {
            rx   = (int32_t)FRAME_WIDTH - (int32_t)RECT_W;
            rdx  = -rdx;
            bounced = 1;
        }

        if (ry < 0) {
            ry   = 0;
            rdy  = -rdy;
            bounced = 1;
        } else if (ry + (int32_t)RECT_H > (int32_t)FRAME_HEIGHT) {
            ry   = (int32_t)FRAME_HEIGHT - (int32_t)RECT_H;
            rdy  = -rdy;
            bounced = 1;
        }

        if (bounced) {
            color_idx = (color_idx + 1u) % NUM_COLORS;
        }

        frame_cnt++;

        if ((frame_cnt % LOG_INTERVAL) == 0u) {
            neorv32_uart0_printf("frame=%u rect=(%d,%d) dx=%d dy=%d color=%u front=%u\n",
                                 frame_cnt, rx, ry, rdx, rdy, color_idx, front_buf);
        }
    }

    return 0;
}
