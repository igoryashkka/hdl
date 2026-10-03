// Module : phy_cfo_coarse   fractional CFO -> NCO phase increment.
//   P (40-bit complex from phy_sync_sc) is normalised by an arithmetic right shift so max(|re|,|im|) < 2^(XW-1), the angle is
//   taken with phy_cordic and inc = -(angle >>> LOG2L) (two's complement, 2^32 = 2*pi per sample): the NCO then cancels
//   exp(j*angle(P)*n/L), i.e. a CFO of angle(P)/pi subcarrier spacings (+-1 spacing = +-15 kHz).
//   Requires |P| >= 2^(XW-2) (guaranteed by the detector energy gate rmin >= 2^18).
// Handshake: start pulse (p_re/p_im sampled on start) -> done pulse with `inc`; Latency = 2 + NITER + 1 cycles.
// Golden: python/sync_ref.py::cfo_inc (bit-exact)
module phy_cfo_coarse #(
  parameter int XW    = 18,
  parameter int NITER = 24,
  parameter int LOG2L = 10
) (
  input  logic               clk,
  input  logic               rst,
  input  logic               start,
  input  logic signed [39:0] p_re,
  input  logic signed [39:0] p_im,
  output logic               busy,
  output logic               done,
  output logic [31:0]        inc
);
  // magnitude-based normalisation shift (priority encode the OR of |re| and |im|)
  wire [39:0] a_re = p_re[39] ? 40'(-p_re) : 40'(p_re);
  wire [39:0] a_im = p_im[39] ? 40'(-p_im) : 40'(p_im);
  wire [39:0] mmax = a_re | a_im;           // same bit length as max(|re|,|im|)
  logic [5:0] sh;
  always_comb begin
    sh = '0;
    for (int b = 0; b < 40; b++) if (mmax[b]) sh = (b + 1 > XW - 1) ? 6'(b + 1 - (XW - 1)) : 6'd0;
  end

  logic signed [XW-1:0] cx, cy;
  logic                 cstart, cbusy, cdone;
  logic [31:0]          cang;
  logic                 pend;

  phy_cordic #(.XW(XW), .NITER(NITER)) u_cordic (
    .clk, .rst, .start(cstart), .x(cx), .y(cy), .busy(cbusy), .done(cdone), .angle(cang)
  );

  assign busy = pend | cbusy;

  always_ff @(posedge clk) begin
    cstart <= 1'b0;
    done   <= 1'b0;
    if (rst) begin
      pend <= 1'b0; inc <= '0; cx <= '0; cy <= '0;
    end else begin
      if (start && !busy) begin
        cx <= XW'(p_re >>> sh);
        cy <= XW'(p_im >>> sh);
        cstart <= 1'b1; pend <= 1'b1;
      end
      if (cstart) pend <= 1'b0;
      if (cdone) begin
        inc  <= 32'(-($signed(cang) >>> LOG2L));
        done <= 1'b1;
      end
    end
  end
endmodule
