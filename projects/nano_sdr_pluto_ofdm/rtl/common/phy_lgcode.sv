// Module : phy_lgcode   log2 code of an unsigned integer: code = floor(log2 x)*LGF + LGT[next LGMB fraction bits]  (LGF = 32 steps per
//   octave), x == 0 -> -1000.  Latency 3.   Golden: python/phy2_fixed_ref.py::lgcode (bit-exact)
module phy_lgcode
  import phy_soft_pkg::*;
#(
  parameter int W = 42
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                in_valid,
  input  logic [W-1:0]        in_x,
  output logic                out_valid,
  output logic signed [12:0]  out_code
);
  logic [5:0]   p1; logic z1, v1; logic [W-1:0] x1;
  always_ff @(posedge clk) begin
    p1 <= '0;
    for (int b = 0; b < W; b++) if (in_x[b]) p1 <= 6'(b);
    z1 <= (in_x == '0); x1 <= in_x; v1 <= in_valid & ~rst;
  end
  logic [4:0] fr2; logic [5:0] p2; logic z2, v2;
  always_ff @(posedge clk) begin
    fr2 <= 5'((W+LGMB)'(x1) << LGMB >> p1);
    p2 <= p1; z2 <= z1; v2 <= v1;
  end
  always_ff @(posedge clk) begin
    out_valid <= v2 & ~rst;
    out_code  <= z2 ? -13'sd1000 : 13'(int'(p2) * LGF + int'(LGT_ROM[fr2]));
  end
endmodule
