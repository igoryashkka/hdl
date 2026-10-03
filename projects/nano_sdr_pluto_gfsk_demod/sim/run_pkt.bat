@echo off
set V=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
call %V%\xvlog.bat -sv ..\rtl\gfsk_tables_pkg.sv ..\rtl\gfsk_nco_mix.sv ..\rtl\gfsk_cic_dec.sv ..\rtl\gfsk_fir.sv ..\rtl\gfsk_discrim.sv ..\rtl\gfsk_bitsync.sv ..\rtl\gfsk_frame.sv ..\rtl\gfsk_rx_1ch.sv ..\rtl\gfsk_pkt_out.sv tb_pkt_top.sv || exit /b 1
call %V%\xvlog.bat ..\rtl\gfsk_rx_pkt_top.v || exit /b 1
call %V%\xelab.bat -debug off -s tb_pkt tb_pkt_top || exit /b 1
call %V%\xsim.bat tb_pkt -runall
