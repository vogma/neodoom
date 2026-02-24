// =============================================================================
// NEORV32 VGA Backend for DOOM
// Double-buffered VGA with GPIO handshake
// =============================================================================

#ifndef NEORV32_VGA_H
#define NEORV32_VGA_H

#include <stdint.h>

// Framebuffer configuration (must match RTL)
#define VGA_FRAME_WIDTH     640u
#define VGA_FRAME_HEIGHT    400u
#define VGA_FRAME_BUF_0     0x10200000u
#define VGA_FRAME_BUF_1     0x10300000u

// Initialize VGA backend
void neorv32_vga_init(void);

// Get address of current back buffer
uint32_t neorv32_vga_get_back_buffer(void);

// Request buffer swap (blocks until complete)
void neorv32_vga_swap(void);

// Get swap statistics
uint32_t neorv32_vga_get_swap_count(void);
uint32_t neorv32_vga_get_timeout_count(void);

#endif // NEORV32_VGA_H
