# constraints
# ad9363 digital interface in CMOS mode

set_property  -dict {PACKAGE_PIN  H16  IOSTANDARD LVCMOS25} [get_ports rx_clk_in]
set_property  -dict {PACKAGE_PIN  K19  IOSTANDARD LVCMOS25} [get_ports rx_frame_in]
set_property  -dict {PACKAGE_PIN  E17  IOSTANDARD LVCMOS25} [get_ports rx_data_in[0]]
set_property  -dict {PACKAGE_PIN  G18  IOSTANDARD LVCMOS25} [get_ports rx_data_in[1]]
set_property  -dict {PACKAGE_PIN  E18  IOSTANDARD LVCMOS25} [get_ports rx_data_in[2]]
set_property  -dict {PACKAGE_PIN  G19  IOSTANDARD LVCMOS25} [get_ports rx_data_in[3]]
set_property  -dict {PACKAGE_PIN  B20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[4]]
set_property  -dict {PACKAGE_PIN  F20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[5]]
set_property  -dict {PACKAGE_PIN  H20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[6]]
set_property  -dict {PACKAGE_PIN  C20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[7]]
set_property  -dict {PACKAGE_PIN  A20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[8]]
set_property  -dict {PACKAGE_PIN  D19  IOSTANDARD LVCMOS25} [get_ports rx_data_in[9]]
set_property  -dict {PACKAGE_PIN  B19  IOSTANDARD LVCMOS25} [get_ports rx_data_in[10]]
set_property  -dict {PACKAGE_PIN  J20  IOSTANDARD LVCMOS25} [get_ports rx_data_in[11]]


set_property  -dict {PACKAGE_PIN  P20 IOSTANDARD LVCMOS25} [get_ports gpio_status[0]]
set_property  -dict {PACKAGE_PIN  R18 IOSTANDARD LVCMOS25} [get_ports gpio_status[1]]
set_property  -dict {PACKAGE_PIN  R17 IOSTANDARD LVCMOS25} [get_ports gpio_status[2]]
set_property  -dict {PACKAGE_PIN  N18 IOSTANDARD LVCMOS25} [get_ports gpio_status[3]]
set_property  -dict {PACKAGE_PIN  T17 IOSTANDARD LVCMOS25} [get_ports gpio_status[4]]
set_property  -dict {PACKAGE_PIN  N17 IOSTANDARD LVCMOS25} [get_ports gpio_status[5]]
set_property  -dict {PACKAGE_PIN  R19 IOSTANDARD LVCMOS25} [get_ports gpio_status[6]]
set_property  -dict {PACKAGE_PIN  T19 IOSTANDARD LVCMOS25} [get_ports gpio_status[7]]

set_property  -dict {PACKAGE_PIN  N20 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[0]]
set_property  -dict {PACKAGE_PIN  P15 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[1]]
set_property  -dict {PACKAGE_PIN  P14 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[2]]
set_property  -dict {PACKAGE_PIN  P16 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[3]]
set_property  -dict {PACKAGE_PIN  U18 IOSTANDARD LVCMOS25} [get_ports gpio_en_agc]
set_property  -dict {PACKAGE_PIN  W19 IOSTANDARD LVCMOS25} [get_ports gpio_resetb]

set_property  -dict {PACKAGE_PIN  T20 IOSTANDARD LVCMOS25} [get_ports enable]
set_property  -dict {PACKAGE_PIN  U20 IOSTANDARD LVCMOS25} [get_ports txnrx]

set_property  -dict {PACKAGE_PIN  M14 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports iic_scl]
set_property  -dict {PACKAGE_PIN  M15 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports iic_sda]

set_property  -dict {PACKAGE_PIN  Y19 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports spi_csn]
set_property  -dict {PACKAGE_PIN  W20 IOSTANDARD LVCMOS25} [get_ports spi_clk]
set_property  -dict {PACKAGE_PIN  V20 IOSTANDARD LVCMOS25} [get_ports spi_mosi]
set_property  -dict {PACKAGE_PIN  Y18 IOSTANDARD LVCMOS25} [get_ports spi_miso]

set_property  -dict {PACKAGE_PIN  L14 IOSTANDARD LVCMOS25} [get_ports pl_spi_clk_o]
set_property  -dict {PACKAGE_PIN  N15 IOSTANDARD LVCMOS25} [get_ports pl_spi_miso]
set_property  -dict {PACKAGE_PIN  N16 IOSTANDARD LVCMOS25} [get_ports pl_spi_mosi]

create_clock -period 8.000 -name rx_clk [get_ports rx_clk_in]

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
