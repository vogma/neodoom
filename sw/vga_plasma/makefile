# Application makefile.
# VGA plasma demo: animated color plasma effect with full-screen repaint.

# Match synthesized CPU ISA features.
MARCH = rv32imc_zicsr_zifencei

# Optimize for throughput during framebuffer writes.
EFFORT = -O3

# DDR3 framebuffer layout (RGB565, 640x480 = 0x96000 bytes each):
#   fb0: 0x10200000 .. 0x10295FFF
#   fb1: 0x10296000 .. 0x1032BFFF
# Firmware data/stack starts immediately after fb1.
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=64k
# RAM starts after fb1 (0x1032C000) and must end at DDR3 limit (0x1FFFFFFF)
# Size: 0x20000000 - 0x1032C000 = 0xFCD4000 (~252.8 MB)
USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x1032C000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=0xFCD4000

# Set path to NEORV32 root directory.
NEORV32_HOME ?= ../../modules/neorv32

# Include the main NEORV32 makefile.
include $(NEORV32_HOME)/sw/common/common.mk
