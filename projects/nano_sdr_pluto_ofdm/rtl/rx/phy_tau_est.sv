// Module : phy_tau_est   fine timing from the LTS: P = sum conj(G_s) G_{s+1} over adjacent bins (accumulated in phy_channel_estimator),
//   arg(P) = -2*pi*tau/N  (tau = delay of the window w.r.t. the symbol, i.e. how early the FFT window starts) ->
//   tau_q8 = -arg(P) * N / 2pi in 1/256 sample.  P (44 bit) is normalised to 17 bit, the angle comes from phy_cordic.
//   `start` pulses once per LTS frame; `tau_valid` ~ 40 cycles later.  Golden: python/phy2_fixed_ref.py::timing_est (bit-exact)
module phy_tau_est (
  input  logic              clk,
  input  logic              rst,
  input  logic              start,
  input  logic signed [43:0] p_re,
  input  logic signed [43:0] p_im,
  output logic              tau_valid,
  output logic signed [19:0] tau_q8
);
  localparam int XW = 18;
  logic signed [43:0] ar, ai;
  logic [43:0] mm;
  logic [5:0]  shn, shn_q;
  logic        v1, v2, v3;
  logic signed [XW-1:0] cx, cy;
  logic        cstart, cdone;
  logic [31:0] cang;
  // S0: capture + abs-or
  always_ff @(posedge clk) begin
    v1 <= start & ~rst;
    if (start) begin ar <= p_re; ai <= p_im; end
  end
  wire [43:0] a_r = ar[43] ? 44'(-ar) : 44'(ar);
  wire [43:0] a_i = ai[43] ? 44'(-ai) : 44'(ai);
  always_comb begin
    mm = a_r | a_i;
    shn = '0;
    for (int b = 0; b < 44; b++) if (mm[b]) shn = (b + 1 > XW - 1) ? 6'(b + 1 - (XW - 1)) : 6'd0;
  end
  // S1: shift amount registered ; S2: normalised operands + CORDIC start
  always_ff @(posedge clk) begin
    v2 <= v1 & ~rst; shn_q <= shn;
  end
  always_ff @(posedge clk) begin
    cstart <= 1'b0; v3 <= 1'b0;
    if (v2) begin cx <= XW'(ar >>> shn_q); cy <= XW'(ai >>> shn_q); v3 <= 1'b1; end
    if (v3) cstart <= 1'b1;
  end
  phy_cordic #(.XW(XW), .NITER(24)) u_cordic (.clk, .rst, .start(cstart), .x(cx), .y(cy), .busy(), .done(cdone), .angle(cang));
  always_ff @(posedge clk) begin
    if (rst) tau_valid <= 1'b0;
    else begin
      tau_valid <= cdone;
      if (cdone) tau_q8 <= 20'(-($signed(cang)) >>> 13);
    end
  end
endmodule
