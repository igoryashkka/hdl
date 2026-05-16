create_project -in_memory -part xc7z020clg400-2
set_property design_mode PinPlanning [current_fileset]
open_io_design
puts "---PKG PIN U18---"
report_property [get_package_pins U18]
puts "---SITE OF U18---"
report_property [get_sites -of_objects [get_package_pins U18]]
close_project
exit
