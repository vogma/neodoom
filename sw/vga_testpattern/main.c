// ================================================================================ //
// NEORV32 VGA test pattern writer                                                   //
// Writes RGB565 test patterns into DDR3 framebuffer for DMA -> VGA display testing //
// ================================================================================ //

#include <neorv32.h>
#include <stdint.h>

/**********************************************************************//**
 * @name User configuration
 **************************************************************************/
/**@{*/
#define BAUD_RATE           19200u
#define FRAME_BUF_BASE_0    0x10200000u
#define FRAME_BUF_BASE_1    0x10296000u
#define FRAME_WIDTH         640u
#define FRAME_HEIGHT        480u
#define FRAME_PIXELS        (FRAME_WIDTH * FRAME_HEIGHT)
#define FRAME_BYTES         (FRAME_PIXELS * 2u)
#define FRAME_WORDS         (FRAME_PIXELS / 2u) // 2x RGB565 pixels per 32-bit word
#define GPIO_SWAP_REQ_BIT   4u
#define GPIO_SWAP_SEL_BIT   5u
#define GPIO_SWAP_ACK_BIT   0u
#define SWAP_TIMEOUT_MS     100u
/**@}*/

enum {
  SWAP_OK = 0,
  SWAP_ERR_IDLE_TIMEOUT = 1,
  SWAP_ERR_ACK_TIMEOUT = 2
};

static uint32_t front_buf = 0u;
static uint32_t back_buf = 1u;
static uint32_t req_seq_shadow = 0u;

static inline uint32_t framebuffer_base(uint32_t buf) {
  return (buf == 0u) ? FRAME_BUF_BASE_0 : FRAME_BUF_BASE_1;
}

static inline void mem_barrier(void) {
  asm volatile ("fence rw, rw" ::: "memory");
}

static inline uint32_t rgb565_pack2(uint16_t px) {
  return ((uint32_t)px << 16) | (uint32_t)px;
}

static inline uint32_t gpio_get_bit(uint32_t bit) {
  return (neorv32_gpio_port_get() >> bit) & 1u;
}

static inline void gpio_set_bit(uint32_t bit, uint32_t value) {
  neorv32_gpio_pin_set((int)bit, (int)(value & 1u));
}

static inline uint32_t vga_ack_get(void) {
  return gpio_get_bit(GPIO_SWAP_ACK_BIT);
}

static inline void vga_req_drive(uint32_t seq) {
  gpio_set_bit(GPIO_SWAP_REQ_BIT, seq);
}

static inline void vga_sel_drive(uint32_t buf) {
  gpio_set_bit(GPIO_SWAP_SEL_BIT, buf);
}

static uint64_t swap_timeout_cycles(uint32_t clk_hz) {
  uint64_t timeout = ((uint64_t)clk_hz * (uint64_t)SWAP_TIMEOUT_MS) / 1000ULL;
  if (timeout == 0ULL) {
    timeout = 1ULL;
  }
  return timeout;
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

static void print_time_ms(uint64_t cycles, uint32_t clk_hz) {
  uint64_t us = ((cycles * 1000000ULL) + ((uint64_t)clk_hz / 2ULL)) / (uint64_t)clk_hz;
  uint32_t ms_i = (uint32_t)(us / 1000ULL);
  uint32_t ms_f = (uint32_t)(us % 1000ULL);
  neorv32_uart0_printf("%u.", ms_i);
  if (ms_f < 100u) {
    neorv32_uart0_putc('0');
  }
  if (ms_f < 10u) {
    neorv32_uart0_putc('0');
  }
  neorv32_uart0_printf("%u", ms_f);
}

static void fb_fill_solid(uint32_t base, uint16_t color) {
  volatile uint32_t *fb = (volatile uint32_t *)base;
  uint32_t packed = rgb565_pack2(color);

  for (uint32_t i = 0; i < FRAME_WORDS; i++) {
    fb[i] = packed;
  }
}

// 3-way bars used in OV7670_DDR_PLAN.md phase-2 display test.
static void fb_fill_rgb_bars_3(uint32_t base) {
  volatile uint16_t *fb = (volatile uint16_t *)base;

  for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
    uint32_t row = y * FRAME_WIDTH;
    for (uint32_t x = 0; x < FRAME_WIDTH; x++) {
      uint16_t px;
      if (x < 213u) {
        px = 0xF800u; // red
      }
      else if (x < 426u) {
        px = 0x07E0u; // green
      }
      else {
        px = 0x001Fu; // blue
      }
      fb[row + x] = px;
    }
  }
}

// 8 x 80px SMPTE-style bars from VGA_TESTPATTERN_PLAN.md.
static void fb_fill_color_bars_8(uint32_t base) {
  static const uint16_t bars[8] = {
    0xFFFFu, // white
    0xFFE0u, // yellow
    0x07FFu, // cyan
    0x07E0u, // green
    0xF81Fu, // magenta
    0xF800u, // red
    0x001Fu, // blue
    0x0000u  // black
  };

  volatile uint16_t *fb = (volatile uint16_t *)base;

  for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
    uint32_t row = y * FRAME_WIDTH;
    for (uint32_t x = 0; x < FRAME_WIDTH; x++) {
      uint32_t bar = x / 80u;
      if (bar > 7u) {
        bar = 7u;
      }
      fb[row + x] = bars[bar];
    }
  }
}

// Horizontal red ramp to validate 32->16 FIFO split and pixel order.
static void fb_fill_red_gradient(uint32_t base) {
  volatile uint16_t *fb = (volatile uint16_t *)base;

  for (uint32_t y = 0; y < FRAME_HEIGHT; y++) {
    uint32_t row = y * FRAME_WIDTH;
    for (uint32_t x = 0; x < FRAME_WIDTH; x++) {
      uint16_t red5 = (uint16_t)((x * 31u) / (FRAME_WIDTH - 1u));
      fb[row + x] = (uint16_t)(red5 << 11);
    }
  }
}

static void fb_readback_sample(uint32_t base) {
  volatile uint16_t *fb = (volatile uint16_t *)base;
  uint16_t p0 = fb[0];
  uint16_t p1 = fb[1];
  uint16_t pm = fb[FRAME_PIXELS / 2u];
  uint16_t pl = fb[FRAME_PIXELS - 1u];
  neorv32_uart0_printf("readback: p0=0x%x p1=0x%x pmid=0x%x plast=0x%x\n", p0, p1, pm, pl);
}

static void print_menu(void) {
  neorv32_uart0_printf("\nPattern menu:\n");
  neorv32_uart0_printf("  1 = solid red (0xF800)\n");
  neorv32_uart0_printf("  2 = solid green (0x07E0)\n");
  neorv32_uart0_printf("  3 = solid blue (0x001F)\n");
  neorv32_uart0_printf("  4 = solid white (0xFFFF)\n");
  neorv32_uart0_printf("  5 = 3 vertical bars (R/G/B)\n");
  neorv32_uart0_printf("  6 = 8 vertical color bars\n");
  neorv32_uart0_printf("  7 = horizontal red gradient\n");
  neorv32_uart0_printf("  s = print swap/handshake state\n");
  neorv32_uart0_printf("  m = print this menu\n");
  neorv32_uart0_printf("Type command key then Enter.\n");
}

static void print_state(void) {
  neorv32_uart0_printf("state: front=%u(0x%x) back=%u(0x%x) req=%u ack=%u\n",
    front_buf, framebuffer_base(front_buf), back_buf, framebuffer_base(back_buf),
    req_seq_shadow, vga_ack_get());
}

static int render_pattern(char cmd, uint32_t base) {
  switch (cmd) {
    case '1':
      fb_fill_solid(base, 0xF800u);
      neorv32_uart0_printf("pattern: solid red\n");
      return 0;
    case '2':
      fb_fill_solid(base, 0x07E0u);
      neorv32_uart0_printf("pattern: solid green\n");
      return 0;
    case '3':
      fb_fill_solid(base, 0x001Fu);
      neorv32_uart0_printf("pattern: solid blue\n");
      return 0;
    case '4':
      fb_fill_solid(base, 0xFFFFu);
      neorv32_uart0_printf("pattern: solid white\n");
      return 0;
    case '5':
      fb_fill_rgb_bars_3(base);
      neorv32_uart0_printf("pattern: 3 bars (R/G/B)\n");
      return 0;
    case '6':
      fb_fill_color_bars_8(base);
      neorv32_uart0_printf("pattern: 8 vertical color bars\n");
      return 0;
    case '7':
      fb_fill_red_gradient(base);
      neorv32_uart0_printf("pattern: horizontal red gradient\n");
      return 0;
    default:
      neorv32_uart0_printf("unknown command '%c'\n", cmd);
      return -1;
  }
}

static void apply_pattern(char cmd, uint32_t clk_hz, uint64_t timeout_cycles) {
  uint64_t start = neorv32_cpu_get_cycle();
  uint32_t target_buf = back_buf;
  uint32_t target_base = framebuffer_base(target_buf);

  neorv32_uart0_printf("render: target_buf=%u base=0x%x\n", target_buf, target_base);

  if (render_pattern(cmd, target_base) != 0) {
    return;
  }

  mem_barrier();
  uint64_t write_cycles = neorv32_cpu_get_cycle() - start;
  neorv32_uart0_printf("write time: %u cycles, ", (uint32_t)write_cycles);
  print_time_ms(write_cycles, clk_hz);
  neorv32_uart0_printf(" ms\n");
  fb_readback_sample(target_base);

  uint64_t swap_start = neorv32_cpu_get_cycle();
  int swap_rc = vga_request_swap(target_buf, timeout_cycles);
  uint64_t swap_cycles = neorv32_cpu_get_cycle() - swap_start;

  if (swap_rc == SWAP_OK) {
    uint32_t old_front = front_buf;
    front_buf = target_buf;
    back_buf = old_front;
    vga_sel_drive(back_buf); // default next target
    neorv32_uart0_printf("swap: done -> displayed buf=%u base=0x%x req=%u ack=%u, ",
      front_buf, framebuffer_base(front_buf), req_seq_shadow, vga_ack_get());
    print_time_ms(swap_cycles, clk_hz);
    neorv32_uart0_printf(" ms\n");
  }
  else {
    neorv32_uart0_printf("swap: TIMEOUT(rc=%d) target=%u req=%u ack=%u front=%u back=%u\n",
      swap_rc, target_buf, req_seq_shadow, vga_ack_get(), front_buf, back_buf);
    vga_resync_req_to_ack();
    neorv32_uart0_printf("swap: resynced req=%u ack=%u\n", req_seq_shadow, vga_ack_get());
  }
}

int main(void) {
  if (neorv32_uart0_available() == 0) {
    return 1;
  }

  neorv32_rte_setup();
  neorv32_uart0_setup(BAUD_RATE, 0);

  uint32_t clk_hz = neorv32_sysinfo_get_clk();
  uint64_t timeout_cycles = swap_timeout_cycles(clk_hz);

  if (neorv32_gpio_available() == 0) {
    neorv32_uart0_printf("ERROR: GPIO not synthesized.\n");
    return 1;
  }

  req_seq_shadow = vga_ack_get();
  vga_req_drive(req_seq_shadow);
  front_buf = 0u;
  back_buf = 1u;
  vga_sel_drive(back_buf);

  neorv32_uart0_printf("\n<<< NEORV32 VGA Test Pattern >>>\n");
  neorv32_uart0_printf("clock:         %u Hz\n", clk_hz);
  neorv32_uart0_printf("fb0 base:      0x%x\n", FRAME_BUF_BASE_0);
  neorv32_uart0_printf("fb1 base:      0x%x\n", FRAME_BUF_BASE_1);
  neorv32_uart0_printf("frame bytes:   %u (0x%x)\n", FRAME_BYTES, FRAME_BYTES);
  neorv32_uart0_printf("resolution:    %u x %u\n", FRAME_WIDTH, FRAME_HEIGHT);
  neorv32_uart0_printf("pixels:        %u\n", FRAME_PIXELS);
  neorv32_uart0_printf("gpio mapping:  req=o[%u], sel=o[%u], ack=i[%u]\n",
    GPIO_SWAP_REQ_BIT, GPIO_SWAP_SEL_BIT, GPIO_SWAP_ACK_BIT);
  neorv32_uart0_printf("swap timeout:  %u ms (%u cycles)\n",
    SWAP_TIMEOUT_MS, (uint32_t)timeout_cycles);

  fb_fill_solid(FRAME_BUF_BASE_0, 0x0000u);
  fb_fill_solid(FRAME_BUF_BASE_1, 0x0000u);
  mem_barrier();

  print_state();
  print_menu();

  // Default power-on pattern for quick visual bring-up.
  apply_pattern('6', clk_hz, timeout_cycles);

  while (1) {
    char c = neorv32_uart0_getc();
    if ((c == '\r') || (c == '\n')) {
      continue;
    }
    if (c == 'm') {
      print_menu();
      continue;
    }
    if (c == 's') {
      print_state();
      continue;
    }
    apply_pattern(c, clk_hz, timeout_cycles);
  }

  return 0;
}
