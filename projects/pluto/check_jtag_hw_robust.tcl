open_hw_manager
connect_hw_server -allow_non_jtag
puts "---HW_TARGETS---"
foreach t [get_hw_targets *] { puts $t }
set targets [get_hw_targets *]
if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  open_hw_target
  puts "---HW_DEVICES---"
  foreach d [get_hw_devices] {
    set part "NA"
    set prog "NA"
    catch { set part [get_property PART $d] }
    catch { set prog [get_property PROGRAM.IS_PROGRAMMED $d] }
    puts "$d PART=$part PROGRAMMED=$prog"
  }
  puts "---HW_ILAS---"
  set ilas [get_hw_ilas *]
  if {[llength $ilas] == 0} { puts "NO_HW_ILA" } else { foreach i $ilas { puts $i } }
}
close_hw_manager
