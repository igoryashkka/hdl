@echo off
rem Single-channel GFSK RX testbench (samples -> decoded bytes). Edit cfg.txt to pick a packet.
set V=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
call %V%\xvlog.bat -sv ..\rtl\gfsk_tables_pkg.sv ..\rtl\gfsk_nco_mix.sv ..\rtl\gfsk_cic_dec.sv ..\rtl\gfsk_fir.sv ..\rtl\gfsk_discrim.sv ..\rtl\gfsk_bitsync.sv ..\rtl\gfsk_frame.sv ..\rtl\gfsk_rx_1ch.sv tb_gfsk_rx_1ch.sv || exit /b 1
call %V%\xelab.bat -debug off -s tb_sim tb_gfsk_rx_1ch || exit /b 1
call %V%\xsim.bat tb_sim -runall
