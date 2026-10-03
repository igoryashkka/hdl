// Module : phy_cfo_coarse   fractional CFO -> NCO phase increment.
//   P (40-bit complex from phy_sync_sc) is normalised by an arithmetic right shift so max(|re|,|im|) < 2^(XW-1), the angle is
//   taken with phy_cordic and inc = -(angle >>> LOG2L) (two's complement, 2^32 = 2*pi per sample): the NCO then cancels
//   exp(j*angle(P)*n/L), i.e. a CFO of angle(P)/pi subcarrier spacings (+-1 spacing = +-15 kHz).
//   Requires |P| >= 2^(XW-2) (guaranteed by the detector energy gate rmin >= 2^18).
// Handshake: start pulse (p_re/p_im sampled on start) -> done pulse with `inc`; Latency = 4 + NITER + 1 cycles.
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
  // normalisation pipeline: latch -> |re|,|im| OR -> priority encode -> shift -> CORDIC start (registered at every step)
  logic signed [39:0] lp_re, lp_im;
  logic [39:0] mmax;
  logic [5:0]  sh;
  logic [3:0]  nst;           // 0 idle, 1 abs/or, 2 priority, 3 shift+start
  logic signed [XW-1:0] cx, cy;
  logic                 cstart, cbusy, cdone;
  logic [31:0]          cang;
  logic                 pend;

  phy_cordic #(.XW(XW), .NITER(NITER)) u_cordic (
    .clk, .rst, .start(cstart), .x(cx), .y(cy), .busy(cbusy), .done(cdone), .angle(cang)
  );

  assign busy = pend | cbusy;

  logic [5:0] sh_c;
  always_comb begin
    sh_c = '0;
    for (int b = 0; b < 40; b++) if (mmax[b]) sh_c = (b + 1 > XW - 1) ? 6'(b + 1 - (XW - 1)) : 6'd0;
  end

  always_ff @(posedge clk) begin
    cstart <= 1'b0;
    done   <= 1'b0;
    if (rst) begin
      pend <= 1'b0; inc <= '0; cx <= '0; cy <= '0; nst <= '0; mmax <= '0; sh <= '0; lp_re <= '0; lp_im <= '0;
    end else begin
      if (start && !busy) begin lp_re <= p_re; lp_im <= p_im; pend <= 1'b1; nst <= 4'd1; end
      case (nst)
        4'd1: begin
          mmax <= (lp_re[39] ? 40'(-lp_re) : 40'(lp_re)) | (lp_im[39] ? 40'(-lp_im) : 40'(lp_im));
          nst <= 4'd2;
        end
        4'd2: begin sh <= sh_c; nst <= 4'd3; end
        4'd3: begin
          cx <= XW'(lp_re >>> sh); cy <= XW'(lp_im >>> sh); cstart <= 1'b1; nst <= 4'd0; pend <= 1'b0;
        end
        default: ;
      endcase
      if (cdone) begin
        inc  <= 32'(-($signed(cang) >>> LOG2L));
        done <= 1'b1;
      end
    end
  end
endmodule
