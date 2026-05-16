create_project -in_memory -part xc7z020clg400-2
set_property design_mode PinPlanning [current_fileset]
open_io_design
foreach p {L14 L15 K17 M14 M15 N15 N16} {
  set pp [get_package_pins $p]
  puts "$p [get_property BANK $pp] [get_property PIN_FUNC $pp]"
}
close_project
exit
