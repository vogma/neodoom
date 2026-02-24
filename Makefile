VIVADO ?= vivado
PROJECT_DIR = neovision
XPR = $(PROJECT_DIR)/neovision.xpr
NEORV32_SW = modules/neorv32/sw
DOOM_SW = sw/doom
# Bootloader config overrides
BOOTLOADER_FLAGS = -DUART_BAUD=115200 -DEXE_BASE_ADDR=0x11000000

.PHONY: project clean bootloader bootloader-clean

project: $(XPR)

$(XPR): scripts/create_project.tcl scripts/block_design.tcl \
        $(wildcard rtl/vga/*.vhd) $(wildcard rtl/bench/*.vhd) \
        $(wildcard rtl/uart/*.vhd) constraints/arty.xdc
	$(VIVADO) -mode batch -source scripts/create_project.tcl -nojournal -nolog

bootloader:
	$(MAKE) -C $(NEORV32_SW)/bootloader CFLAGS="$(BOOTLOADER_FLAGS)" bootloader

bootloader-clean:
	$(MAKE) -C $(NEORV32_SW)/bootloader clean

doom:
	$(MAKE) -C $(DOOM_SW) clean_all exe 

clean:
	rm -rf $(PROJECT_DIR) .Xil .Xiltemp
