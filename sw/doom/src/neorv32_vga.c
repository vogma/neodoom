// =============================================================================
// NEORV32 VGA Backend for DOOM
// Double-buffered VGA with GPIO handshake
// Adapted from sw/vga_plasma/main.c
// =============================================================================

#include <neorv32.h>
#include <stdint.h>
#include "neorv32_vga.h"

// GPIO bit assignments (must match RTL vga_dma.vhd)
#define GPIO_SWAP_REQ_BIT   4u
#define GPIO_SWAP_SEL_BIT   5u
#define GPIO_SWAP_ACK_BIT   0u

// Timeout for swap handshake
#define SWAP_TIMEOUT_MS     100u

// Swap result codes
enum {
    SWAP_OK = 0,
    SWAP_ERR_IDLE_TIMEOUT = 1,
    SWAP_ERR_ACK_TIMEOUT = 2
};

// Buffer state
static uint32_t front_buf = 0;
static uint32_t back_buf = 1;
static uint32_t req_seq_shadow = 0;
static uint64_t timeout_cycles = 0;

// Statistics
static uint32_t swap_count = 0;
static uint32_t timeout_count = 0;

// =============================================================================
// Internal helpers
// =============================================================================

static inline void mem_barrier(void)
{
    asm volatile("fence rw, rw" ::: "memory");
}

static inline uint32_t vga_ack_get(void)
{
    return (neorv32_gpio_port_get() >> GPIO_SWAP_ACK_BIT) & 1u;
}

static inline void vga_req_drive(uint32_t seq)
{
    neorv32_gpio_pin_set((int)GPIO_SWAP_REQ_BIT, (int)(seq & 1u));
}

static inline void vga_sel_drive(uint32_t buf)
{
    neorv32_gpio_pin_set((int)GPIO_SWAP_SEL_BIT, (int)(buf & 1u));
}

static int wait_for_ack_eq_req(uint64_t timeout)
{
    uint64_t start = neorv32_cpu_get_cycle();
    while (vga_ack_get() != req_seq_shadow) {
        if ((neorv32_cpu_get_cycle() - start) >= timeout) {
            return -1;
        }
    }
    return 0;
}

static int vga_request_swap(uint32_t target_buf, uint64_t timeout)
{
    // Wait for idle (ack == req)
    if (wait_for_ack_eq_req(timeout) != 0) {
        return SWAP_ERR_IDLE_TIMEOUT;
    }

    // Drive buffer select
    vga_sel_drive(target_buf);
    mem_barrier();

    // Toggle request
    req_seq_shadow ^= 1u;
    vga_req_drive(req_seq_shadow);

    // Wait for ack
    if (wait_for_ack_eq_req(timeout) != 0) {
        return SWAP_ERR_ACK_TIMEOUT;
    }

    return SWAP_OK;
}

static void vga_resync_req_to_ack(void)
{
    req_seq_shadow = vga_ack_get();
    vga_req_drive(req_seq_shadow);
}

// =============================================================================
// Public API
// =============================================================================

void neorv32_vga_init(void)
{
    uint32_t clk_hz = neorv32_sysinfo_get_clk();
    timeout_cycles = ((uint64_t)clk_hz * SWAP_TIMEOUT_MS) / 1000ULL;
    if (timeout_cycles == 0) timeout_cycles = 1;

    // Sync to hardware state
    req_seq_shadow = vga_ack_get();
    vga_req_drive(req_seq_shadow);

    // Start with buffer 1 as back buffer
    front_buf = 0;
    back_buf = 1;
    vga_sel_drive(back_buf);

    // Reset statistics
    swap_count = 0;
    timeout_count = 0;

    neorv32_uart0_printf("VGA: init done, fb0=0x%x fb1=0x%x\n",
                         VGA_FRAME_BUF_0, VGA_FRAME_BUF_1);
}

uint32_t neorv32_vga_get_back_buffer(void)
{
    return (back_buf == 0) ? VGA_FRAME_BUF_0 : VGA_FRAME_BUF_1;
}

void neorv32_vga_swap(void)
{
    mem_barrier();

    int rc = vga_request_swap(back_buf, timeout_cycles);
    if (rc != SWAP_OK) {
        timeout_count++;
        neorv32_uart0_printf("VGA: swap TIMEOUT rc=%d\n", rc);
        vga_resync_req_to_ack();
        return;
    }

    // Commit swap
    uint32_t tmp = front_buf;
    front_buf = back_buf;
    back_buf = tmp;
    swap_count++;
}

uint32_t neorv32_vga_get_swap_count(void)
{
    return swap_count;
}

uint32_t neorv32_vga_get_timeout_count(void)
{
    return timeout_count;
}
