// =============================================================================
// doomgeneric platform implementation for NEORV32 + VGA DMA
// =============================================================================

#include <neorv32.h>
#include <stdint.h>
#include <string.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "neorv32_vga.h"

// Timing state
static uint32_t clk_hz;
static uint64_t start_cycles;

// Frame statistics
static uint32_t frame_count = 0;
static uint64_t last_stats_time = 0;

// HPM state
static uint32_t hpm_num = 0;

// =============================================================================
// DG_Init - Initialize platform
// =============================================================================
void DG_Init(void)
{
    // Get clock frequency for timing
    clk_hz = neorv32_sysinfo_get_clk();
    start_cycles = neorv32_cpu_get_cycle();
    last_stats_time = start_cycles;

    // Initialize VGA backend
    neorv32_vga_init();

    DG_ScreenBuffer = (pixel_t *)neorv32_vga_get_back_buffer();

    // Initialize hardware performance monitors
    if ((neorv32_cpu_csr_read(CSR_MXISA) & (1 << CSR_MXISA_ZIHPM))) {
        hpm_num = neorv32_cpu_hpm_get_num_counters();
    }
    if (hpm_num > 0) {
        neorv32_uart0_printf("HPM: %u counters available\n", hpm_num);

        // Stop all counters
        neorv32_cpu_csr_write(CSR_MCOUNTINHIBIT, -1);

        // Clear base counters
        if ((neorv32_cpu_csr_read(CSR_MXISA) & (1 << CSR_MXISA_ZICNTR))) {
            neorv32_cpu_csr_write(CSR_MCYCLE, 0);
            neorv32_cpu_csr_write(CSR_MCYCLEH, 0);
            neorv32_cpu_csr_write(CSR_MINSTRET, 0);
            neorv32_cpu_csr_write(CSR_MINSTRETH, 0);
        }

        // Clear and configure HPM counters
        if (hpm_num > 0) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER3,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER3H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT3,  1 << HPMCNT_EVENT_COMPR);    }
        if (hpm_num > 1) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER4,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER4H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT4,  1 << HPMCNT_EVENT_WAIT_DIS); }
        if (hpm_num > 2) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER5,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER5H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT5,  1 << HPMCNT_EVENT_WAIT_ALU); }
        if (hpm_num > 3) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER6,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER6H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT6,  1 << HPMCNT_EVENT_BRANCH);   }
        if (hpm_num > 4) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER7,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER7H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT7,  1 << HPMCNT_EVENT_CTRLFLOW); }
        if (hpm_num > 5) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER8,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER8H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT8,  1 << HPMCNT_EVENT_LOAD);     }
        if (hpm_num > 6) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER9,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER9H,  0); neorv32_cpu_csr_write(CSR_MHPMEVENT9,  1 << HPMCNT_EVENT_STORE);    }
        if (hpm_num > 7) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER10, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER10H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT10, 1 << HPMCNT_EVENT_WAIT_LSU); }

        // Enable all counters
        neorv32_cpu_csr_write(CSR_MCOUNTINHIBIT, 0);
    } else {
        neorv32_uart0_printf("HPM: not available\n");
    }

    neorv32_uart0_printf("DG_Init: platform ready, clk=%u Hz\n", clk_hz);
}

// =============================================================================
// DG_DrawFrame - Copy DG_ScreenBuffer to VGA framebuffer
//
// DG_ScreenBuffer is 640x400 pixels, 32-bit RGB (0x00RRGGBB)
// VGA framebuffer is 640x480 pixels, 16-bit RGB565
// We letterbox with 40 black lines top and bottom
// =============================================================================
void DG_DrawFrame(void)
{
    // Get back buffer address
    // volatile uint16_t *fb = (volatile uint16_t *)neorv32_vga_get_back_buffer();
    // const pixel_t *src = DG_ScreenBuffer;

    // --- Top letterbox: 40 lines of black ---
    // volatile uint32_t *fb32 = (volatile uint32_t *)fb;
    // for (int i = 0; i < (640 * 40) / 2; i++)
    // {
    //     fb32[i] = 0;
    // }
    // fb += 640 * 40;

    // --- Copy 640x400 frame with RGB888 -> RGB565 conversion ---
    // for (int y = 0; y < DOOMGENERIC_RESY; y++)
    // {
    //     for (int x = 0; x < DOOMGENERIC_RESX; x++)
    //     {
    //         // Extract RGB from 32-bit pixel (format: 0x00RRGGBB)
    //         uint32_t pixel = *src++;
    //         uint32_t r = (pixel >> 16) & 0xFF;
    //         uint32_t g = (pixel >> 8) & 0xFF;
    //         uint32_t b = pixel & 0xFF;

    //         // Convert to RGB565: RRRRRGGGGGGBBBBB
    //         uint16_t rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
    //         *fb++ = rgb565;
    //     }
    // }

    // --- Bottom letterbox: 40 lines of black ---
    // fb32 = (volatile uint32_t *)fb;
    // for (int i = 0; i < (640 * 40) / 2; i++)
    // {
    //     fb32[i] = 0;
    // }

    // Request buffer swap
    neorv32_vga_swap();
    DG_ScreenBuffer = (pixel_t *)neorv32_vga_get_back_buffer(); //change doom internal frame buffer

    // Update statistics
    frame_count++;

    // Print stats every 60 frames
    if ((frame_count % 60) == 0)
    {
        // Print HPM counters (delta since last stats print)
        if (hpm_num > 0) {
            // Stop counters to get consistent snapshot
            neorv32_cpu_csr_write(CSR_MCOUNTINHIBIT, -1);

            // Read full 64-bit counter values
            uint64_t cycles  = 0, instret = 0;
            uint64_t hpm[8]  = {0};

            if ((neorv32_cpu_csr_read(CSR_MXISA) & (1 << CSR_MXISA_ZICNTR))) {
                cycles  = ((uint64_t)neorv32_cpu_csr_read(CSR_MCYCLEH)   << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MCYCLE);
                instret = ((uint64_t)neorv32_cpu_csr_read(CSR_MINSTRETH) << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MINSTRET);
            }
            if (hpm_num > 0) hpm[0] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER3H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER3);
            if (hpm_num > 1) hpm[1] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER4H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER4);
            if (hpm_num > 2) hpm[2] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER5H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER5);
            if (hpm_num > 3) hpm[3] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER6H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER6);
            if (hpm_num > 4) hpm[4] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER7H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER7);
            if (hpm_num > 5) hpm[5] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER8H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER8);
            if (hpm_num > 6) hpm[6] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER9H)  << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER9);
            if (hpm_num > 7) hpm[7] = ((uint64_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER10H) << 32) | (uint32_t)neorv32_cpu_csr_read(CSR_MHPMCOUNTER10);

            // Compute FPS from cycle count (cycles = exact delta for this interval)
            uint32_t elapsed_ms = (uint32_t)((cycles * 1000ULL) / clk_hz);
            uint32_t fps_x10 = (elapsed_ms > 0) ? (60 * 10000) / elapsed_ms : 0;

            // Print values as millions (M) and percentages of cycles
            uint32_t cyc_m = (uint32_t)(cycles / 1000000ULL);
            uint32_t ins_m = (uint32_t)(instret / 1000000ULL);
            uint32_t cpi_x10 = (instret > 0) ? (uint32_t)((cycles * 10ULL) / instret) : 0;

            neorv32_uart0_printf("frame=%u fps=%u.%u\n",
                frame_count, fps_x10 / 10, fps_x10 % 10);
            neorv32_uart0_printf("  cycles=%uM instret=%uM cpi=%u.%u\n",
                cyc_m, ins_m, cpi_x10 / 10, cpi_x10 % 10);

            // Compute percentages of total cycles (x10 for one decimal place)
            #define HPM_PCT(val) (uint32_t)(cycles > 0 ? ((val) * 1000ULL / cycles) : 0)

            if (hpm_num > 0) neorv32_uart0_printf("  compressed=%uM",  (uint32_t)(hpm[0] / 1000000ULL));
            if (hpm_num > 1) neorv32_uart0_printf(" disp_wait=%uM(%u.%u%%)", (uint32_t)(hpm[1] / 1000000ULL), HPM_PCT(hpm[1]) / 10, HPM_PCT(hpm[1]) % 10);
            if (hpm_num > 2) neorv32_uart0_printf(" alu_wait=%uM(%u.%u%%)",  (uint32_t)(hpm[2] / 1000000ULL), HPM_PCT(hpm[2]) / 10, HPM_PCT(hpm[2]) % 10);
            if (hpm_num > 0) neorv32_uart0_printf("\n");

            if (hpm_num > 3) neorv32_uart0_printf("  branch=%uM",     (uint32_t)(hpm[3] / 1000000ULL));
            if (hpm_num > 4) neorv32_uart0_printf(" ctrlflow=%uM",    (uint32_t)(hpm[4] / 1000000ULL));
            if (hpm_num > 3) neorv32_uart0_printf("\n");

            if (hpm_num > 5) neorv32_uart0_printf("  loads=%uM",      (uint32_t)(hpm[5] / 1000000ULL));
            if (hpm_num > 6) neorv32_uart0_printf(" stores=%uM",      (uint32_t)(hpm[6] / 1000000ULL));
            if (hpm_num > 7) neorv32_uart0_printf(" lsu_wait=%uM(%u.%u%%)",  (uint32_t)(hpm[7] / 1000000ULL), HPM_PCT(hpm[7]) / 10, HPM_PCT(hpm[7]) % 10);
            if (hpm_num > 5) neorv32_uart0_printf("\n");

            #undef HPM_PCT

            // Reset all counters for next interval
            if ((neorv32_cpu_csr_read(CSR_MXISA) & (1 << CSR_MXISA_ZICNTR))) {
                neorv32_cpu_csr_write(CSR_MCYCLE, 0);
                neorv32_cpu_csr_write(CSR_MCYCLEH, 0);
                neorv32_cpu_csr_write(CSR_MINSTRET, 0);
                neorv32_cpu_csr_write(CSR_MINSTRETH, 0);
            }
            if (hpm_num > 0) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER3,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER3H,  0); }
            if (hpm_num > 1) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER4,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER4H,  0); }
            if (hpm_num > 2) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER5,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER5H,  0); }
            if (hpm_num > 3) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER6,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER6H,  0); }
            if (hpm_num > 4) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER7,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER7H,  0); }
            if (hpm_num > 5) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER8,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER8H,  0); }
            if (hpm_num > 6) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER9,  0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER9H,  0); }
            if (hpm_num > 7) { neorv32_cpu_csr_write(CSR_MHPMCOUNTER10, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER10H, 0); }

            // Re-enable all counters
            neorv32_cpu_csr_write(CSR_MCOUNTINHIBIT, 0);
        } else {
            // Fallback FPS without HPM
            uint64_t now = neorv32_cpu_get_cycle();
            uint64_t elapsed = now - last_stats_time;
            uint32_t elapsed_ms = (uint32_t)((elapsed * 1000ULL) / clk_hz);
            uint32_t fps_x10 = (elapsed_ms > 0) ? (60 * 10000) / elapsed_ms : 0;
            neorv32_uart0_printf("frame=%u fps=%u.%u\n",
                                 frame_count, fps_x10 / 10, fps_x10 % 10);
            last_stats_time = now;
        }
    }
}

// =============================================================================
// DG_GetTicksMs - Return wall-clock time in milliseconds
//
// Note: With singletics=true in d_loop.c, TryRunTics() ignores this value
// and runs exactly 1 tic per call. This is used for FPS stats and SleepMs.
// =============================================================================
uint32_t DG_GetTicksMs(void)
{
    uint64_t now = neorv32_cpu_get_cycle();
    uint64_t elapsed = now - start_cycles;
    return (uint32_t)((elapsed * 1000ULL) / clk_hz);
}

// =============================================================================
// DG_SleepMs - Sleep for specified milliseconds (wall-clock time)
// =============================================================================
void DG_SleepMs(uint32_t ms)
{
    // Use real wall-clock time for actual delays
    uint64_t start = neorv32_cpu_get_cycle();
    uint64_t delay_cycles = ((uint64_t)ms * clk_hz) / 1000;
    while ((neorv32_cpu_get_cycle() - start) < delay_cycles)
    {
        // Busy wait
    }
}

// =============================================================================
// DG_GetKey - Get keyboard input
//
// For demo playback mode, we primarily return no keys.
// Optionally poll UART for debug/control keys.
// =============================================================================
int DG_GetKey(int *pressed, unsigned char *key)
{
    // Check UART for debug keys
    if (neorv32_uart0_char_received())
    {
        char c = (char)neorv32_uart0_getc();
        *pressed = 1;

        // Map debug keys
        switch (c)
        {
        case 27: // ESC
            *key = KEY_ESCAPE;
            break;
        case 13: // Enter
        case 10:
            *key = KEY_ENTER;
            break;
        case ' ':
            *key = KEY_USE;
            break;
        case 'w':
        case 'W':
            *key = KEY_UPARROW;
            break;
        case 's':
        case 'S':
            *key = KEY_DOWNARROW;
            break;
        case 'a':
        case 'A':
            *key = KEY_STRAFE_L;
            break;
        case 'd':
        case 'D':
            *key = KEY_STRAFE_R;
            break;
        case ',':
            *key = KEY_LEFTARROW;
            break;
        case '.':
            *key = KEY_RIGHTARROW;
            break;
        case 'f':
        case 'F':
            *key = KEY_FIRE;
            break;
        default:
            *key = c;
            break;
        }
        return 1;
    }

    return 0; // No key event
}

// =============================================================================
// DG_SetWindowTitle - Set window title (log to UART)
// =============================================================================
void DG_SetWindowTitle(const char *title)
{
    neorv32_uart0_printf("DOOM: %s\n", title);
}
