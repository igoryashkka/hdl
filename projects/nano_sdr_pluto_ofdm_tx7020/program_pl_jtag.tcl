# Loads the OFDM PHY TX bitstream into the PL of a running Zynq-7020 Pluto over JTAG (Linux keeps running; lost on reboot).
#   xsdb program_pl_jtag.tcl [path/to/system_top.bit [jtag_cable_serial]]   (the serial is needed when several JTAG cables are connected)
# Which bitstream is in the PL is checked afterwards on the board: `plutolink diag` must report the PHY ID OFTX.
set here [file dirname [file normalize [info script]]]
set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : [file join $here nano_sdr_pluto_ofdm_tx7020.runs impl_1 system_top.bit]}]
puts "bitstream: $bit"
connect
if {[llength $argv] > 1} {
  targets -set -filter [format {name =~ "xc7z0*" && jtag_cable_serial == "%s"} [lindex $argv 1]]   ;# the PL device of that cable
} else {
  targets -set -filter {name =~ "*Cortex-A9*#0"}
}
fpga -file $bit
puts "PL programmed. Next: reload the AD9361 drivers, then run plutolink diag on the board (expects PHY ID OFTX)."
disconnect
exit
