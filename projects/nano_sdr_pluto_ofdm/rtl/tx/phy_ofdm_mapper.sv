// Module : phy_ofdm_mapper   builds one frequency-domain OFDM symbol (FFT_SIZE bins, natural order 0..N-1).
// Active bins 1..NUM_POS_SC and NEG_FIRST_BIN..N-1 (DC and guard bins are zero). Pilot slots (active stream index
// % PILOT_SPACING == PILOT_OFFSET) are emitted as zero with out_pilot=1 (phy_pilot_insert fills them).
// Data slots consume one QAM symbol each from the input stream (in_ready only on data slots, state-dependent).
// Handshake: a symbol runs after start_valid&&start_ready; start_ready=1 while idle. If a data slot has no input the
// output stalls (out_valid=0, bin does not advance), so the downstream core must accept gaps.
// Latency: 1 cycle (registered output).  Throughput: 1 bin/cycle.   Golden: python/ofdm_ref.py::map_bins
module phy_ofdm_mapper
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   start_valid,
  output logic                   start_ready,
  input  logic                   in_valid,
  output logic                   in_ready,
  input  logic signed [IQ_W-1:0] in_re,
  input  logic signed [IQ_W-1:0] in_im,
  output logic                   out_valid,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im,
  output logic                   out_pilot,
  output logic                   out_first,
  output logic                   out_last
);
  localparam int LATENCY = 1;
  localparam int BW = $clog2(FFT_SIZE);
  localparam int PW = $clog2(PILOT_SPACING);

  logic          busy;
  logic [BW-1:0] bin;
  logic [PW-1:0] pmod;          // active stream index % PILOT_SPACING

  wire active    = (bin >= BW'(1) && bin <= BW'(NUM_POS_SC)) || (bin >= BW'(NEG_FIRST_BIN));
  wire pilot_slot = active && (pmod == PW'(PILOT_OFFSET));
  wire data_slot  = active && !pilot_slot;

  assign start_ready = ~busy;
  assign in_ready    = busy && data_slot;
  wire   step        = busy && (!data_slot || in_valid);

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0; bin <= '0; pmod <= '0;
      out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0; out_pilot <= 1'b0;
      out_re <= '0; out_im <= '0;
    end else begin
      out_valid <= step;
      if (step) begin
        out_first <= (bin == '0);
        out_last  <= (bin == BW'(FFT_SIZE - 1));
        out_pilot <= pilot_slot;
        out_re    <= data_slot ? in_re : '0;
        out_im    <= data_slot ? in_im : '0;
        if (active) pmod <= (pmod == PW'(PILOT_SPACING - 1)) ? '0 : pmod + 1'b1;
        if (bin == BW'(FFT_SIZE - 1)) begin busy <= 1'b0; bin <= '0; pmod <= '0; end
        else bin <= bin + 1'b1;
      end else if (!busy && start_valid) begin
        busy <= 1'b1;
      end
    end
  end
endmodule
