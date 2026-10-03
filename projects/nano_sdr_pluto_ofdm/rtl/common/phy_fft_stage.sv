// Module : phy_fft_stage   one radix-2 DIF single-path-delay-feedback stage (block size 2D, D = 2^LOGD).
// State advances only on in_valid (gaps allowed). Output stream lags the input by D samples
// (the first D inputs of a stream produce no output); frame f outputs appear while frame f+1 is fed.
//   phase0 (first D of 2D): out = stored diff of previous block, store input
//   phase1 (last  D of 2D): out = scale(a+b); store scale(a-b)  with a = stored input, b = current input
// Diff outputs are multiplied by W_{2D}^n (D>=4: complex multiplier + Q1.15 ROM; D==2: exact *(-j) on n=1;
// D==1: none).  Sum outputs bypass the multiplier through a matching delay.
// Latency (cycles, additional to the D-sample structural delay): 1 + (D>=4 ? 5 : 1).
// Delay memory: D>=4 -> RAM, read-first with 1-sample prefetch (BRAM/dist. RAM); D<4 -> shift regs.
// Widths: data W signed; twiddle TWW signed Q1.15; SHIFT=1 -> round-half-up >>1 after add/sub, else saturate.
// Golden: python/fft_ref.py (bit-exact).
module phy_fft_stage #(
  parameter int LOGD  = 10,
  parameter int W     = 18,
  parameter int TWW   = 16,
  parameter bit SHIFT = 1'b0
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                in_valid,
  input  logic signed [W-1:0] in_re,
  input  logic signed [W-1:0] in_im,
  output logic                out_valid,
  output logic signed [W-1:0] out_re,
  output logic signed [W-1:0] out_im
);
  localparam int D       = 1 << LOGD;
  localparam int MULT_LAT = (D >= 4) ? 5 : 1;   // D>=4: ROM/data reg (1) + phy_complex_mult (4); D<4: output reg
  localparam int PW       = (LOGD > 0) ? LOGD : 1;
  localparam int LATENCY  = 1 + MULT_LAT;

  // ---------------------------------------------------------------- control
  logic [LOGD:0] cnt;           // position inside the 2D block, advances on in_valid
  logic          primed;
  wire           phase1 = cnt[LOGD];
  wire [PW-1:0]   ptr   = (LOGD > 0) ? cnt[(LOGD > 0) ? LOGD - 1 : 0 : 0] : '0;

  // ---------------------------------------------------------------- delay memory
  logic signed [W-1:0] sr_re, sr_im;     // stored value for the current step
  logic signed [W-1:0] st_re, st_im;     // value to store

  localparam int WW = 2 * W;
  generate
    if (D >= 4) begin : g_ram
      logic [WW-1:0] ram [D] = '{default: '0};
      wire [PW-1:0] ptr_n = (ptr == PW'(D - 1)) ? '0 : ptr + 1'b1;
      logic [WW-1:0] rd_q = '0;
      assign {sr_re, sr_im} = rd_q;
      always_ff @(posedge clk) begin
        if (in_valid) begin
          ram[ptr] <= {st_re, st_im};
          rd_q     <= ram[ptr_n];
        end
      end
    end else begin : g_sr
      logic signed [W-1:0] shr_re [D] = '{default: '0};
      logic signed [W-1:0] shr_im [D] = '{default: '0};
      assign sr_re = shr_re[D-1];
      assign sr_im = shr_im[D-1];
      always_ff @(posedge clk) begin
        if (in_valid) begin
          shr_re[0] <= st_re; shr_im[0] <= st_im;
          for (int i = 1; i < D; i++) begin shr_re[i] <= shr_re[i-1]; shr_im[i] <= shr_im[i-1]; end
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------- butterfly (combinational + 1 output reg)
  logic signed [W:0]   sum_re, sum_im, dif_re, dif_im;
  logic signed [W-1:0] s_re, s_im, d_re, d_im;

  function automatic logic signed [W-1:0] scl(input logic signed [W:0] v);
    logic signed [W+1:0] t;
    logic signed [W:0]   hi, lo;
    if (SHIFT) begin
      t   = (W+2)'(v) + 1;
      return t[W:1];
    end else begin
      hi = (W+1)'((1 << (W - 1)) - 1);
      lo = -(W+1)'(1 << (W - 1));
      return (v > hi) ? hi[W-1:0] : (v < lo) ? lo[W-1:0] : v[W-1:0];
    end
  endfunction

  always_comb begin
    sum_re = (W+1)'(sr_re) + (W+1)'(in_re);
    sum_im = (W+1)'(sr_im) + (W+1)'(in_im);
    dif_re = (W+1)'(sr_re) - (W+1)'(in_re);
    dif_im = (W+1)'(sr_im) - (W+1)'(in_im);
    s_re = scl(sum_re); s_im = scl(sum_im);
    d_re = scl(dif_re); d_im = scl(dif_im);
    if (phase1) begin st_re = d_re;  st_im = d_im;  end
    else        begin st_re = in_re; st_im = in_im; end
  end

  logic                bf_valid, bf_diff;
  logic [PW-1:0]       bf_n;
  logic signed [W-1:0] bf_re, bf_im;

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= '0; primed <= 1'b0; bf_valid <= 1'b0;
    end else begin
      bf_valid <= in_valid & (phase1 | primed);
      if (in_valid) begin
        cnt <= (cnt == (LOGD+1)'(2 * D - 1)) ? '0 : cnt + 1'b1;
        if (phase1) primed <= 1'b1;
      end
    end
    if (in_valid) begin
      bf_diff <= ~phase1;
      bf_n    <= ptr;
      bf_re   <= phase1 ? s_re : sr_re;
      bf_im   <= phase1 ? s_im : sr_im;
    end
  end

  // ---------------------------------------------------------------- twiddle multiply
  generate
    if (D >= 4) begin : g_mult
      logic signed [TWW-1:0] rom_re [D];
      logic signed [TWW-1:0] rom_im [D];
      for (genvar i = 0; i < D; i++) begin : g_rom
        localparam real TH = 6.283185307179586 * i / (2.0 * D);
        localparam int  CR = $rtoi($floor($cos(TH) * 32768.0 + 0.5));
        localparam int  SI = $rtoi($floor(-$sin(TH) * 32768.0 + 0.5));
        assign rom_re[i] = TWW'((CR > 32767) ? 32767 : CR);
        assign rom_im[i] = TWW'((SI > 32767) ? 32767 : (SI < -32768) ? -32768 : SI);
      end
      logic                  mo_valid;
      logic signed [W-1:0]   mo_re, mo_im;

      // ROM lookup: registered together with the data (so the multiplier sees them aligned)
      logic signed [TWW-1:0] rom_q_re, rom_q_im;
      logic signed [W-1:0]   bf_re_q, bf_im_q;
      logic                  bf_valid_q, bf_diff_q;
      always_ff @(posedge clk) begin
        rom_q_re <= rom_re[bf_n]; rom_q_im <= rom_im[bf_n];
        bf_re_q <= bf_re; bf_im_q <= bf_im;
      end
      always_ff @(posedge clk) begin
        if (rst) begin bf_valid_q <= 1'b0; end
        else     bf_valid_q <= bf_valid;
        bf_diff_q <= bf_diff;
      end
      // NOTE: ROM+data registers above add one cycle; the multiplier has 4 cycles.
      phy_complex_mult #(.AW(W), .BW(TWW)) u_mult (
        .clk, .rst, .in_valid(bf_valid_q & bf_diff_q),
        .a(bf_re_q), .b(bf_im_q), .c(rom_q_re), .d(rom_q_im),
        .out_valid(mo_valid), .out_i(mo_re), .out_q(mo_im)
      );
      // bypass pipeline (valid/data of sum outputs) with the same total latency as the multiplier path
      localparam int BL = 4;
      logic             bp_v   [BL];
      logic signed [W-1:0] bp_r [BL];
      logic signed [W-1:0] bp_i [BL];
      always_ff @(posedge clk) begin
        bp_r[0] <= bf_re_q; bp_i[0] <= bf_im_q;
        bp_v[0] <= bf_valid_q & ~bf_diff_q;
        for (int k = 1; k < BL; k++) begin bp_r[k] <= bp_r[k-1]; bp_i[k] <= bp_i[k-1]; bp_v[k] <= bp_v[k-1]; end
        if (rst) for (int k = 0; k < BL; k++) bp_v[k] <= 1'b0;
      end
      // multiplier output appears 4 cycles after its input; bypass has 4 regs -> aligned
      always_comb begin
        out_valid = mo_valid | bp_v[BL-1];
        out_re    = mo_valid ? mo_re : bp_r[BL-1];
        out_im    = mo_valid ? mo_im : bp_i[BL-1];
      end
    end else begin : g_triv
      // D==2: element n=1 of the diff stream is multiplied by -j (exact); D==1: pass through. Output registered.
      localparam logic signed [W-1:0] MAXP = (W'(1) <<< (W - 1)) - 1;
      localparam logic signed [W-1:0] MINN = -(W'(1) <<< (W - 1));
      always_ff @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else     out_valid <= bf_valid;
        if (D == 2 && bf_diff && bf_n[0]) begin
          out_re <= bf_im;
          out_im <= (bf_re == MINN) ? MAXP : -bf_re;
        end else begin
          out_re <= bf_re;
          out_im <= bf_im;
        end
      end
    end
  endgenerate
endmodule
