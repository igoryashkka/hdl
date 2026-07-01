open_project [file normalize "nano_sdr_pluto.xpr"]

reset_run system_ila_0_1_synth_1
launch_runs system_ila_0_1_synth_1 -jobs 4
wait_on_run system_ila_0_1_synth_1

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

reset_run impl_1
launch_runs impl_1 -to_step opt_design -jobs 4
wait_on_run impl_1

puts "ILA_STATUS=[get_property STATUS [get_runs system_ila_0_1_synth_1]]"
puts "SYNTH_STATUS=[get_property STATUS [get_runs synth_1]]"
puts "IMPL_STATUS=[get_property STATUS [get_runs impl_1]]"

close_project
