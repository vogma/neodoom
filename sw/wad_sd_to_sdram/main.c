// ============================================================================
// WAD SD -> SDRAM Loader
// Loads DOOM1.WAD from SD-card root directory to SDRAM and prints transfer time.
// ============================================================================

#include <neorv32.h>
#include <stdint.h>
#include "pff.h"

#define BAUD_RATE         115200u
#define WAD_FILE_NAME     "DOOM1.WAD"

#define WAD_DST_ADDR      0x15000000u
#define WAD_MAX_BYTES     (8u * 1024u * 1024u)
#define READ_CHUNK_BYTES  4096u

// Slow clock for card init, faster clock for bulk transfer.
#define SD_SPI_INIT_PRSC  CLK_PRSC_1024
#define SD_SPI_INIT_CDIV  1
#define SD_SPI_RUN_PRSC   CLK_PRSC_2
#define SD_SPI_RUN_CDIV   0

static FATFS fs;

static int setup_uart(void) {
  if (neorv32_uart0_available() == 0) {
    return -1;
  }
  neorv32_uart0_setup(BAUD_RATE, 0);
  return 0;
}

static int setup_spi_for_sd(void) {
  if (neorv32_spi_available() == 0) {
    return -1;
  }
  neorv32_spi_setup(SD_SPI_INIT_PRSC, SD_SPI_INIT_CDIV, 0, 0);
  return 0;
}

static void print_pf_error(const char *step, FRESULT fr) {
  neorv32_uart0_printf("ERROR: %s failed (FRESULT=%u)\n", step, (uint32_t)fr);
}

int main(void) {
  if (setup_uart() != 0) {
    return 1;
  }

  neorv32_rte_setup();
  neorv32_uart0_printf("\nWAD SD->SDRAM loader\n");
  neorv32_uart0_printf("CPU clock: %u Hz\n", neorv32_sysinfo_get_clk());

  if (setup_spi_for_sd() != 0) {
    neorv32_uart0_printf("ERROR: SPI not synthesized.\n");
    return 1;
  }

  neorv32_uart0_printf("SPI init clock: %u Hz\n", neorv32_spi_get_clock_speed());

  FRESULT fr = pf_mount(&fs);
  if (fr != FR_OK) {
    print_pf_error("pf_mount", fr);
    return 1;
  }

  fr = pf_open(WAD_FILE_NAME);
  if (fr != FR_OK) {
    print_pf_error("pf_open", fr);
    return 1;
  }

  // Switch to faster SPI clock after card + filesystem init.
  neorv32_spi_setup(SD_SPI_RUN_PRSC, SD_SPI_RUN_CDIV, 0, 0);
  neorv32_uart0_printf("SPI run clock:  %u Hz\n", neorv32_spi_get_clock_speed());
  neorv32_uart0_printf("Copying %s -> 0x%08x (max %u bytes)\n",
    WAD_FILE_NAME, WAD_DST_ADDR, WAD_MAX_BYTES);

  volatile uint8_t *dst = (volatile uint8_t *)WAD_DST_ADDR;
  uint32_t total = 0;
  uint64_t t0 = neorv32_cpu_get_cycle();

  while (1) {
    uint32_t room = WAD_MAX_BYTES - total;
    if (room == 0u) {
      neorv32_uart0_printf("ERROR: WAD exceeds %u bytes limit.\n", WAD_MAX_BYTES);
      return 1;
    }

    UINT req = (room < READ_CHUNK_BYTES) ? (UINT)room : (UINT)READ_CHUNK_BYTES;
    UINT br = 0;

    fr = pf_read((void *)dst, req, &br);
    if (fr != FR_OK) {
      print_pf_error("pf_read", fr);
      return 1;
    }

    dst += br;
    total += (uint32_t)br;

    if (br == 0u) {
      break; // EOF
    }
  }

  uint64_t t1 = neorv32_cpu_get_cycle();
  uint64_t cycles = t1 - t0;
  uint32_t clk_hz = neorv32_sysinfo_get_clk();

  asm volatile ("fence rw, rw" ::: "memory");

  if (cycles == 0u) {
    cycles = 1u;
  }
  uint64_t time_ms = ((cycles * 1000ull) + (clk_hz / 2u)) / clk_hz;
  uint64_t bytes_per_s = ((uint64_t)total * (uint64_t)clk_hz) / cycles;
  uint64_t kib_per_s = bytes_per_s / 1024ull;

  uint32_t magic = *(volatile uint32_t *)WAD_DST_ADDR;

  neorv32_uart0_printf("Done.\n");
  neorv32_uart0_printf("Bytes copied: %u\n", total);
  neorv32_uart0_printf("Cycles:       %u:%u\n", (uint32_t)(cycles >> 32), (uint32_t)cycles);
  neorv32_uart0_printf("Time:         %u ms\n", (uint32_t)time_ms);
  neorv32_uart0_printf("Throughput:   %u KiB/s\n", (uint32_t)kib_per_s);
  neorv32_uart0_printf("Header @dst:  0x%08x (%c%c%c%c)\n",
    magic,
    (char)((magic >> 0) & 0xff),
    (char)((magic >> 8) & 0xff),
    (char)((magic >> 16) & 0xff),
    (char)((magic >> 24) & 0xff));

  if (magic == 0x44415749u) {
    neorv32_uart0_printf("IWAD header check: OK\n");
  } else {
    neorv32_uart0_printf("IWAD header check: FAILED\n");
  }

  return 0;
}
