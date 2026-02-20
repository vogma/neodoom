# create_project.tcl - Creates Vivado project for neodoom
#
# Usage: vivado -mode batch -source scripts/create_project.tcl -nojournal -nolog

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set project_name "neodoom"

# Remove existing project if it exists
if {[file exists ${project_dir}/${project_name}]} {
    puts "Removing existing project directory..."
    file delete -force ${project_dir}/${project_name}
}

# Create project
create_project $project_name ${project_dir}/${project_name} -part xc7a100tcsg324-1 -force
set_property BOARD_PART digilentinc.com:arty-a7-100:part0:1.1 [current_project]

# Set VHDL as default for new files
set_property target_language VHDL [current_project]
set_property default_lib work [current_project]

# NEORV32 submodule paths
set neorv32_dir ${project_dir}/modules/neorv32

# Add NEORV32 core files (must be in library 'neorv32')
set neorv32_core_files [glob -directory ${neorv32_dir}/rtl/core *.vhd]
add_files -norecurse $neorv32_core_files
set_property library neorv32 [get_files -filter {NAME =~ */neorv32/rtl/core/*.vhd}]

# Add NEORV32 system integration files (Vivado IP wrapper + AXI bridge)
add_files -norecurse ${neorv32_dir}/rtl/system_integration/neorv32_vivado_ip.vhd
add_files -norecurse ${neorv32_dir}/rtl/system_integration/xbus2axi4_bridge.vhd
set_property library neorv32 [get_files */neorv32_vivado_ip.vhd]
set_property library neorv32 [get_files */xbus2axi4_bridge.vhd]

# Add VGA modules (required by block design)
add_files -norecurse ${project_dir}/rtl/vga/vga_controller.vhd
add_files -norecurse ${project_dir}/rtl/vga/vga_dma.vhd

# Add AXI benchmark and UART helper
add_files -norecurse ${project_dir}/rtl/uart/uart_tx_own.vhd
add_files -norecurse ${project_dir}/rtl/bench/ddr_axi_read_bench.vhd

# Add other RTL modules that may be useful
# (comment out if not needed)
# add_files -norecurse ${project_dir}/rtl/common/common_pkg.vhd
# add_files -norecurse ${project_dir}/rtl/camera/ov7670_capture.vhd
# add_files -norecurse ${project_dir}/rtl/debounce/debounce.vhd

# Add constraints
add_files -fileset constrs_1 -norecurse ${project_dir}/constraints/arty.xdc

# Source the block design TCL
# This creates the block design with all IP and connections
source ${script_dir}/block_design.tcl

# Generate the HDL wrapper for the block design
# Use Verilog because SmartConnect IP fails VHDL wrapper generation
# Temporarily switch target language to Verilog for wrapper generation
set_property target_language Verilog [current_project]

set bd_file [get_files -filter {NAME =~ *.bd}]
make_wrapper -files $bd_file -top -force

# Find the generated wrapper file
set wrapper_file [glob ${project_dir}/${project_name}/${project_name}.gen/sources_1/bd/*/hdl/*_wrapper.v]
puts "Generated wrapper: $wrapper_file"

# Add the wrapper to the project
add_files -norecurse $wrapper_file

# Set wrapper as top module
set_property top test_bd_design_wrapper [current_fileset]

update_compile_order -fileset sources_1
