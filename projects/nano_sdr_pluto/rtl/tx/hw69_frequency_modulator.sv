`timescale 1ns / 1ps

module hw69_frequency_modulator #(
    parameter int unsigned CONTROL_WIDTH = 18,
    parameter int unsigned CONTROL_FRAC_BITS = 16,
    parameter int unsigned PHASE_WIDTH = 32,
    parameter logic signed [PHASE_WIDTH-1:0] CARRIER_PHASE_WORD = '0,
    parameter logic signed [PHASE_WIDTH-1:0] DEVIATION_PHASE_WORD = 32'sd78293675
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [CONTROL_WIDTH-1:0] freq_control,
    output logic phase_valid,
    output logic [PHASE_WIDTH-1:0] phase_word
);
    localparam int unsigned PRODUCT_WIDTH = CONTROL_WIDTH + PHASE_WIDTH;

    logic [PHASE_WIDTH-1:0] phase_acc;

    always_ff @(posedge clk) begin
        logic signed [PRODUCT_WIDTH-1:0] product;
        logic signed [PRODUCT_WIDTH-1:0] phase_step_ext;
        logic signed [PHASE_WIDTH-1:0] deviation_phase_step;
        logic signed [PHASE_WIDTH-1:0] phase_step;

        if (rst) begin
            phase_acc <= '0;
            phase_valid <= 1'b0;
            phase_word <= '0;
        end else begin
            phase_valid <= in_valid;

            if (in_valid) begin
                product = freq_control * DEVIATION_PHASE_WORD;
                phase_step_ext = product >>> CONTROL_FRAC_BITS;
                deviation_phase_step = phase_step_ext[PHASE_WIDTH-1:0];
                phase_step = CARRIER_PHASE_WORD + deviation_phase_step;
                phase_acc <= phase_acc + phase_step;
                phase_word <= phase_acc + phase_step;
            end
        end
    end
endmodule