`timescale 1ns / 1ps

module hw69_fixed_add_const #(
    parameter int unsigned DATA_WIDTH = 18,
    parameter logic signed [DATA_WIDTH-1:0] CONST_Q = -18'sd32768
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [DATA_WIDTH-1:0] data_in,
    output logic out_valid,
    output logic signed [DATA_WIDTH-1:0] data_out
);
    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            data_out <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                data_out <= data_in + CONST_Q;
            end
        end
    end
endmodule