// ================================================================================ //
// NEORV32 frame read benchmark                                                      //
// Measures full VGA framebuffer read time from DDR3 and reports cycles + ms via UART//
// ================================================================================ //

#include <neorv32.h>
#include <stdint.h>

/**********************************************************************//**
 * @name User configuration
 **************************************************************************/
/**@{*/
#define BAUD_RATE               19200u
#define FRAMEBUFFER_BASE        0x10200000u
#define FRAME_WIDTH             640u
#define FRAME_HEIGHT            480u
#define FRAME_PIXELS            (FRAME_WIDTH * FRAME_HEIGHT)
#define FRAME_BYTES             (FRAME_PIXELS * 2u)    // RGB565
#define FRAME_WORDS             (FRAME_BYTES / 4u)     // 32-bit reads
#define BENCH_ITERATIONS        10u
#define TEST_COLOR_RGB565       0xF800u                // red
#define RUN_HALFWORD_COMPARISON 1u                     // 1: also benchmark 16-bit reads
/**@}*/


static volatile uint32_t read_sink = 0;


static inline void mem_barrier(void) {
  asm volatile ("fence" ::: "memory");
}

static void print_u32_padded3(uint32_t value) {
  if (value < 100u) {
    neorv32_uart0_putc('0');
  }
  if (value < 10u) {
    neorv32_uart0_putc('0');
  }
  neorv32_uart0_printf("%u", value);
}

static void print_u32_padded2(uint32_t value) {
  if (value < 10u) {
    neorv32_uart0_putc('0');
  }
  neorv32_uart0_printf("%u", value);
}

static void print_time_ms(uint64_t cycles, uint32_t clk_hz) {
  uint64_t us = ((cycles * 1000000ULL) + ((uint64_t)clk_hz / 2ULL)) / (uint64_t)clk_hz;
  uint32_t ms_i = (uint32_t)(us / 1000ULL);
  uint32_t ms_f = (uint32_t)(us % 1000ULL);
  neorv32_uart0_printf("%u.", ms_i);
  print_u32_padded3(ms_f);
}

static void print_bw_mbps(uint64_t cycles, uint32_t clk_hz) {
  uint64_t denom = cycles * 1000000ULL;
  uint64_t numer = (uint64_t)FRAME_BYTES * (uint64_t)clk_hz * 100ULL;
  uint64_t mbps_x100 = (numer + (denom / 2ULL)) / denom;
  uint32_t mbps_i = (uint32_t)(mbps_x100 / 100ULL);
  uint32_t mbps_f = (uint32_t)(mbps_x100 % 100ULL);
  neorv32_uart0_printf("%u.", mbps_i);
  print_u32_padded2(mbps_f);
}

static void seed_framebuffer(uint16_t color) {
  volatile uint32_t *fb = (volatile uint32_t *)FRAMEBUFFER_BASE;
  uint32_t seed = ((uint32_t)color << 16) | (uint32_t)color;
  for (uint32_t i = 0; i < FRAME_WORDS; i++) {
    seed = (seed * 1664525u) + 1013904223u;
    fb[i] = seed;
  }
  mem_barrier();
}

static uint64_t frame_read_32(void) {
  volatile uint32_t *fb = (volatile uint32_t *)FRAMEBUFFER_BASE;
  uint32_t acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;

  mem_barrier();
  uint64_t start = neorv32_cpu_get_cycle();
  uint32_t i = 0;
  for (; (i + 3u) < FRAME_WORDS; i += 4u) {
    acc0 ^= fb[i + 0u];
    acc1 ^= fb[i + 1u];
    acc2 ^= fb[i + 2u];
    acc3 ^= fb[i + 3u];
  }
  for (; i < FRAME_WORDS; i++) {
    acc0 ^= fb[i];
  }
  mem_barrier();
  uint64_t stop = neorv32_cpu_get_cycle();

  read_sink ^= (acc0 ^ acc1 ^ acc2 ^ acc3);
  return (stop - start);
}

static uint64_t frame_read_16(void) {
  volatile uint16_t *fb = (volatile uint16_t *)FRAMEBUFFER_BASE;
  uint32_t acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;

  mem_barrier();
  uint64_t start = neorv32_cpu_get_cycle();
  uint32_t i = 0;
  for (; (i + 3u) < FRAME_PIXELS; i += 4u) {
    acc0 ^= fb[i + 0u];
    acc1 ^= fb[i + 1u];
    acc2 ^= fb[i + 2u];
    acc3 ^= fb[i + 3u];
  }
  for (; i < FRAME_PIXELS; i++) {
    acc0 ^= fb[i];
  }
  mem_barrier();
  uint64_t stop = neorv32_cpu_get_cycle();

  read_sink ^= (acc0 ^ acc1 ^ acc2 ^ acc3);
  return (stop - start);
}

static void print_result_line(uint32_t idx, uint64_t cycles, uint32_t clk_hz) {
  neorv32_uart0_printf("frame %u: cycles=%u, time=", idx, (uint32_t)cycles);
  print_time_ms(cycles, clk_hz);
  neorv32_uart0_printf(" ms, bw=");
  print_bw_mbps(cycles, clk_hz);
  neorv32_uart0_printf(" MB/s\n");
}

static void print_dcache_info(void) {
  uint32_t soc = NEORV32_SYSINFO->SOC;
  uint32_t cache = NEORV32_SYSINFO->CACHE;

  neorv32_uart0_printf("d-cache:      ");
  if (soc & (1u << SYSINFO_SOC_DCACHE)) {
    uint32_t dc_block_size = (cache >> SYSINFO_CACHE_DATA_BLOCK_SIZE_0) & 0x0Fu;
    dc_block_size = 1u << dc_block_size;

    uint32_t dc_num_blocks = (cache >> SYSINFO_CACHE_DATA_NUM_BLOCKS_0) & 0x0Fu;
    dc_num_blocks = 1u << dc_num_blocks;

    neorv32_uart0_printf("%u bytes (%ux%u)", dc_num_blocks * dc_block_size, dc_num_blocks, dc_block_size);
  }
  else {
    neorv32_uart0_printf("none");
  }

  if (cache & (1u << SYSINFO_CACHE_DATA_BURSTS_EN)) {
    neorv32_uart0_printf(", bursts enabled\n");
  }
  else {
    neorv32_uart0_printf(", bursts disabled\n");
  }
}

static void run_benchmark(const char *label, uint8_t halfword_mode, uint32_t clk_hz) {
  uint64_t total = 0;
  uint64_t min_cycles = ~0ULL;
  uint64_t max_cycles = 0;

  neorv32_uart0_printf("\n%s\n", label);
  for (uint32_t i = 0; i < BENCH_ITERATIONS; i++) {
    uint64_t cycles = halfword_mode ? frame_read_16() : frame_read_32();
    total += cycles;
    if (cycles < min_cycles) {
      min_cycles = cycles;
    }
    if (cycles > max_cycles) {
      max_cycles = cycles;
    }
    print_result_line(i, cycles, clk_hz);
  }

  uint64_t avg_cycles = total / (uint64_t)BENCH_ITERATIONS;
  uint32_t cyc_60fps = clk_hz / 60u;
  uint32_t cyc_30fps = clk_hz / 30u;

  neorv32_uart0_printf("summary: min=%u, avg=%u, max=%u cycles\n",
    (uint32_t)min_cycles, (uint32_t)avg_cycles, (uint32_t)max_cycles);
  neorv32_uart0_printf("avg frame time: ");
  print_time_ms(avg_cycles, clk_hz);
  neorv32_uart0_printf(" ms\n");

  if (avg_cycles <= (uint64_t)cyc_60fps) {
    neorv32_uart0_printf("budget check: PASS for 60 fps full-frame reads\n");
  }
  else if (avg_cycles <= (uint64_t)cyc_30fps) {
    neorv32_uart0_printf("budget check: FAIL for 60 fps, PASS for 30 fps\n");
  }
  else {
    neorv32_uart0_printf("budget check: FAIL for 30 fps and 60 fps\n");
  }
}

int main(void) {
  if (neorv32_uart0_available() == 0) {
    return 1;
  }

  neorv32_rte_setup();
  neorv32_uart0_setup(BAUD_RATE, 0);

  uint32_t clk_hz = neorv32_sysinfo_get_clk();
  uint32_t packed_color = ((uint32_t)TEST_COLOR_RGB565 << 16) | (uint32_t)TEST_COLOR_RGB565;

  neorv32_uart0_printf("\n<<< NEORV32 Frame Read Benchmark >>>\n\n");
  neorv32_uart0_printf("clock:        %u Hz\n", clk_hz);
  neorv32_uart0_printf("fb base:      0x%x\n", FRAMEBUFFER_BASE);
  neorv32_uart0_printf("resolution:   %u x %u\n", FRAME_WIDTH, FRAME_HEIGHT);
  neorv32_uart0_printf("frame size:   %u bytes (%u words)\n", FRAME_BYTES, FRAME_WORDS);
  neorv32_uart0_printf("iterations:   %u\n", BENCH_ITERATIONS);
  neorv32_uart0_printf("seed color:   RGB565=0x%x (packed=0x%x)\n", TEST_COLOR_RGB565, packed_color);
  print_dcache_info();

  neorv32_uart0_printf("seeding framebuffer...\n");
  seed_framebuffer(TEST_COLOR_RGB565);

  run_benchmark("32-bit load benchmark (recommended path)", 0, clk_hz);

#if (RUN_HALFWORD_COMPARISON != 0)
  run_benchmark("16-bit load benchmark (comparison)", 1, clk_hz);
#endif

  volatile uint32_t *fb = (volatile uint32_t *)FRAMEBUFFER_BASE;
  uint32_t first = fb[0];
  uint32_t middle = fb[FRAME_WORDS / 2u];
  uint32_t last = fb[FRAME_WORDS - 1u];
  neorv32_uart0_printf("\nreadback words: first=0x%x middle=0x%x last=0x%x\n", first, middle, last);
  neorv32_uart0_printf("read sink: 0x%x\n", read_sink);
  neorv32_uart0_printf("done.\n");

  while (1) {
    asm volatile ("wfi");
  }

  return 0;
}
