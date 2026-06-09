`timescale 1ns / 1ps

module hw69_sin_cos_lut #(
    parameter int unsigned PHASE_WIDTH = 32,
    parameter int unsigned OUTPUT_WIDTH = 16,
    parameter int unsigned LUT_ADDR_WIDTH = 12
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic [PHASE_WIDTH-1:0] phase_word,
    output logic out_valid,
    output logic signed [OUTPUT_WIDTH-1:0] i_out,
    output logic signed [OUTPUT_WIDTH-1:0] q_out
);
    localparam logic signed [OUTPUT_WIDTH-1:0] FULL_SCALE = {1'b0, {(OUTPUT_WIDTH - 1){1'b1}}};
    localparam logic signed [OUTPUT_WIDTH-1:0] DIAG_SCALE = FULL_SCALE >>> 1;

    logic [2:0] octant_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            octant_reg <= '0;
            out_valid <= 1'b0;
            i_out <= '0;
            q_out <= '0;
        end else begin
            out_valid <= in_valid;

            if (in_valid) begin
                octant_reg <= phase_word[PHASE_WIDTH-1 -: 3];
            end

            if (out_valid) begin
                case (octant_reg)
                    3'd0: begin
                        i_out <= FULL_SCALE;
                        q_out <= '0;
                    end
                    3'd1: begin
                        i_out <= DIAG_SCALE;
                        q_out <= FULL_SCALE;
                    end
                    3'd2: begin
                        i_out <= '0;
                        q_out <= FULL_SCALE;
                    end
                    3'd3: begin
                        i_out <= -DIAG_SCALE;
                        q_out <= FULL_SCALE;
                    end
                    3'd4: begin
                        i_out <= -FULL_SCALE;
                        q_out <= '0;
                    end
                    3'd5: begin
                        i_out <= -DIAG_SCALE;
                        q_out <= -FULL_SCALE;
                    end
                    3'd6: begin
                        i_out <= '0;
                        q_out <= -FULL_SCALE;
                    end
                    default: begin
                        i_out <= DIAG_SCALE;
                        q_out <= -FULL_SCALE;
                    end
                endcase
            end
        end
    end
endmodule