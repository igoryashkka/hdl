set probes_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/pluto.runs/impl_1/system_top.ltx}
set csv_file {C:/Users/user/Documents/sdr_hdl/hdl/projects/pluto/rx_ila_capture_fifo_xfer_req.csv}
open_hw_manager
connect_hw_server -allow_non_jtag
current_hw_target [lindex [get_hw_targets *] 0]
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
set_property PROBES.FILE $probes_file $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas *] 0]
puts "---ILA--- $ila"
set probes [get_hw_probes -of_objects $ila]
set index 0
foreach p $probes {
  set width "NA"
  catch { set width [get_property WIDTH $p] }
  puts "PROBE_INDEX=$index $p WIDTH=$width"
  incr index
}
set trig_probe [lindex [get_hw_probes -of_objects $ila *packed_fifo_wr_en] 0]
if {$trig_probe eq ""} {
  error "No packed_fifo_wr_en probe found"
}
puts "---TRIGGER_PROBE--- $trig_probe"
set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE {eq1'b1} $trig_probe
puts "---ARM_TRIGGER---"
run_hw_ila $ila
wait_on_hw_ila $ila
puts "---UPLOAD---"
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file $csv_file $data
puts "CSV_FILE=$csv_file"
close_hw_manager
