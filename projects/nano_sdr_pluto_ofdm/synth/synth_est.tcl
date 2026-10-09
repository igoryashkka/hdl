# Out-of-context synthesis ESTIMATE of phy_rx_top / phy_tx_top (resource fit check, no implementation):
#   vivado -mode batch -source synth_est.tcl -tclargs <top> <part> <outdir> [GENERIC:value ...]   (":" because the vivado.bat wrapper splits arguments at "=")
# e.g. phy_rx_top / phy_tx_top on xczu27dr-ffve1156-1-i (reference part of ТЗ 003). Reports: utilization (post-synthesis), timing summary (un-routed, indicative only).
set top  [lindex $argv 0]
set part [lindex $argv 1]
set out  [lindex $argv 2]
file mkdir $out
set root [file normalize [file join [file dirname [info script]] ..]]
set pk [list common/phy_pkg.sv common/phy_ldpc_pkg.sv common/phy_soft_pkg.sv]
set files $pk
foreach d {common tx rx} {
  foreach f [lsort [glob -nocomplain -directory [file join $root rtl $d] *.sv *.v]] {
    set rel "$d/[file tail $f]"
    if {[lsearch $pk $rel] < 0 && [file tail $f] ne "phy_rx_axis_top.v" && [file tail $f] ne "phy_tx_axis_top.v" && [file tail $f] ne "phy_regs_axil.v"} { lappend files $rel }
  }
}
foreach f $files { read_verilog -sv [file join $root rtl $f] }
set_part $part
# further generics of the top (e.g. CA:1 UA_HW:0) follow the output directory on the command line
set gen [list -generic CODED=1]
foreach g [lrange $argv 3 end] { lappend gen -generic [string map {: =} $g] }
synth_design -top $top -part $part -mode out_of_context {*}$gen -flatten_hierarchy rebuilt
create_clock -period 8.000 -name clk [get_ports clk]
report_utilization -file [file join $out ${top}_util.rpt]
report_utilization -hierarchical -file [file join $out ${top}_util_hier.rpt]
report_timing_summary -max_paths 200 -file [file join $out ${top}_timing.rpt]
puts "SYNTH_EST_DONE $top"
