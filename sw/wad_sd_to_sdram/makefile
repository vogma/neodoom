# Application makefile.
# Loads DOOM1.WAD from SD card (FAT32 root) into external SDRAM.

# Match synthesized CPU ISA features.
MARCH = rv32imc_zicsr_zifencei

# Optimize for sustained streaming throughput.
EFFORT = -O3

USER_FLAGS += -std=gnu11

# Keep program/data in a safe DDR region:
#   framebuffer region: 0x10200000 .. 0x1032BFFF (used by VGA path)
#   app runtime region: 0x1032C000 .. 0x10FFFFFF
# USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=64k
# USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x1032C000
# USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=0x00CD4000


USER_FLAGS += -Wl,--defsym,__neorv32_rom_base=0x11000000
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=0x02000000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x13000000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=0x0C000000
USER_FLAGS += -Wl,--defsym,__neorv32_heap_size=0x01000000

# Set path to NEORV32 root directory.
NEORV32_HOME ?= ../../modules/neorv32
PFF_DIR = $(NEORV32_HOME)/sw/bootloader/petit_fatfs

# Application + Petit FatFs sources.
APP_SRC += ./main.c $(PFF_DIR)/pff.c $(PFF_DIR)/diskio.c
APP_INC += -I . -I $(PFF_DIR)

# Include the main NEORV32 makefile.
include $(NEORV32_HOME)/sw/common/common.mk
