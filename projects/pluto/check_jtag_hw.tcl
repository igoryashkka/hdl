open_hw_manager
connect_hw_server -allow_non_jtag
puts "---HW_TARGETS---"
foreach t [get_hw_targets *] { puts $t }
set targets [get_hw_targets *]
if {[llength $targets] > 0} {
  current_hw_target [lindex $targets 0]
  open_hw_target
  puts "---HW_DEVICES---"
  foreach d [get_hw_devices] { puts "$d PART=[get_property PART $d] PROGRAMMED=[get_property PROGRAM.IS_PROGRAMMED $d]" }
  puts "---HW_ILAS---"
  foreach i [get_hw_ilas *] { puts $i }
}
close_hw_manager
