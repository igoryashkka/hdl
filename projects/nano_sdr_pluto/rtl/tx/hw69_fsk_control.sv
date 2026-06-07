`timescale 1ns / 1ps

module hw69_fsk_control #(
    parameter int unsigned WORD_WIDTH = 32,
    parameter logic signed [WORD_WIDTH-1:0] MARK_WORD = 32'sd1000,
    parameter logic signed [WORD_WIDTH-1:0] SPACE_WORD = -32'sd1000,
    parameter logic signed [WORD_WIDTH-1:0] IDLE_WORD = 32'sd0
) (
    input  logic clk,
    input  logic rst,
    input  logic bit_valid,
    input  logic tx_bit,
    input  logic burst_gate_in,
    output logic freq_valid,
    output logic signed [WORD_WIDTH-1:0] freq_word,
    output logic burst_gate_out
);
    always_ff @(posedge clk) begin
        if (rst) begin
            freq_valid <= 1'b0;
            freq_word <= '0;
            burst_gate_out <= 1'b0;
        end else begin
            freq_valid <= bit_valid;
            burst_gate_out <= bit_valid && burst_gate_in;

            if (bit_valid && burst_gate_in) begin
                freq_word <= tx_bit ? MARK_WORD : SPACE_WORD;
            end else if (bit_valid) begin
                freq_word <= IDLE_WORD;
            end
        end
    end
endmodule