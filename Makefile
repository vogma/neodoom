VIVADO ?= vivado
PROJECT_DIR = neovision
XPR = $(PROJECT_DIR)/neovision.xpr

.PHONY: project clean

project: $(XPR)

$(XPR): scripts/create_project.tcl scripts/block_design.tcl \
        $(wildcard rtl/vga/*.vhd) $(wildcard rtl/bench/*.vhd) \
        $(wildcard rtl/uart/*.vhd) constraints/arty.xdc
	$(VIVADO) -mode batch -source scripts/create_project.tcl -nojournal -nolog

clean:
	rm -rf $(PROJECT_DIR) .Xil .Xiltemp
