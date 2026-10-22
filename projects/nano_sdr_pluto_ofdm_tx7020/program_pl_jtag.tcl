# Loads the OFDM PHY TX bitstream into the PL of a running Zynq-7020 Pluto over JTAG (Linux keeps running; lost on reboot).
#   xsdb program_pl_jtag.tcl [path/to/system_top.bit]
# Prints USR_ACCESS (build timestamp written by Vivado) to prove which bitstream is in the PL.
set here [file dirname [file normalize [info script]]]
set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : [file join $here nano_sdr_pluto_ofdm_tx7020.runs impl_1 system_top.bit]}]
puts "bitstream: $bit"
connect
targets -set -filter {name =~ "*Cortex-A9*#0"}
fpga -file $bit
puts "USR_ACCESS = [format 0x%08X [mrd -value 0xF8007080]]"
disconnect
exit
