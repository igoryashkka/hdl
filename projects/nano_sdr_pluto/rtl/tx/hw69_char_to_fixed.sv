`timescale 1ns / 1ps

module hw69_char_to_fixed #(
    parameter int unsigned OUT_WIDTH = 18,
    parameter int unsigned FRAC_BITS = 16
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic [7:0] char_in,
    output logic out_valid,
    output logic signed [OUT_WIDTH-1:0] fixed_out
);
    localparam logic signed [OUT_WIDTH-1:0] ONE_Q = 1 <<< FRAC_BITS;

    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            fixed_out <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                fixed_out <= char_in[0] ? ONE_Q : '0;
            end
        end
    end
endmodule