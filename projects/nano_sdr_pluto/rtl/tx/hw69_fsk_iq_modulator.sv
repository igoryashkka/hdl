`timescale 1ns / 1ps

module hw69_fsk_iq_modulator #(
    parameter int unsigned CONTROL_WIDTH = 18,
    parameter int unsigned CONTROL_FRAC_BITS = 16,
    parameter int unsigned PHASE_WIDTH = 32,
    parameter int unsigned IQ_WIDTH = 16,
    parameter logic signed [PHASE_WIDTH-1:0] CARRIER_PHASE_WORD = '0,
    parameter logic signed [PHASE_WIDTH-1:0] DEVIATION_PHASE_WORD = 32'sd78293675
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [CONTROL_WIDTH-1:0] freq_control,
    output logic phase_valid,
    output logic [PHASE_WIDTH-1:0] phase_word,
    output logic out_valid,
    output logic signed [IQ_WIDTH-1:0] i_out,
    output logic signed [IQ_WIDTH-1:0] q_out
);
    logic dds_in_valid;
    logic [PHASE_WIDTH-1:0] dds_phase_word;

    hw69_frequency_modulator #(
        .CONTROL_WIDTH(CONTROL_WIDTH),
        .CONTROL_FRAC_BITS(CONTROL_FRAC_BITS),
        .PHASE_WIDTH(PHASE_WIDTH),
        .CARRIER_PHASE_WORD(CARRIER_PHASE_WORD),
        .DEVIATION_PHASE_WORD(DEVIATION_PHASE_WORD)
    ) frequency_modulator (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .freq_control(freq_control),
        .phase_valid(dds_in_valid),
        .phase_word(dds_phase_word)
    );

    hw69_sin_cos_lut #(
        .PHASE_WIDTH(PHASE_WIDTH),
        .OUTPUT_WIDTH(IQ_WIDTH)
    ) phase_to_iq (
        .clk(clk),
        .rst(rst),
        .in_valid(dds_in_valid),
        .phase_word(dds_phase_word),
        .out_valid(out_valid),
        .i_out(i_out),
        .q_out(q_out)
    );

    assign phase_valid = dds_in_valid;
    assign phase_word = dds_phase_word;
endmodule