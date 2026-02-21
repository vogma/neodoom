// =============================================================================
// DOOM on NEORV32
// Main entry point
// =============================================================================

#include <neorv32.h>
#include "doomgeneric.h"
#include "wad_sd_loader.h"

#define BAUD_RATE 115200

int main(void)
{
    // Initialize runtime environment
    neorv32_rte_setup();

    // Initialize UART for debug output
    if (neorv32_uart0_available()) {
        neorv32_uart0_setup(BAUD_RATE, 0);
    }

    // Print banner
    neorv32_uart0_printf("\n");
    neorv32_uart0_printf("========================================\n");
    neorv32_uart0_printf("       DOOM on NEORV32 RISC-V\n");
    neorv32_uart0_printf("========================================\n");
    neorv32_uart0_printf("Clock:    %u Hz\n", neorv32_sysinfo_get_clk());
    neorv32_uart0_printf("MISA:     0x%x\n", neorv32_cpu_csr_read(CSR_MISA));
    neorv32_uart0_printf("\n");

    // Check for GPIO (required for VGA swap)
    if (neorv32_gpio_available() == 0) {
        neorv32_uart0_printf("ERROR: GPIO not available!\n");
        return 1;
    }

    neorv32_uart0_printf("Loading %s from SD card...\n", DOOM_WAD_FILE_NAME);
    if (wad_sd_loader_load() != 0) {
        neorv32_uart0_printf("ERROR: failed to load IWAD from SD card.\n");
        return 1;
    }
    neorv32_uart0_printf("IWAD ready: %s @0x%08x (%u bytes)\n",
                         DOOM_WAD_FILE_NAME,
                         wad_sd_loader_get_addr(),
                         wad_sd_loader_get_size());

    // DOOM command line arguments
    // Note: -iwad file content is served from SDRAM by w_file_sdram.c
    char *argv[] = {
        "doom",
        "-iwad",
        DOOM_WAD_FILE_NAME,
        "-nosound",
        "-nomusic",
        "-nosfx",
        NULL
    };
    int argc = 6;

    neorv32_uart0_printf("Starting DOOM...\n\n");

    // Initialize DOOM
    doomgeneric_Create(argc, argv);

    // Main game loop
    while (1) {
        doomgeneric_Tick();
    }

    return 0;
}
