// Module : phy_pilot_insert   replaces pilot slots (in_pilot=1) by +-PILOT_AMP (real) with a PN sign
// (x^15+x^14+1 LFSR, SEED restarted at in_first, advanced per pilot). Other samples pass unchanged.
// Latency 1, throughput 1 sample/valid (valid-gated, gaps allowed).   Golden: python/ofdm_ref.py::insert_pilots
module phy_pilot_insert
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   in_valid,
  input  logic                   in_first,
  input  logic                   in_last,
  input  logic                   in_pilot,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 1;
  logic [14:0] lfsr;
  wire         fb = lfsr[14] ^ lfsr[13];

  always_ff @(posedge clk) begin
    if (rst) begin
      lfsr <= PILOT_SEED; out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0;
      out_re <= '0; out_im <= '0;
    end else begin
      out_valid <= in_valid;
      out_first <= in_valid & in_first;
      out_last  <= in_valid & in_last;
      if (in_valid) begin
        if (in_first) lfsr <= PILOT_SEED;          // bin 0 is never a pilot slot
        if (in_pilot) begin
          out_re <= fb ? -IQ_W'(PILOT_AMP) : IQ_W'(PILOT_AMP);
          out_im <= '0;
          lfsr   <= {lfsr[13:0], fb};
        end else begin
          out_re <= in_re;
          out_im <= in_im;
        end
      end
    end
  end
endmodule
