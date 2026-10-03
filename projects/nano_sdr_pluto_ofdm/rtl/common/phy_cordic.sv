// Module : phy_cordic   iterative CORDIC in VECTORING mode: angle of (x + j*y), 2^32 = 2*pi, unsigned 32-bit result.
//   fold: if x < 0 -> (x,y) = (-x,-y), z = 2^31 ; then NITER iterations (1/clk):
//   y >= 0 ? (x += y>>i, y -= x>>i, z += atan_i) : (x -= y>>i, y += x>>i, z -= atan_i)       (shifts are arithmetic)
// Inputs |x|,|y| < 2^(XW-1) (signed XW bits). Internal width XW+2 (CORDIC gain 1.65 + sign). Angle error < 2^-22 rad.
// Handshake: start pulse while !busy; done pulses 1 cycle when `angle` is valid (angle holds until the next start).
// Latency = NITER + 1 cycles from start to done.  Throughput: 1 result per NITER+1 cycles.  3 adders, no DSP/BRAM.
// Golden: python/sync_ref.py::cordic_vec (bit-exact)
module phy_cordic #(
  parameter int XW    = 18,
  parameter int NITER = 24
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 start,
  input  logic signed [XW-1:0] x,
  input  logic signed [XW-1:0] y,
  output logic                 busy,
  output logic                 done,
  output logic [31:0]          angle
);
  localparam int IW = XW + 2;
  logic [$clog2(NITER+1)-1:0] it;
  logic signed [IW-1:0] xr, yr;
  logic [31:0]          zr;

  logic [31:0] atan_tab [NITER];
  for (genvar i = 0; i < NITER; i++) begin : g_atan
    localparam real AT = $atan(1.0 / (2.0 ** i)) / 6.283185307179586 * 4294967296.0;
    localparam longint AV = $rtoi($floor(AT + 0.5));
    assign atan_tab[i] = 32'(AV);
  end

  wire signed [IW-1:0] ys = yr >>> it;
  wire signed [IW-1:0] xs = xr >>> it;
  assign angle = zr;

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      busy <= 1'b0; it <= '0; xr <= '0; yr <= '0; zr <= '0;
    end else if (!busy) begin
      if (start) begin
        busy <= 1'b1; it <= '0;
        if (x < 0) begin xr <= -IW'(x); yr <= -IW'(y); zr <= 32'h8000_0000; end
        else       begin xr <=  IW'(x); yr <=  IW'(y); zr <= 32'h0; end
      end
    end else begin
      if (!yr[IW-1]) begin xr <= xr + ys; yr <= yr - xs; zr <= zr + atan_tab[it]; end
      else           begin xr <= xr - ys; yr <= yr + xs; zr <= zr - atan_tab[it]; end
      if (it == $bits(it)'(NITER - 1)) begin
        busy <= 1'b0; done <= 1'b1;
      end else it <= it + 1'b1;
    end
  end
endmodule
