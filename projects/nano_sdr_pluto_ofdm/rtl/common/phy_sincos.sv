// Module : phy_sincos   cos/sin lookup for a 12-bit phase index (2*pi = 4096), Q1.15 outputs in -32767..32767.
//   Quarter-wave table of 1024 entries, midpoint sampled: T[a] = round(32767*cos(2*pi*(a+0.5)/4096)).
//   quad 0: c=T[a],  s=T[1023-a] ; quad 1: c=-T[1023-a], s=T[a] ; quad 2: c=-T[a], s=-T[1023-a] ; quad 3: c=T[1023-a], s=-T[a]
// Latency = 2 cycles (table read, quadrant mapping), free-running pipeline (valid delayed alongside).
// Golden: python/rx_blocks_ref.py::nco_cs (bit-exact), verified through tb_phy_nco_mixer and tb_phy_phase_tracker.
module phy_sincos (
  input  logic               clk,
  input  logic               rst,
  input  logic               in_valid,
  input  logic [11:0]        idx,
  output logic               out_valid,
  output logic signed [15:0] cos_o,
  output logic signed [15:0] sin_o
);
  localparam int AW = 10;
  logic signed [15:0] tab [1 << AW];
  for (genvar i = 0; i < (1 << AW); i++) begin : g_tab
    localparam real TH = 6.283185307179586 * (i + 0.5) / 4096.0;
    localparam int  CV = $rtoi($floor($cos(TH) * 32767.0 + 0.5));
    assign tab[i] = 16'(CV);
  end

  logic signed [15:0] t1, tr1;
  logic [1:0]         quad1;
  logic               v1;
  wire  [AW-1:0]      a0 = idx[AW-1:0];
  always_ff @(posedge clk) begin
    t1    <= tab[a0];
    tr1   <= tab[AW'((1 << AW) - 1) - a0];
    quad1 <= idx[11:10];
    if (rst) v1 <= 1'b0; else v1 <= in_valid;
  end
  always_ff @(posedge clk) begin
    case (quad1)
      2'd0: begin cos_o <= t1;   sin_o <= tr1;  end
      2'd1: begin cos_o <= -tr1; sin_o <= t1;   end
      2'd2: begin cos_o <= -t1;  sin_o <= -tr1; end
      default: begin cos_o <= tr1; sin_o <= -t1; end
    endcase
    if (rst) out_valid <= 1'b0; else out_valid <= v1;
  end
endmodule
