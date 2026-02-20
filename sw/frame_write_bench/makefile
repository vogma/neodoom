# Application makefile.
# Frame write benchmark for NEORV32 -> DDR3 framebuffer throughput.

# Match synthesized CPU ISA features.
MARCH = rv32imc_zicsr_zifencei

# Prefer throughput over code size for this benchmark.
EFFORT = -O3

# Place code in IMEM and runtime data in full DDR3 range (same as your existing flow).
# Note: framebuffer protection is done by software discipline in this mode.
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=64k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x10000000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=256M

# Set path to NEORV32 root directory.
NEORV32_HOME ?= ../../modules/neorv32

# Include the main NEORV32 makefile.
include $(NEORV32_HOME)/sw/common/common.mk
