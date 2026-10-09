# Register / memory breakdown by name pattern after out-of-context synthesis (analysis helper):
#   vivado -mode batch -source ff_breakdown.tcl -tclargs <top> <part> <out.txt> <pattern> [pattern ...]
set top [lindex $argv 0]; set part [lindex $argv 1]; set out [lindex $argv 2]; set pats [lrange $argv 3 end]
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
synth_design -top $top -part $part -mode out_of_context -generic CODED=1 -flatten_hierarchy none
set fh [open $out w]
puts $fh "top $top"
foreach p $pats {
  set ff   [llength [get_cells -quiet -hier -filter "REF_NAME =~ FD* && NAME =~ *${p}*"]]
  set srl  [llength [get_cells -quiet -hier -filter "REF_NAME =~ SRL* && NAME =~ *${p}*"]]
  set ram  [llength [get_cells -quiet -hier -filter "(REF_NAME =~ RAM* || REF_NAME =~ RAMB*) && NAME =~ *${p}*"]]
  puts $fh "$p FF $ff SRL $srl RAM $ram"
}
close $fh
puts "FF_BREAKDOWN_DONE"
