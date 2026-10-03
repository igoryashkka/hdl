// Module : phy_preamble_gen   frequency-domain preamble symbols, FFT_SIZE bins in natural order, 1 bin/cycle.
//   kind 0 (sync): even active bins only, +-SYNC_AMP -> time domain is periodic with FFT_SIZE/2 (Schmidl-Cox timing/CFO)
//   kind 1 (LTS) : all active bins, +-PILOT_AMP, known to the receiver (channel estimate, integer CFO)
// Handshake: start_valid&&start_ready latches `kind`; start_ready=1 while idle. First bin is visible 2 cycles after the handshake edge.
// Golden: python/ofdm_ref.py::preamble
module phy_preamble_gen
  import phy_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst,
  input  logic                   start_valid,
  output logic                   start_ready,
  input  logic                   start_kind,
  output logic                   out_valid,
  output logic                   out_first,
  output logic                   out_last,
  output logic signed [IQ_W-1:0] out_re,
  output logic signed [IQ_W-1:0] out_im
);
  localparam int LATENCY = 1;
  localparam int BW = $clog2(FFT_SIZE);

  logic          busy, kind;
  logic [BW-1:0] bin;
  logic [14:0]   lfsr;
  wire           fb     = lfsr[14] ^ lfsr[13];
  wire           active = (bin >= BW'(1) && bin <= BW'(NUM_POS_SC)) || (bin >= BW'(NEG_FIRST_BIN));
  wire           used   = active && (kind || !bin[0]);

  assign start_ready = ~busy;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0; kind <= 1'b0; bin <= '0; lfsr <= '0;
      out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0; out_re <= '0; out_im <= '0;
    end else begin
      out_valid <= busy;
      if (busy) begin
        out_first <= (bin == '0);
        out_last  <= (bin == BW'(FFT_SIZE - 1));
        out_im    <= '0;
        out_re    <= used ? (fb ? -IQ_W'(kind ? PILOT_AMP : SYNC_AMP) : IQ_W'(kind ? PILOT_AMP : SYNC_AMP)) : '0;
        if (used) lfsr <= {lfsr[13:0], fb};
        if (bin == BW'(FFT_SIZE - 1)) begin busy <= 1'b0; bin <= '0; end
        else bin <= bin + 1'b1;
      end else if (start_valid) begin
        busy <= 1'b1; kind <= start_kind;
        lfsr <= start_kind ? LTS_SEED : SYNC_SEED;
      end
    end
  end
endmodule
