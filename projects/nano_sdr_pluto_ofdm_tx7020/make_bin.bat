@echo off
rem Byte-swapped bitstream for the Linux FPGA manager (bf_autostart.sh): system_top.bit -> system_top.bit.bin
set D=%~dp0
set BIT=%D%nano_sdr_pluto_ofdm_tx7020.runs\impl_1\system_top.bit
echo all: { %BIT% } > "%D%bit2bin.bif"
call C:\AMDDesignTools\2025.2\Vivado\bin\bootgen.bat -image "%D%bit2bin.bif" -arch zynq -process_bitstream bin -w on
if exist "%BIT%.bin" (copy /y "%BIT%.bin" "%D%system_top.bit.bin" > nul & echo %D%system_top.bit.bin) else (echo bootgen failed & exit /b 1)
