create_project -in_memory -part xc7z020clg400-2
set_property design_mode PinPlanning [current_fileset]
open_io_design
set pins {U18 U19 U14 U15 Y16 Y17 V16 W16 Y18 Y19 T16 U17 V20 W20 T17 R18 T20 U20 W18 W19 V15 W15 V12 W13 W14 Y14 T12 U12 T11 T10 U13 V13 R17 V18 P16 V17 T15 P18 P20 R19 T19 R16 P14}
puts "PIN BANK SITE"
foreach p $pins {
  set pp [get_package_pins $p]
  if {[llength $pp] == 0} {
    puts "$p MISSING"
  } else {
    set site [get_sites -of_objects $pp]
    set bank [get_property IOBANK $site]
    set sitetype [get_property SITE_TYPE $site]
    puts "$p $bank $sitetype"
  }
}
close_project
exit
