// =============================================================================
// WAD SD -> SDRAM loader for DOOM runtime
// =============================================================================

#include <neorv32.h>
#include <stdint.h>

#include "pff.h"
#include "wad_sd_loader.h"

#define READ_CHUNK_BYTES  4096u

// Slow clock for card init, faster clock for bulk transfer.
#define SD_SPI_INIT_PRSC  CLK_PRSC_1024
#define SD_SPI_INIT_CDIV  1
#define SD_SPI_RUN_PRSC   CLK_PRSC_2
#define SD_SPI_RUN_CDIV   0

static FATFS fs;
static uint32_t wad_size_bytes = 0;
static int wad_ready = 0;

static char ascii_upper(char c)
{
    if ((c >= 'a') && (c <= 'z')) {
        return (char)(c - ('a' - 'A'));
    }
    return c;
}

static int str_case_eq(const char *a, const char *b)
{
    while ((*a != '\0') && (*b != '\0')) {
        if (ascii_upper(*a) != ascii_upper(*b)) {
            return 0;
        }
        a++;
        b++;
    }

    return (*a == '\0') && (*b == '\0');
}

static const char *path_basename(const char *path)
{
    const char *base = path;

    if (path == 0) {
        return "";
    }

    while (*path != '\0') {
        if ((*path == '/') || (*path == '\\')) {
            base = path + 1;
        }
        path++;
    }

    return base;
}

static void print_pf_error(const char *step, FRESULT fr)
{
    neorv32_uart0_printf("ERROR: %s failed (FRESULT=%u)\n", step, (uint32_t)fr);
}

int wad_sd_loader_load(void)
{
    FRESULT fr;
    volatile uint8_t *dst;
    uint32_t total;
    uint64_t t0;
    uint64_t t1;
    uint64_t cycles;
    uint32_t clk_hz;
    uint64_t time_ms;
    uint64_t bytes_per_s;
    uint64_t kib_per_s;
    uint32_t magic;

    if (wad_ready) {
        return 0;
    }

    // Check if WAD is already present in SDRAM (survives soft reset).
    {
        volatile uint32_t *hdr = (volatile uint32_t *)DOOM_WAD_DST_ADDR;
        uint32_t magic = hdr[0];
        if (magic == 0x44415749u) { // "IWAD"
            uint32_t numlumps    = hdr[1];
            uint32_t infotableofs = hdr[2];
            uint32_t size = infotableofs + numlumps * 16u;
            if (size >= 12u && size <= DOOM_WAD_MAX_BYTES) {
                wad_size_bytes = size;
                wad_ready = 1;
                neorv32_uart0_printf("IWAD already in SDRAM: %u bytes @ 0x%x\n",
                                     wad_size_bytes, DOOM_WAD_DST_ADDR);
                return 0;
            }
        }
    }

    if (neorv32_spi_available() == 0) {
        neorv32_uart0_printf("ERROR: SPI not synthesized.\n");
        return -1;
    }

    neorv32_spi_setup(SD_SPI_INIT_PRSC, SD_SPI_INIT_CDIV, 0, 0);
    neorv32_uart0_printf("SPI init clock: %u Hz\n", neorv32_spi_get_clock_speed());

    fr = pf_mount(&fs);
    if (fr != FR_OK) {
        print_pf_error("pf_mount", fr);
        return -2;
    }

    fr = pf_open(DOOM_WAD_FILE_NAME);
    if (fr != FR_OK) {
        print_pf_error("pf_open", fr);
        return -3;
    }

    neorv32_spi_setup(SD_SPI_RUN_PRSC, SD_SPI_RUN_CDIV, 0, 0);
    neorv32_uart0_printf("SPI run clock:  %u Hz\n", neorv32_spi_get_clock_speed());
    neorv32_uart0_printf("Copying %s -> 0x%08x (max %u bytes)\n",
                         DOOM_WAD_FILE_NAME, DOOM_WAD_DST_ADDR, DOOM_WAD_MAX_BYTES);

    dst = (volatile uint8_t *)DOOM_WAD_DST_ADDR;
    total = 0;
    t0 = neorv32_cpu_get_cycle();

    while (1) {
        uint32_t room;
        UINT req;
        UINT br;

        room = DOOM_WAD_MAX_BYTES - total;
        if (room == 0u) {
            neorv32_uart0_printf("ERROR: WAD exceeds %u bytes limit.\n", DOOM_WAD_MAX_BYTES);
            return -4;
        }

        req = (room < READ_CHUNK_BYTES) ? (UINT)room : (UINT)READ_CHUNK_BYTES;
        br = 0;

        fr = pf_read((void *)dst, req, &br);
        if (fr != FR_OK) {
            print_pf_error("pf_read", fr);
            return -5;
        }

        dst += br;
        total += (uint32_t)br;

        if (br == 0u) {
            break;
        }
    }

    asm volatile ("fence rw, rw" ::: "memory");

    if (total < 4u) {
        neorv32_uart0_printf("ERROR: WAD too small (%u bytes).\n", total);
        return -6;
    }

    magic = *(volatile uint32_t *)DOOM_WAD_DST_ADDR;
    if (magic != 0x44415749u) {
        neorv32_uart0_printf("ERROR: invalid IWAD header 0x%x.\n", magic);
        return -7;
    }

    t1 = neorv32_cpu_get_cycle();
    cycles = t1 - t0;
    if (cycles == 0u) {
        cycles = 1u;
    }

    clk_hz = neorv32_sysinfo_get_clk();
    time_ms = ((cycles * 1000ull) + (clk_hz / 2u)) / clk_hz;
    bytes_per_s = ((uint64_t)total * (uint64_t)clk_hz) / cycles;
    kib_per_s = bytes_per_s / 1024ull;

    wad_size_bytes = total;
    wad_ready = 1;

    neorv32_uart0_printf("IWAD load done: %u bytes, %u ms, %u KiB/s\n",
                         wad_size_bytes, (uint32_t)time_ms, (uint32_t)kib_per_s);
    return 0;
}

int wad_sd_loader_is_ready(void)
{
    return wad_ready;
}

uint32_t wad_sd_loader_get_addr(void)
{
    return DOOM_WAD_DST_ADDR;
}

uint32_t wad_sd_loader_get_size(void)
{
    return wad_size_bytes;
}

int wad_sd_loader_path_matches(const char *path)
{
    return str_case_eq(path_basename(path), DOOM_WAD_FILE_NAME);
}

// Hook used by doomgeneric IWAD path search.
int DG_FilePathAvailable(const char *path)
{
    return wad_sd_loader_is_ready() && wad_sd_loader_path_matches(path);
}
