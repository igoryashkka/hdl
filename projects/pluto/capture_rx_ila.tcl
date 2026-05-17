set probes_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.ltx}
set csv_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/rx_ila_capture_jtag.csv}
open_hw_manager
connect_hw_server -allow_non_jtag
current_hw_target [lindex [get_hw_targets *] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
set_property PROBES.FILE $probes_file $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas *] 0]
puts "---ILA--- $ila"
puts "---ILA_PROBES_OF_OBJECT---"
foreach p [get_hw_probes -of_objects $ila] {
  set width "NA"
  catch { set width [get_property WIDTH $p] }
  puts "$p WIDTH=$width"
}
puts "---RUN_CAPTURE---"
set_property CONTROL.TRIGGER_POSITION 512 $ila
if {[catch {run_hw_ila -trigger_now $ila} err]} {
  puts "RUN_TRIGGER_NOW_FAILED=$err"
  run_hw_ila $ila
} else {
  puts "RUN_TRIGGER_NOW_OK"
}
wait_on_hw_ila $ila
puts "---UPLOAD---"
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
puts "CSV_FILE=$csv_file"
close_hw_manager
