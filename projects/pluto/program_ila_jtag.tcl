set bit_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.bit}
set probes_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.ltx}
open_hw_manager
connect_hw_server -allow_non_jtag
current_hw_target [lindex [get_hw_targets *] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
puts "---PROGRAM_DEVICE--- $dev"
set_property PROGRAM.FILE $bit_file $dev
set_property PROBES.FILE $probes_file $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "---HW_ILAS_AFTER_PROGRAM---"
set ilas [get_hw_ilas *]
if {[llength $ilas] == 0} { puts "NO_HW_ILA" } else { foreach i $ilas { puts $i } }
puts "---HW_PROBES---"
foreach p [get_hw_probes *] { puts "$p WIDTH=[get_property WIDTH $p]" }
close_hw_manager
