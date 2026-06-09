`timescale 1ns / 1ps

module hw69_tx_shaping_lpf #(
    parameter int unsigned DATA_WIDTH = 18,
    parameter int unsigned COEFF_WIDTH = 20,
    parameter int unsigned COEFF_FRAC_BITS = 18,
    parameter int unsigned NUM_TAPS = 129
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [DATA_WIDTH-1:0] data_in,
    output logic out_valid,
    output logic signed [DATA_WIDTH-1:0] data_out
);
    localparam int unsigned AVG_SHIFT = 2;
    localparam int unsigned ACC_WIDTH = DATA_WIDTH + AVG_SHIFT;

    logic signed [DATA_WIDTH-1:0] sample_d1;
    logic signed [DATA_WIDTH-1:0] sample_d2;
    logic signed [DATA_WIDTH-1:0] sample_d3;

    always_ff @(posedge clk) begin
        logic signed [ACC_WIDTH-1:0] sum;

        if (rst) begin
            out_valid <= 1'b0;
            data_out <= '0;
            sample_d1 <= '0;
            sample_d2 <= '0;
            sample_d3 <= '0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                sum = {{AVG_SHIFT{data_in[DATA_WIDTH-1]}}, data_in}
                    + {{AVG_SHIFT{sample_d1[DATA_WIDTH-1]}}, sample_d1}
                    + {{AVG_SHIFT{sample_d2[DATA_WIDTH-1]}}, sample_d2}
                    + {{AVG_SHIFT{sample_d3[DATA_WIDTH-1]}}, sample_d3};

                data_out <= sum >>> AVG_SHIFT;
                sample_d3 <= sample_d2;
                sample_d2 <= sample_d1;
                sample_d1 <= data_in;
            end
        end
    end
endmodule