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
    volatile uint16_t *fb = (volatile uint16_t *)neorv32_vga_get_back_buffer();
    const pixel_t *src = DG_ScreenBuffer;

    // --- Top letterbox: 40 lines of black ---
    volatile uint32_t *fb32 = (volatile uint32_t *)fb;
    for (int i = 0; i < (640 * 40) / 2; i++) {
        fb32[i] = 0;
    }
    fb += 640 * 40;

    // --- Copy 640x400 frame with RGB888 -> RGB565 conversion ---
    for (int y = 0; y < DOOMGENERIC_RESY; y++) {
        for (int x = 0; x < DOOMGENERIC_RESX; x++) {
            // Extract RGB from 32-bit pixel (format: 0x00RRGGBB)
            uint32_t pixel = *src++;
            uint32_t r = (pixel >> 16) & 0xFF;
            uint32_t g = (pixel >> 8) & 0xFF;
            uint32_t b = pixel & 0xFF;

            // Convert to RGB565: RRRRRGGGGGGBBBBB
            uint16_t rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            *fb++ = rgb565;
        }
    }

    // --- Bottom letterbox: 40 lines of black ---
    fb32 = (volatile uint32_t *)fb;
    for (int i = 0; i < (640 * 40) / 2; i++) {
        fb32[i] = 0;
    }

    // Request buffer swap
    neorv32_vga_swap();

    // Update statistics
    frame_count++;

    // Print stats every 60 frames
    if ((frame_count % 60) == 0) {
        uint64_t now = neorv32_cpu_get_cycle();
        uint64_t elapsed = now - last_stats_time;
        uint32_t elapsed_ms = (uint32_t)((elapsed * 1000ULL) / clk_hz);
        uint32_t fps_x10 = (60 * 10000) / elapsed_ms;  // FPS * 10

        neorv32_uart0_printf("frame=%u fps=%u.%u\n",
                             frame_count, fps_x10 / 10, fps_x10 % 10);
        last_stats_time = now;
    }
}

// =============================================================================
// DG_GetTicksMs - Return milliseconds since DG_Init
// =============================================================================
uint32_t DG_GetTicksMs(void)
{
    uint64_t now = neorv32_cpu_get_cycle();
    uint64_t elapsed = now - start_cycles;
    return (uint32_t)((elapsed * 1000ULL) / clk_hz);
}

// =============================================================================
// DG_SleepMs - Sleep for specified milliseconds
// =============================================================================
void DG_SleepMs(uint32_t ms)
{
    uint32_t target = DG_GetTicksMs() + ms;
    while (DG_GetTicksMs() < target) {
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
    if (neorv32_uart0_char_received()) {
        char c = (char)neorv32_uart0_getc();
        *pressed = 1;

        // Map debug keys
        switch (c) {
            case 27:  // ESC
                *key = KEY_ESCAPE;
                break;
            case 13:  // Enter
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

    return 0;  // No key event
}

// =============================================================================
// DG_SetWindowTitle - Set window title (log to UART)
// =============================================================================
void DG_SetWindowTitle(const char *title)
{
    neorv32_uart0_printf("DOOM: %s\n", title);
}
