@echo off
rem Full build of the rx-only OFDM PHY project (BD, synthesis, implementation, reports).
set ADI_IGNORE_VERSION_CHECK=1
set V=C:\AMDDesignTools\2025.2\Vivado\bin
cd /d %~dp0
call %V%\vivado.bat -mode batch -log build.log -journal build.jou -source system_project.tcl
echo BUILD_EXIT %ERRORLEVEL%
