proc check_pin_bank {part pin} {
  create_project -in_memory -part $part
  set_property design_mode PinPlanning [current_fileset]
  open_io_design
  set pp [get_package_pins $pin]
  if {[llength $pp] == 0} {
    puts "$part $pin MISSING"
  } else {
    puts "$part $pin [get_property BANK $pp] [get_property PIN_FUNC $pp]"
  }
  close_project
}
check_pin_bank xc7z020clg400-2 U18
check_pin_bank xc7z020clg400-1 U18
check_pin_bank xc7z020clg484-1 U18
check_pin_bank xc7z010clg400-1 U18
exit
