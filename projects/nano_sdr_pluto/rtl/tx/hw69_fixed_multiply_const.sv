`timescale 1ns / 1ps

module hw69_fixed_multiply_const #(
    parameter int unsigned DATA_WIDTH = 18,
    parameter int unsigned CONST_WIDTH = 20,
    parameter int unsigned CONST_FRAC_BITS = 16,
    parameter logic signed [CONST_WIDTH-1:0] CONST_Q = 20'sd131072
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [DATA_WIDTH-1:0] data_in,
    output logic out_valid,
    output logic signed [DATA_WIDTH-1:0] data_out
);
    localparam int unsigned PRODUCT_WIDTH = DATA_WIDTH + CONST_WIDTH;

    function automatic logic signed [DATA_WIDTH-1:0] saturate(input logic signed [PRODUCT_WIDTH-1:0] value);
        logic signed [DATA_WIDTH-1:0] max_value;
        logic signed [DATA_WIDTH-1:0] min_value;
        begin
            max_value = {1'b0, {(DATA_WIDTH - 1){1'b1}}};
            min_value = {1'b1, {(DATA_WIDTH - 1){1'b0}}};

            if (value > {{PRODUCT_WIDTH-DATA_WIDTH{max_value[DATA_WIDTH-1]}}, max_value}) begin
                return max_value;
            end
            if (value < {{PRODUCT_WIDTH-DATA_WIDTH{min_value[DATA_WIDTH-1]}}, min_value}) begin
                return min_value;
            end
            return value[DATA_WIDTH-1:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        logic signed [PRODUCT_WIDTH-1:0] product;
        logic signed [PRODUCT_WIDTH-1:0] shifted;

        if (rst) begin
            out_valid <= 1'b0;
            data_out <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                product = data_in * CONST_Q;
                shifted = product >>> CONST_FRAC_BITS;
                data_out <= saturate(shifted);
            end
        end
    end
endmodule