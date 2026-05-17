open_hw_manager
connect_hw_server
open_hw_target

set devices [get_hw_devices]
puts "JTAG_DEVICES_BEGIN"
foreach device $devices {
  puts "DEVICE=$device PART=[get_property PART $device]"
}
puts "JTAG_DEVICES_END"

set fpga_devices [get_hw_devices xc7z*]
if {[llength $fpga_devices] == 0} {
  puts "ERROR: no xc7z FPGA device found on JTAG"
  exit 1
}

set device [lindex $fpga_devices 0]
current_hw_device $device
refresh_hw_device $device

puts "CURRENT_DEVICE=$device"
puts "PART=[get_property PART $device]"

set usr_access_status [catch {get_property REGISTER.USR_ACCESS $device} usr_access]
if {$usr_access_status == 0} {
  puts "USR_ACCESS=$usr_access"
} else {
  puts "USR_ACCESS_READ_ERROR=$usr_access"
  puts "AVAILABLE_REGISTER_PROPERTIES_BEGIN"
  foreach property [list_property $device] {
    if {[string match "REGISTER*" $property]} {
      catch {puts "$property=[get_property $property $device]"}
    }
  }
  puts "AVAILABLE_REGISTER_PROPERTIES_END"
  exit 2
}

close_hw_manager
exit 0
