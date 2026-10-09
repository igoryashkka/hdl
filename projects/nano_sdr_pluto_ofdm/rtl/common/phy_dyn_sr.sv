// Module : phy_dyn_sr   shift register with a selectable read tap (dynamic SRL): one SRLC32E per bit, no flip-flops, no read multiplexer.
//   en: shift (d enters at position 0);  q = the word that entered tap + 1 shifts ago (tap = 0 .. DEPTH-1, static while in use).
//   Used for the LDPC layer ring: the record of a layer is needed again LMB layers later (6 or 18, selected by the code).
//   No reset (the contents are ignored until they have been written). Coding style: UG901 "dynamic shift register".
module phy_dyn_sr #(
  parameter int W     = 8,
  parameter int DEPTH = 18
) (
  input  logic                     clk,
  input  logic                     en,
  input  logic [W-1:0]             d,
  input  logic [$clog2(DEPTH)-1:0] tap,
  output logic [W-1:0]             q
);
  for (genvar b = 0; b < W; b++) begin : g_bit
    (* shreg_extract = "yes" *) logic [DEPTH-1:0] sr;
    always_ff @(posedge clk) if (en) sr <= {sr[DEPTH-2:0], d[b]};
    assign q[b] = sr[tap];
  end
endmodule
