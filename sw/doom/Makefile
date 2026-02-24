# =============================================================================
# DOOM on NEORV32 Makefile
# =============================================================================

NEORV32_HOME ?= ../../modules/neorv32

# -----------------------------------------------------------------------------
# CPU Configuration
# -----------------------------------------------------------------------------
MARCH ?= rv32imc_zicsr_zifencei_zba_zbb_zbkb_zbkc_zbs_zcb_zihpm
MABI  ?= ilp32

# Optimization
EFFORT ?= -O3

# -----------------------------------------------------------------------------
# DDR3 Memory Layout
# Framebuffers at 0x10200000-0x1032BFFF - AVOID THIS REGION
# ROM: 0x11000000, 32MB (code + rodata)
# RAM: 0x13000000, 192MB (data + bss + heap + stack)
# -----------------------------------------------------------------------------
USER_FLAGS += -Wl,--defsym,__neorv32_rom_base=0x11000000
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=0x02000000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_base=0x13000000
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=0x0C000000
USER_FLAGS += -Wl,--defsym,__neorv32_heap_size=0x01000000

# -----------------------------------------------------------------------------
# Compiler Flags
# -----------------------------------------------------------------------------
# Use C11 to avoid true/false keyword issues in newer C standards
USER_FLAGS += -std=gnu11

USER_FLAGS += -Wno-unused-parameter
USER_FLAGS += -Wno-implicit-function-declaration
USER_FLAGS += -Wno-missing-field-initializers
USER_FLAGS += -Wno-strict-aliasing
USER_FLAGS += -Wno-pointer-sign
USER_FLAGS += -DSPI_SDCARD_CS=1

# doomgeneric configuration
USER_FLAGS += -DDOOMGENERIC_RESX=640
USER_FLAGS += -DDOOMGENERIC_RESY=400

# Profiling mode for fbconv phase (uncomment ONE):
#   0 = normal (default)
#   1 = skip FB writes (measure read-only LSU stalls)
#   2 = skip FB reads  (measure write-only LSU stalls)
# USER_FLAGS += -DPROF_MODE=1
# USER_FLAGS += -DPROF_MODE=2

# -----------------------------------------------------------------------------
# Source Directories
# -----------------------------------------------------------------------------
DOOM_SRC_DIR = doomgeneric/doomgeneric
NEORV32_SRC_DIR = src
PFF_DIR = $(NEORV32_HOME)/sw/bootloader/petit_fatfs

# -----------------------------------------------------------------------------
# Platform Source Files (our implementation)
# -----------------------------------------------------------------------------
PLATFORM_SRC = \
    $(NEORV32_SRC_DIR)/main.c \
    $(NEORV32_SRC_DIR)/doomgeneric_neorv32.c \
    $(NEORV32_SRC_DIR)/neorv32_vga.c \
    $(NEORV32_SRC_DIR)/w_file_sdram.c \
    $(NEORV32_SRC_DIR)/wad_sd_loader.c \
    $(NEORV32_SRC_DIR)/system_stubs.c

# -----------------------------------------------------------------------------
# doomgeneric Source Files
# Exclude platform-specific files (sdl, win, xlib, allegro, etc.)
# Exclude w_file_stdc.c (we provide SDRAM backend override)
# -----------------------------------------------------------------------------
DOOM_SRC = \
    $(DOOM_SRC_DIR)/am_map.c \
    $(DOOM_SRC_DIR)/d_event.c \
    $(DOOM_SRC_DIR)/d_items.c \
    $(DOOM_SRC_DIR)/d_iwad.c \
    $(DOOM_SRC_DIR)/d_loop.c \
    $(DOOM_SRC_DIR)/d_main.c \
    $(DOOM_SRC_DIR)/d_mode.c \
    $(DOOM_SRC_DIR)/d_net.c \
    $(DOOM_SRC_DIR)/doomdef.c \
    $(DOOM_SRC_DIR)/doomgeneric.c \
    $(DOOM_SRC_DIR)/doomstat.c \
    $(DOOM_SRC_DIR)/dstrings.c \
    $(DOOM_SRC_DIR)/dummy.c \
    $(DOOM_SRC_DIR)/f_finale.c \
    $(DOOM_SRC_DIR)/f_wipe.c \
    $(DOOM_SRC_DIR)/g_game.c \
    $(DOOM_SRC_DIR)/hu_lib.c \
    $(DOOM_SRC_DIR)/hu_stuff.c \
    $(DOOM_SRC_DIR)/i_cdmus.c \
    $(DOOM_SRC_DIR)/i_endoom.c \
    $(DOOM_SRC_DIR)/i_input.c \
    $(DOOM_SRC_DIR)/i_joystick.c \
    $(DOOM_SRC_DIR)/i_scale.c \
    $(DOOM_SRC_DIR)/i_sound.c \
    $(DOOM_SRC_DIR)/i_system.c \
    $(DOOM_SRC_DIR)/i_timer.c \
    $(DOOM_SRC_DIR)/i_video.c \
    $(DOOM_SRC_DIR)/icon.c \
    $(DOOM_SRC_DIR)/info.c \
    $(DOOM_SRC_DIR)/m_argv.c \
    $(DOOM_SRC_DIR)/m_bbox.c \
    $(DOOM_SRC_DIR)/m_cheat.c \
    $(DOOM_SRC_DIR)/m_config.c \
    $(DOOM_SRC_DIR)/m_controls.c \
    $(DOOM_SRC_DIR)/m_fixed.c \
    $(DOOM_SRC_DIR)/m_menu.c \
    $(DOOM_SRC_DIR)/m_misc.c \
    $(DOOM_SRC_DIR)/m_random.c \
    $(DOOM_SRC_DIR)/memio.c \
    $(DOOM_SRC_DIR)/p_ceilng.c \
    $(DOOM_SRC_DIR)/p_doors.c \
    $(DOOM_SRC_DIR)/p_enemy.c \
    $(DOOM_SRC_DIR)/p_floor.c \
    $(DOOM_SRC_DIR)/p_inter.c \
    $(DOOM_SRC_DIR)/p_lights.c \
    $(DOOM_SRC_DIR)/p_map.c \
    $(DOOM_SRC_DIR)/p_maputl.c \
    $(DOOM_SRC_DIR)/p_mobj.c \
    $(DOOM_SRC_DIR)/p_plats.c \
    $(DOOM_SRC_DIR)/p_pspr.c \
    $(DOOM_SRC_DIR)/p_saveg.c \
    $(DOOM_SRC_DIR)/p_setup.c \
    $(DOOM_SRC_DIR)/p_sight.c \
    $(DOOM_SRC_DIR)/p_spec.c \
    $(DOOM_SRC_DIR)/p_switch.c \
    $(DOOM_SRC_DIR)/p_telept.c \
    $(DOOM_SRC_DIR)/p_tick.c \
    $(DOOM_SRC_DIR)/p_user.c \
    $(DOOM_SRC_DIR)/r_bsp.c \
    $(DOOM_SRC_DIR)/r_data.c \
    $(DOOM_SRC_DIR)/r_draw.c \
    $(DOOM_SRC_DIR)/r_main.c \
    $(DOOM_SRC_DIR)/r_plane.c \
    $(DOOM_SRC_DIR)/r_segs.c \
    $(DOOM_SRC_DIR)/r_sky.c \
    $(DOOM_SRC_DIR)/r_things.c \
    $(DOOM_SRC_DIR)/sha1.c \
    $(DOOM_SRC_DIR)/sounds.c \
    $(DOOM_SRC_DIR)/s_sound.c \
    $(DOOM_SRC_DIR)/statdump.c \
    $(DOOM_SRC_DIR)/st_lib.c \
    $(DOOM_SRC_DIR)/st_stuff.c \
    $(DOOM_SRC_DIR)/tables.c \
    $(DOOM_SRC_DIR)/v_video.c \
    $(DOOM_SRC_DIR)/w_checksum.c \
    $(DOOM_SRC_DIR)/w_file.c \
    $(DOOM_SRC_DIR)/w_main.c \
    $(DOOM_SRC_DIR)/w_wad.c \
    $(DOOM_SRC_DIR)/wi_stuff.c \
    $(DOOM_SRC_DIR)/z_zone.c

# -----------------------------------------------------------------------------
# All Sources
# -----------------------------------------------------------------------------
APP_SRC = $(PLATFORM_SRC) $(DOOM_SRC)
APP_SRC += $(PFF_DIR)/pff.c $(PFF_DIR)/diskio.c

# Include paths
APP_INC = -I $(NEORV32_SRC_DIR) -I $(DOOM_SRC_DIR) -I $(PFF_DIR)

# -----------------------------------------------------------------------------
# Include NEORV32 common makefile
# -----------------------------------------------------------------------------
include $(NEORV32_HOME)/sw/common/common.mk

# -----------------------------------------------------------------------------
# Custom Targets
# -----------------------------------------------------------------------------

.PHONY: check_layout doom

# Check ELF memory layout
check_layout: $(APP_ELF)
	@echo ""
	@echo "=== Section Layout ==="
	$(Q)$(READELF) -S $< | grep -E "^\s+\[|\.text|\.rodata|\.data|\.bss|\.heap"
	@echo ""
	@echo "=== Checking for framebuffer overlap (0x10200000-0x1032BFFF) ==="
	@$(READELF) -S $< | awk '/PROGBITS|NOBITS/ { \
		if (NF >= 5) { \
			addr = strtonum("0x" $$4); \
			size = strtonum("0x" $$5); \
			if (addr >= 0x10200000 && addr < 0x1032C000) { \
				print "ERROR: " $$2 " at 0x" $$4 " overlaps framebuffer!"; \
				exit 1; \
			} \
		} \
	}' && echo "OK - no framebuffer overlap"
	@echo ""

# Build DOOM (runtime SD-loaded WAD)
doom: elf asm
	@echo ""
	@echo "=== DOOM Build Complete ==="
	@echo "ELF: $(APP_ELF)"
	@echo "ASM: $(APP_ASM)"
	@$(SIZE) $(APP_ELF)

# Clean alias
clean_doom: clean
