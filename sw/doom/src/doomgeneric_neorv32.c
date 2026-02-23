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

// HPM state
static uint32_t hpm_num = 0;

// Per-phase profiling accumulators (summed over 60 frames)
#define PROF_PHASE_LOGIC  0
#define PROF_PHASE_RENDER 1
#define PROF_PHASE_FBCONV 2

typedef struct {
    uint64_t cycles;
    uint64_t loads;
    uint64_t stores;
    uint64_t lsu_wait;
    uint64_t alu_wait;
    uint64_t disp_wait;
} phase_stats_t;

static phase_stats_t prof[3]; // logic, render, fbconv

// Inhibit mask for HPM3-HPM8 only (leave MCYCLE/MINSTRET running)
#define HPM_INHIBIT_MASK ((1<<3)|(1<<4)|(1<<5)|(1<<6)|(1<<7)|(1<<8))

// Stop HPM counters, read & accumulate into phase, reset, restart.
// Never touches MCYCLE/MINSTRET — those stay monotonic for timing APIs.
void prof_phase_end(int phase)
{
    if (hpm_num == 0) return;
    neorv32_cpu_csr_set(CSR_MCOUNTINHIBIT, HPM_INHIBIT_MASK);

    // Read counters (low word only — single phase fits in 32 bits)
    uint32_t cyc = neorv32_cpu_csr_read(CSR_MHPMCOUNTER3);
    uint32_t ld  = neorv32_cpu_csr_read(CSR_MHPMCOUNTER4);
    uint32_t st  = neorv32_cpu_csr_read(CSR_MHPMCOUNTER5);
    uint32_t lsu = neorv32_cpu_csr_read(CSR_MHPMCOUNTER6);
    uint32_t alu = neorv32_cpu_csr_read(CSR_MHPMCOUNTER7);
    uint32_t dis = neorv32_cpu_csr_read(CSR_MHPMCOUNTER8);

    prof[phase].cycles    += cyc;
    prof[phase].loads     += ld;
    prof[phase].stores    += st;
    prof[phase].lsu_wait  += lsu;
    prof[phase].alu_wait  += alu;
    prof[phase].disp_wait += dis;

    // Reset HPM counters only
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER3, 0);
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER4, 0);
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER5, 0);
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER6, 0);
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER7, 0);
    neorv32_cpu_csr_write(CSR_MHPMCOUNTER8, 0);

    neorv32_cpu_csr_clr(CSR_MCOUNTINHIBIT, HPM_INHIBIT_MASK);
}

// =============================================================================
// DG_Init - Initialize platform
// =============================================================================
void DG_Init(void)
{
    // Get clock frequency for timing
    clk_hz = neorv32_sysinfo_get_clk();
    start_cycles = neorv32_cpu_get_cycle();

    // Initialize VGA backend
    neorv32_vga_init();

    DG_ScreenBuffer = (pixel_t *)neorv32_vga_get_back_buffer();

    // Initialize hardware performance monitors
    if ((neorv32_cpu_csr_read(CSR_MXISA) & (1 << CSR_MXISA_ZIHPM))) {
        hpm_num = neorv32_cpu_hpm_get_num_counters();
    }
    if (hpm_num >= 6) {
        neorv32_uart0_printf("HPM: %u counters available, using 6 for profiling\n", hpm_num);

        // Stop HPM counters (leave MCYCLE/MINSTRET running)
        neorv32_cpu_csr_set(CSR_MCOUNTINHIBIT, HPM_INHIBIT_MASK);

        // Configure HPM3-HPM8 for per-phase profiling
        // HPM3=cycles  HPM4=loads  HPM5=stores  HPM6=lsu_wait  HPM7=alu_wait  HPM8=disp_wait
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER3, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER3H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT3, 1 << HPMCNT_EVENT_CY);
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER4, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER4H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT4, 1 << HPMCNT_EVENT_LOAD);
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER5, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER5H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT5, 1 << HPMCNT_EVENT_STORE);
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER6, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER6H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT6, 1 << HPMCNT_EVENT_WAIT_LSU);
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER7, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER7H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT7, 1 << HPMCNT_EVENT_WAIT_ALU);
        neorv32_cpu_csr_write(CSR_MHPMCOUNTER8, 0); neorv32_cpu_csr_write(CSR_MHPMCOUNTER8H, 0); neorv32_cpu_csr_write(CSR_MHPMEVENT8, 1 << HPMCNT_EVENT_WAIT_DIS);

        // Start HPM counters
        neorv32_cpu_csr_clr(CSR_MCOUNTINHIBIT, HPM_INHIBIT_MASK);
    } else {
        neorv32_uart0_printf("HPM: %u counters (need 6), profiling disabled\n", hpm_num);
        hpm_num = 0;
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
    // Buffer swap (included in fbconv phase)
    neorv32_vga_swap();

    // End fbconv phase — captures cmap_to_fb + swap
    prof_phase_end(PROF_PHASE_FBCONV);

    DG_ScreenBuffer = (pixel_t *)neorv32_vga_get_back_buffer();

    frame_count++;

    if ((frame_count % 60) == 0)
    {
        // Compute totals across phases
        uint64_t tot_cycles = prof[0].cycles + prof[1].cycles + prof[2].cycles;
        uint64_t tot_loads  = prof[0].loads  + prof[1].loads  + prof[2].loads;
        uint64_t tot_stores = prof[0].stores + prof[1].stores + prof[2].stores;
        uint64_t tot_lsu    = prof[0].lsu_wait  + prof[1].lsu_wait  + prof[2].lsu_wait;
        uint64_t tot_alu    = prof[0].alu_wait  + prof[1].alu_wait  + prof[2].alu_wait;
        uint64_t tot_disp   = prof[0].disp_wait + prof[1].disp_wait + prof[2].disp_wait;

        // FPS from total cycles
        uint32_t fps_x10 = 0;
        if (tot_cycles > 0) {
            uint32_t elapsed_ms = (uint32_t)((tot_cycles * 1000ULL) / (60 * (uint64_t)clk_hz));
            fps_x10 = (elapsed_ms > 0) ? 10000 / elapsed_ms : 0;
        }

        // Helper: permille of total cycles (for phase %)
        #define PCT_OF_TOTAL(v) (uint32_t)(tot_cycles > 0 ? ((v) * 1000ULL / tot_cycles) : 0)
        // Helper: permille of own cycles (for occupancy within a phase)
        #define OCCUPANCY(val, cyc) (uint32_t)((cyc) > 0 ? ((val) * 1000ULL / (cyc)) : 0)

        neorv32_uart0_printf("--- frame %u  fps=%u.%u  avg/frame over 60 ---\n",
            frame_count, fps_x10 / 10, fps_x10 % 10);
        neorv32_uart0_printf("phase   cycles  loads stores  lsu%%  alu%% disp%%  frame%%\n");

        const char *names[3] = {"logic ", "render", "fbconv"};
        for (int i = 0; i < 3; i++) {
            uint32_t cyc_m = (uint32_t)(prof[i].cycles / 60 / 1000000ULL);
            uint32_t ld_k  = (uint32_t)(prof[i].loads  / 60 / 1000);
            uint32_t st_k  = (uint32_t)(prof[i].stores / 60 / 1000);
            uint32_t lsu   = OCCUPANCY(prof[i].lsu_wait,  prof[i].cycles);
            uint32_t alu   = OCCUPANCY(prof[i].alu_wait,  prof[i].cycles);
            uint32_t dis   = OCCUPANCY(prof[i].disp_wait, prof[i].cycles);
            uint32_t pct   = PCT_OF_TOTAL(prof[i].cycles);

            neorv32_uart0_printf("%s  %uM  %uk %uk  %u.%u  %u.%u  %u.%u  %u.%u%%\n",
                names[i], cyc_m, ld_k, st_k,
                lsu / 10, lsu % 10,
                alu / 10, alu % 10,
                dis / 10, dis % 10,
                pct / 10, pct % 10);
        }

        // Total row
        {
            uint32_t cyc_m = (uint32_t)(tot_cycles / 60 / 1000000ULL);
            uint32_t ld_k  = (uint32_t)(tot_loads  / 60 / 1000);
            uint32_t st_k  = (uint32_t)(tot_stores / 60 / 1000);
            uint32_t lsu   = OCCUPANCY(tot_lsu,  tot_cycles);
            uint32_t alu   = OCCUPANCY(tot_alu,  tot_cycles);
            uint32_t dis   = OCCUPANCY(tot_disp, tot_cycles);

            neorv32_uart0_printf("TOTAL   %uM  %uk %uk  %u.%u  %u.%u  %u.%u\n",
                cyc_m, ld_k, st_k,
                lsu / 10, lsu % 10,
                alu / 10, alu % 10,
                dis / 10, dis % 10);
        }

        #undef PCT_OF_TOTAL
        #undef OCCUPANCY

        // Reset accumulators
        memset(prof, 0, sizeof(prof));
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
