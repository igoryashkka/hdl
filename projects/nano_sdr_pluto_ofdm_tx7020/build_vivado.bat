@echo off
rem Full build of the OFDM PHY TX for the Zynq-7020 LVDS Pluto board (BD, synthesis, implementation, bitstream).
set ADI_IGNORE_VERSION_CHECK=1
set V=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
call %V%\vivado.bat -mode batch -log build.log -journal build.jou -source system_project.tcl
echo BUILD_EXIT %ERRORLEVEL%
