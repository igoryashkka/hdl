`timescale 1ns / 1ps

module hw69_zoh_resampler #(
    parameter int unsigned DATA_WIDTH = 18,
    parameter int unsigned INTERP = 100
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [DATA_WIDTH-1:0] data_in,
    output logic out_valid,
    output logic signed [DATA_WIDTH-1:0] data_out
);
    logic signed [DATA_WIDTH-1:0] held_sample;
    logic [$clog2(INTERP + 1)-1:0] remaining;

    always_ff @(posedge clk) begin
        if (rst) begin
            held_sample <= '0;
            remaining <= '0;
            out_valid <= 1'b0;
            data_out <= '0;
        end else begin
            if (in_valid) begin
                held_sample <= data_in;
                data_out <= data_in;
                out_valid <= 1'b1;
                remaining <= INTERP - 1'b1;
            end else if (remaining != '0) begin
                data_out <= held_sample;
                out_valid <= 1'b1;
                remaining <= remaining - 1'b1;
            end else begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule