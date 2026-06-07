`timescale 1ns / 1ps

module hw69_pn9_whitener #(
    parameter logic [8:0] SEED = 9'h1ff
) (
    input  logic clk,
    input  logic rst,
    input  logic init,
    input  logic bit_valid,
    input  logic bit_in,
    output logic bit_valid_out,
    output logic bit_out
);
    logic [8:0] state;
    logic [8:0] active_state;
    logic feedback;

    always_comb begin
        active_state = init ? SEED : state;
        feedback = active_state[0] ^ active_state[5];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= SEED;
            bit_valid_out <= 1'b0;
            bit_out <= 1'b0;
        end else begin
            bit_valid_out <= bit_valid;

            if (bit_valid) begin
                bit_out <= bit_in ^ active_state[0];
                state <= {feedback, active_state[8:1]};
            end else if (init) begin
                state <= SEED;
            end
        end
    end
endmodule