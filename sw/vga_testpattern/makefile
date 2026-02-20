# Application makefile.
# VGA test pattern writer for DDR3 framebuffer -> VGA DMA pipeline.

# Match synthesized CPU ISA features.
MARCH = rv32imc_zicsr_zifencei

# Optimize for throughput during framebuffer writes.
EFFORT = -O3

# DDR3 framebuffer layout (RGB565, 640x480 = 0x96000 bytes each):
#   fb0: 0x10200000 .. 0x10295FFF
#   fb1: 0x10296000 .. 0x1032BFFF
# Firmware data/stack starts immediately after fb1.
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=64k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x1032C000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=253M

# Set path to NEORV32 root directory.
NEORV32_HOME ?= ../../modules/neorv32

# Include the main NEORV32 makefile.
include $(NEORV32_HOME)/sw/common/common.mk
