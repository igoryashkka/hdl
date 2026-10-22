# constraints
# ad9361 (SWAP == 0x1)

set_property  -dict {PACKAGE_PIN  U18  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_clk_in_p]
set_property  -dict {PACKAGE_PIN  U19  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_clk_in_n]
set_property  -dict {PACKAGE_PIN  Y16  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_frame_in_p]
set_property  -dict {PACKAGE_PIN  Y17  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_frame_in_n]
set_property  -dict {PACKAGE_PIN  Y18  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[0]]
set_property  -dict {PACKAGE_PIN  Y19  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[0]]
set_property  -dict {PACKAGE_PIN  T16  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[1]]
set_property  -dict {PACKAGE_PIN  U17  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[1]]
set_property  -dict {PACKAGE_PIN  V20  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[2]]
set_property  -dict {PACKAGE_PIN  W20  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[2]]
set_property  -dict {PACKAGE_PIN  T17  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[3]]
set_property  -dict {PACKAGE_PIN  R18  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[3]]
set_property  -dict {PACKAGE_PIN  T20  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[4]]
set_property  -dict {PACKAGE_PIN  U20  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[4]]
set_property  -dict {PACKAGE_PIN  W18  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_p[5]]
set_property  -dict {PACKAGE_PIN  W19  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports rx_data_in_n[5]]

set_property  -dict {PACKAGE_PIN  U14  IOSTANDARD LVDS_25} [get_ports tx_clk_out_p]
set_property  -dict {PACKAGE_PIN  U15  IOSTANDARD LVDS_25} [get_ports tx_clk_out_n]
set_property  -dict {PACKAGE_PIN  V16  IOSTANDARD LVDS_25} [get_ports tx_frame_out_p]
set_property  -dict {PACKAGE_PIN  W16  IOSTANDARD LVDS_25} [get_ports tx_frame_out_n]
set_property  -dict {PACKAGE_PIN  V15  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[0]]
set_property  -dict {PACKAGE_PIN  W15  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[0]]
set_property  -dict {PACKAGE_PIN  V12  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[1]]
set_property  -dict {PACKAGE_PIN  W13  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[1]]
set_property  -dict {PACKAGE_PIN  W14  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[2]]
set_property  -dict {PACKAGE_PIN  Y14  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[2]]
set_property  -dict {PACKAGE_PIN  T12  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[3]]
set_property  -dict {PACKAGE_PIN  U12  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[3]]
set_property  -dict {PACKAGE_PIN  T11  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[4]]
set_property  -dict {PACKAGE_PIN  T10  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[4]]
set_property  -dict {PACKAGE_PIN  U13  IOSTANDARD LVDS_25} [get_ports tx_data_out_p[5]]
set_property  -dict {PACKAGE_PIN  V13  IOSTANDARD LVDS_25} [get_ports tx_data_out_n[5]]

set_property  -dict {PACKAGE_PIN  L20 IOSTANDARD LVCMOS25} [get_ports gpio_status[0]]
set_property  -dict {PACKAGE_PIN  L19 IOSTANDARD LVCMOS25} [get_ports gpio_status[1]]
set_property  -dict {PACKAGE_PIN  K19 IOSTANDARD LVCMOS25} [get_ports gpio_status[2]]
set_property  -dict {PACKAGE_PIN  T14 IOSTANDARD LVCMOS25} [get_ports gpio_status[3]]
set_property  -dict {PACKAGE_PIN  P15 IOSTANDARD LVCMOS25} [get_ports gpio_status[4]]
set_property  -dict {PACKAGE_PIN  M20 IOSTANDARD LVCMOS25} [get_ports gpio_status[5]]
set_property  -dict {PACKAGE_PIN  M19 IOSTANDARD LVCMOS25} [get_ports gpio_status[6]]
set_property  -dict {PACKAGE_PIN  N20 IOSTANDARD LVCMOS25} [get_ports gpio_status[7]]

set_property  -dict {PACKAGE_PIN  J19 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[0]]
set_property  -dict {PACKAGE_PIN  K14 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[1]]
set_property  -dict {PACKAGE_PIN  L17 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[2]]
set_property  -dict {PACKAGE_PIN  J20 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[3]]
set_property  -dict {PACKAGE_PIN  P20 IOSTANDARD LVCMOS25} [get_ports gpio_en_agc]
set_property  -dict {PACKAGE_PIN  R19 IOSTANDARD LVCMOS25} [get_ports gpio_resetb]

set_property  -dict {PACKAGE_PIN  T15 IOSTANDARD LVCMOS25} [get_ports enable]
set_property  -dict {PACKAGE_PIN  P18 IOSTANDARD LVCMOS25} [get_ports txnrx]

set_property  -dict {PACKAGE_PIN  M14 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports iic_scl]
set_property  -dict {PACKAGE_PIN  M15 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports iic_sda]

set_property  -dict {PACKAGE_PIN  R17 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports spi_csn]
set_property  -dict {PACKAGE_PIN  V18 IOSTANDARD LVCMOS25} [get_ports spi_clk]
set_property  -dict {PACKAGE_PIN  P16 IOSTANDARD LVCMOS25} [get_ports spi_mosi]
set_property  -dict {PACKAGE_PIN  V17 IOSTANDARD LVCMOS25} [get_ports spi_miso]

set_property  -dict {PACKAGE_PIN  L14 IOSTANDARD LVCMOS25} [get_ports pl_spi_clk_o]
set_property  -dict {PACKAGE_PIN  N15 IOSTANDARD LVCMOS25} [get_ports pl_spi_miso]
set_property  -dict {PACKAGE_PIN  N16 IOSTANDARD LVCMOS25} [get_ports pl_spi_mosi]

# 4 ns as in projects/pluto: the AD9361 driver starts at 61.44 MS/s (l_clk = LVDS DATA_CLK 245.76 MHz) and tunes the LVDS interface
# there, so axi_ad9361 / DMA must close at 4 ns (with 8 ns the tuning failed and the TX data reaching the AD9363 was corrupted).
create_clock -period 4.000 -name rx_clk [get_ports rx_clk_in_p]

create_clock -name clk_fpga_0 -period 10 [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[0]"]
create_clock -name clk_fpga_1 -period  5 [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[1]"]
create_clock -name spi0_clk -period 40 [get_pins -hier */EMIOSPI0SCLKO]

set_input_jitter clk_fpga_0 0.3
set_input_jitter clk_fpga_1 0.15

set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_rx/i_up_adc_common/up_adc_gpio_out_int_reg[0]/C}]
set_false_path -from [get_pins {i_system_wrapper/system_i/axi_ad9361/inst/i_tx/i_up_dac_common/up_dac_gpio_out_int_reg[0]/C}]

# Encode build timestamp into USR_ACCESS register for runtime fingerprinting
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ---- OFDM PHY register block (phy_regs_axil): clock-domain crossings are handshaked / 2-FF synchronised ----
set_false_path -to   [get_cells -hier -quiet -filter {NAME =~ *u_regs/*_s1_reg*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_regs/stat_bank_reg*}]
set_false_path -from [get_cells -hier -quiet -filter {NAME =~ *u_regs/cfg_s2_reg*}]   ;# configuration is static while the PHY runs

# ---- OFDM PHY TX: used only at 30.72 MS/s (l_clk 122.88 MHz in 2R2T), its paths get two l_clk periods (8 ns). At 61.44 MS/s the PHY
# output is not selected by the DAC core (driver tuning uses its own patterns). The register block (u_regs, CPU clock) keeps one period.
set_multicycle_path -setup 2 -from [get_cells -hier -filter {NAME =~ *phy_tx/inst/* && NAME !~ *phy_tx/inst/u_regs/*}]
set_multicycle_path -hold  1 -from [get_cells -hier -filter {NAME =~ *phy_tx/inst/* && NAME !~ *phy_tx/inst/u_regs/*}]
set_multicycle_path -setup 2 -to   [get_cells -hier -filter {NAME =~ *phy_tx/inst/* && NAME !~ *phy_tx/inst/u_regs/*}]
set_multicycle_path -hold  1 -to   [get_cells -hier -filter {NAME =~ *phy_tx/inst/* && NAME !~ *phy_tx/inst/u_regs/*}]
