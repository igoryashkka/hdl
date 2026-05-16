# =============================================================================
# Corrected XDC for 7020_936x SDR Board (ZYNQ-7020 CLG400 + AD936x)
# Generated from schematic: 7020_936x_SDR原理图.pdf  (2025-02-15)
# =============================================================================
# Bank voltage summary:
#   Bank 13 (HR, T8/U11/W7/Y10): VCCO = VCC3V3 or VCC2V5 — LVDS_25 / LVCMOS25
#   Bank 34 (HR, N19/R15/T18…):  VCCO = VCC3V3              — LVCMOS33 (unused here)
#   Bank 35 (HR, C19/F18/H14…):  VCCO = VCC1V8              — LVCMOS18
# =============================================================================

# -----------------------------------------------------------------------------
# AD936x LVDS Data Interface  —  Bank 13
# DATA_CLK  (receive clock from AD9361 → FPGA)
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_clk_in_p]        ;# DATA_CLK_P
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_clk_in_n]        ;# DATA_CLK_N

# FB_CLK  (feedback/transmit clock from FPGA → AD9361)
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVDS_25}                 [get_ports tx_clk_out_p]       ;# FB_CLK_P
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVDS_25}                 [get_ports tx_clk_out_n]       ;# FB_CLK_N

# RX Frame
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_frame_in_p]      ;# RX_FRAME_P
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_frame_in_n]      ;# RX_FRAME_N

# TX Frame
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVDS_25}                 [get_ports tx_frame_out_p]     ;# TX_FRAME_P
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVDS_25}                 [get_ports tx_frame_out_n]     ;# TX_FRAME_N

# RX Data [5:0]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[0]]    ;# RX_D0_P
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[0]]    ;# RX_D0_N
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[1]]    ;# RX_D1_P
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[1]]    ;# RX_D1_N
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[2]]    ;# RX_D2_P
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[2]]    ;# RX_D2_N
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[3]]    ;# RX_D3_P
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[3]]    ;# RX_D3_N
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[4]]    ;# RX_D4_P
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[4]]    ;# RX_D4_N
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_p[5]]    ;# RX_D5_P
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVDS_25 DIFF_TERM TRUE}  [get_ports rx_data_in_n[5]]    ;# RX_D5_N

# TX Data [5:0]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[0]]   ;# TX_D0_P
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[0]]   ;# TX_D0_N
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[1]]   ;# TX_D1_P
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[1]]   ;# TX_D1_N
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[2]]   ;# TX_D2_P
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[2]]   ;# TX_D2_N
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[3]]   ;# TX_D3_P
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[3]]   ;# TX_D3_N
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[4]]   ;# TX_D4_P
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[4]]   ;# TX_D4_N
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_p[5]]   ;# TX_D5_P
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVDS_25}                 [get_ports tx_data_out_n[5]]   ;# TX_D5_N

# -----------------------------------------------------------------------------
# AD936x Control / SPI  —  Bank 13 (LVCMOS25)
# (P14–P20, R14–R19, T9–T19 are all Bank 13 per schematic U1B)
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS25}                [get_ports enable]             ;# ENABLE
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS25}                [get_ports txnrx]              ;# TXNRX
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS25}                [get_ports gpio_en_agc]        ;# EN_AGC
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS25}                [get_ports gpio_resetb]        ;# RF_RESET  (IO_0 of Bank 13)
# Optional signals from some Pluto variants; currently not present in system_top
# set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS25}                [get_ports ad936x_sync]        ;# AD936X_SYNC (IO_25 of Bank 13)
# set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS25}                [get_ports clk_out]            ;# CLK_OUT from AD9361 (IO_L19P_T3)
# set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS25}                [get_ports ptt_io]             ;# PTT_IO

# SPI  (all Bank 13)
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS25 PULLTYPE PULLUP} [get_ports spi_csn]           ;# SPI_CS   (IO_L19N_T3_VREF)
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS25}                [get_ports spi_clk]            ;# SPI_CLK  (IO_L21N_T3_DQS)
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS25}                [get_ports spi_mosi]           ;# SPI_MOSI (IO_L24N_T3)
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS25}                [get_ports spi_miso]           ;# SPI_MISO (IO_L21P_T3_DQS)

# Auxiliary PL-side SPI and I2C lines used by current top-level
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS18}                [get_ports pl_spi_clk_o]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS18}                [get_ports pl_spi_miso]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS18}                [get_ports pl_spi_mosi]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS18 PULLTYPE PULLUP} [get_ports iic_scl]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS18 PULLTYPE PULLUP} [get_ports iic_sda]

# -----------------------------------------------------------------------------
# AD936x CTRL_OUT[7:0]  (gpio_status in HDL)
# NOTE: [0..2,5,6] are Bank 35 (1.8 V); [3,4,7] are Bank 13 (2.5 V).
# Each pin must use the IOSTANDARD of its own bank.
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS18} [get_ports gpio_status[0]]  ;# CTRL_OUT0 – Bank 35
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS18} [get_ports gpio_status[1]]  ;# CTRL_OUT1 – Bank 35
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS18} [get_ports gpio_status[2]]  ;# CTRL_OUT2 – Bank 35
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS25} [get_ports gpio_status[3]]  ;# CTRL_OUT3 – Bank 13
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS25} [get_ports gpio_status[4]]  ;# CTRL_OUT4 – Bank 13
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS18} [get_ports gpio_status[5]]  ;# CTRL_OUT5 – Bank 35
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS18} [get_ports gpio_status[6]]  ;# CTRL_OUT6 – Bank 35
set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS25} [get_ports gpio_status[7]]  ;# CTRL_OUT7 – Bank 13 (IO_L14P_T2_SRCC)

# -----------------------------------------------------------------------------
# AD936x CTRL_IN[3:0]  (gpio_ctl in HDL)
# NOTE: [0,1,3] are Bank 35 (1.8 V); [2] is Bank 13 (2.5 V).
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[0]]     ;# CTRL_IN0 – Bank 35
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[1]]     ;# CTRL_IN1 – Bank 35
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS25} [get_ports gpio_ctl[2]]     ;# CTRL_IN2 – Bank 13 (IO_L6N_T0_VREF)
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS18} [get_ports gpio_ctl[3]]     ;# CTRL_IN3 – Bank 35

# -----------------------------------------------------------------------------
# JP5 External I/O connector
#   1V8 differential pairs  —  Bank 35 (LVCMOS18)
# -----------------------------------------------------------------------------
# Optional JP5 I/O, currently not present in system_top
# set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS18} [get_ports io_1v8_p[0]]    ;# 1V8_IO1_P (IO_L18P_T2)
# set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports io_1v8_n[0]]    ;# 1V8_IO1_N (IO_L18N_T2)
# set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS18} [get_ports io_1v8_p[1]]    ;# 1V8_IO3_P (IO_L14P_T2_SRCC)
# set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS18} [get_ports io_1v8_n[1]]    ;# 1V8_IO3_N (IO_L14N_T2_SRCC)
# set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS18} [get_ports io_1v8_p[2]]    ;# 1V8_IO5_P (IO_L13P_T2_MRCC)
# set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS18} [get_ports io_1v8_n[2]]    ;# 1V8_IO5_N (IO_L13N_T2_MRCC)
# set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS18} [get_ports io_1v8_p[3]]    ;# 1V8_IO7_P (IO_L22P_T3)
# set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS18} [get_ports io_1v8_n[3]]    ;# 1V8_IO7_N (IO_L22N_T3)

#   3V3 single-ended (Bank 13, routed via U1G)
# set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS25} [get_ports io_3v3[0]]      ;# 3V3_IO1 (IO_L20N_T3)
# set_property -dict {PACKAGE_PIN U9  IOSTANDARD LVCMOS25} [get_ports io_3v3[1]]      ;# 3V3_IO2 (IO_L16P_T1)
# set_property -dict {PACKAGE_PIN U10 IOSTANDARD LVCMOS25} [get_ports io_3v3[2]]      ;# 3V3_IO3 (IO_L16N_T2)
# set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS25} [get_ports io_3v3[3]]      ;# 3V3_IO4 (IO_L12P_T1)

# -----------------------------------------------------------------------------
# Clocks  —  oscillator / AD9361 reference
# -----------------------------------------------------------------------------
# 50 MHz PL fabric clock  —  Bank 13, IO_L13P_T2_MRCC (MRCC-capable)
# Optional fabric reference clock, currently not present in system_top
# set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS25} [get_ports pl_gclk]        ;# PL_GCLK 50 MHz (Y1 → R63)

# 40 MHz AD936x reference clock output from FPGA  —  Bank 35, IO_L12P_T1_MRCC
# set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS18} [get_ports fpga_clk]       ;# FPGA_CLK → AD9361 EXT_CLK (Y3 → R107)

# -----------------------------------------------------------------------------
# Timing constraints
# -----------------------------------------------------------------------------
# AD9361 DATA_CLK: maximum 245.76 MHz (LVDS @ 2×122.88 MS/s)
create_clock -period 4.069 -name rx_clk [get_ports rx_clk_in_p]

# 50 MHz PL GCLK (Y1 oscillator)
# create_clock -period 20.000 -name pl_gclk [get_ports pl_gclk]

# PS fabric clocks from Zynq PS7
create_clock -name clk_fpga_0 -period 10 \
    [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[0]"]
create_clock -name clk_fpga_1 -period  5 \
    [get_pins "i_system_wrapper/system_i/sys_ps7/inst/PS7_i/FCLKCLK[1]"]

# PS SPI0 (EMIO — to AD9361 SPI)
create_clock -name spi0_clk -period 40 [get_pins -hier */EMIOSPI0SCLKO]

set_input_jitter clk_fpga_0 0.3
set_input_jitter clk_fpga_1 0.15
