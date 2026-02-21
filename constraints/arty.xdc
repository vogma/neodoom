## This file is a general .xdc for the Arty A7-35 Rev. D

## For default neorv32_test_setup.vhd top entity

## Clock signal
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports { sys_clk }]; #IO_L12P_T1_MRCC_35 Sch=gclk[100]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { sys_clk }];

# CDC: vga_controller (pxl_clk) -> vga_dma (ui_clk)
set_false_path -to [get_pins -hier *vga_dma_engine_0*/inst/vblank_sync_ff1_reg/D]

## RGB LEDs
#set_property -dict { PACKAGE_PIN E1    IOSTANDARD LVCMOS33 } [get_ports { led0_b }]; #IO_L18N_T2_35 Sch=led0_b
#set_property -dict { PACKAGE_PIN F6    IOSTANDARD LVCMOS33 } [get_ports { led0_g }]; #IO_L19N_T3_VREF_35 Sch=led0_g
set_property -dict { PACKAGE_PIN G6    IOSTANDARD LVCMOS33 } [get_ports { led_cpu[0] }]; #IO_L19P_T3_35 Sch=led0_r
#set_property -dict { PACKAGE_PIN G4    IOSTANDARD LVCMOS33 } [get_ports { led1_b }]; #IO_L20P_T3_35 Sch=led1_b
#set_property -dict { PACKAGE_PIN J4    IOSTANDARD LVCMOS33 } [get_ports { led1_g }]; #IO_L21P_T3_DQS_35 Sch=led1_g
set_property -dict { PACKAGE_PIN G3    IOSTANDARD LVCMOS33 } [get_ports { led_cpu[1] }]; #IO_L20N_T3_35 Sch=led1_r
#set_property -dict { PACKAGE_PIN H4    IOSTANDARD LVCMOS33 } [get_ports { led2_b }]; #IO_L21N_T3_DQS_35 Sch=led2_b
#set_property -dict { PACKAGE_PIN J2    IOSTANDARD LVCMOS33 } [get_ports { led2_g }]; #IO_L22N_T3_35 Sch=led2_g
set_property -dict { PACKAGE_PIN J3    IOSTANDARD LVCMOS33 } [get_ports { led_cpu[2] }]; #IO_L22P_T3_35 Sch=led2_r
#set_property -dict { PACKAGE_PIN K2    IOSTANDARD LVCMOS33 } [get_ports { led3_b }]; #IO_L23P_T3_35 Sch=led3_b
#set_property -dict { PACKAGE_PIN H6    IOSTANDARD LVCMOS33 } [get_ports { led3_g }]; #IO_L24P_T3_35 Sch=led3_g
set_property -dict { PACKAGE_PIN K1    IOSTANDARD LVCMOS33 } [get_ports { led_cpu[3] }]; #IO_L23N_T3_35 Sch=led3_r

## LEDs
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L24N_T3_35 Sch=led[4]
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_25_35 Sch=led[5]
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L24P_T3_A01_D17_14 Sch=led[6]
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33}  [get_ports { led[3] }];
#set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { init_calib_complete }]; #IO_L24N_T3_A00_D16_14 Sch=led[7]

## Pmod Header JA (unused GPIO outputs)
#set_property -dict { PACKAGE_PIN G13  IOSTANDARD LVCMOS33 } [get_ports { gpio_o[4] }]; #IO_0_15 Sch=ja[1]
#set_property -dict { PACKAGE_PIN B11  IOSTANDARD LVCMOS33 } [get_ports { gpio_o[5] }]; #IO_L4P_T0_15 Sch=ja[2]
#set_property -dict { PACKAGE_PIN A11  IOSTANDARD LVCMOS33 } [get_ports { gpio_o[6] }]; #IO_L4N_T0_15 Sch=ja[3]
#set_property -dict { PACKAGE_PIN D12  IOSTANDARD LVCMOS33 } [get_ports { gpio_o[7] }]; #IO_L6P_T0_15 Sch=ja[4]

## USB-UART Interface
set_property -dict { PACKAGE_PIN D10  IOSTANDARD LVCMOS33 } [get_ports { uart0_txd_o }]; #IO_L19N_T3_VREF_16 Sch=uart_rxd_out
set_property -dict { PACKAGE_PIN A9   IOSTANDARD LVCMOS33 } [get_ports { uart0_rxd_i }]; #IO_L14N_T2_SRCC_16 Sch=uart_txd_in

## Buttons
set_property -dict { PACKAGE_PIN D9   IOSTANDARD LVCMOS33 } [get_ports { cpu_reset }]; #IO_L6N_T0_VREF_16 Sch=btn[0]

## Misc.
set_property -dict { PACKAGE_PIN C2   IOSTANDARD LVCMOS33 } [get_ports { resetn }]; #IO_L16P_T2_35 Sch=ck_rst
#set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets test_bd_design_i/neorv32_SystemTop_axi4lite/inst/neorv32_top_inst/io_system.neorv32_trng_inst_true.neorv32_trng_inst/neoTRNG_inst/neoTRNG_cell_inst[0].neoTRNG_cell_inst_i/enable_sreg_l_reg[0]_0]


## Pmod Header JB - Pmod microSD (SPI mode)
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports { spi_clk_o }];    # JB4  SCLK
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports { spi_dat_o }];    # JB2  MOSI
set_property -dict { PACKAGE_PIN D15 IOSTANDARD LVCMOS33 } [get_ports { spi_dat_i }];    # JB3  MISO
set_property -dict { PACKAGE_PIN E15 IOSTANDARD LVCMOS33 } [get_ports { spi_csn_sd_o }]; # JB1  CS



set_property CLOCK_DEDICATED_ROUTE TRUE [get_nets test_bd_design_i/clk_wiz_0/inst/clk_out1]

## Pmod Header JC
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {VGA_R[0]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {VGA_R[1]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports {VGA_R[2]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {VGA_R[3]}]
set_property -dict {PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { VGA_B[0] }]; #IO_L22P_T3_A05_D21_14 Sch=jc_p[3]
set_property -dict {PACKAGE_PIN V14   IOSTANDARD LVCMOS33 } [get_ports { VGA_B[1] }]; #IO_L22N_T3_A04_D20_14 Sch=jc_n[3]
set_property -dict {PACKAGE_PIN T13   IOSTANDARD LVCMOS33 } [get_ports { VGA_B[2] }]; #IO_L23P_T3_A03_D19_14 Sch=jc_p[4]
set_property -dict {PACKAGE_PIN U13   IOSTANDARD LVCMOS33 } [get_ports { VGA_B[3] }]; #IO_L23N_T3_A02_D18_14 Sch=jc_n[4]

## Pmod Header JD
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {VGA_G[0]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33} [get_ports {VGA_G[1]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {VGA_G[2]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {VGA_G[3]}]
set_property -dict { PACKAGE_PIN E2    IOSTANDARD LVCMOS33 } [get_ports { VGA_HS_O }]; #IO_L14P_T2_SRCC_35 Sch=jd[7]
set_property -dict { PACKAGE_PIN D2    IOSTANDARD LVCMOS33 } [get_ports { VGA_VS_O }]; #IO_L14N_T2_SRCC_35 Sch=jd[8]
#set_property -dict { PACKAGE_PIN H2    IOSTANDARD LVCMOS33 } [get_ports { jd[6] }]; #IO_L15P_T2_DQS_35 Sch=jd[9]
#set_property -dict { PACKAGE_PIN G2    IOSTANDARD LVCMOS33 } [get_ports { jd[7] }]; #IO_L15N_T2_DQS_35 Sch=jd[10]


