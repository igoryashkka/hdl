// phy_pkg.sv -- single source of truth for PHY constants (no magic numbers in RTL).
// Mirror of python/phy_params.py; keep both in sync (checked by python/check_params.py).
package phy_pkg;

  // ---- numerology (LTE-20MHz-like) ----
  localparam int SAMPLE_RATE_HZ   = 30_720_000;
  localparam int FFT_SIZE         = 2048;
  localparam int CP_LEN           = 144;
  localparam int SYMBOL_LEN       = FFT_SIZE + CP_LEN;          // 2192 samples
  localparam int SUBCARRIER_HZ    = SAMPLE_RATE_HZ / FFT_SIZE;  // 15000
  localparam int SYMBOL_RATE_HZ   = SAMPLE_RATE_HZ / SYMBOL_LEN; // 14014 (integer part)

  // ---- subcarrier allocation ----
  localparam int NUM_ACTIVE_SC    = 1200;                       // +-600 around DC, DC unused
  localparam int PILOT_SPACING    = 12;
  localparam int NUM_PILOTS       = NUM_ACTIVE_SC / PILOT_SPACING;          // 100
  localparam int NUM_DATA_SC      = NUM_ACTIVE_SC - NUM_PILOTS;             // 1100

  localparam int NUM_POS_SC       = NUM_ACTIVE_SC / 2;          // bins 1 .. 600
  localparam int NEG_FIRST_BIN    = FFT_SIZE - NUM_POS_SC;      // bins 1448 .. 2047 (negative frequencies)
  localparam int PILOT_OFFSET     = 6;                          // pilot where (active stream index % PILOT_SPACING) == 6

  // ---- modulation ----
  localparam int QAM_ORDER        = 16;                         // 4 / 16 / 64
  localparam int BITS_PER_SYM     = $clog2(QAM_ORDER);          // 4
  localparam int BITS_PER_AXIS    = BITS_PER_SYM / 2;
  localparam int QAM_UNIT         = 4096;                       // axis level unit, Q4.12 -> levels +-U*(2i-(M-1))
  localparam int IQ_W             = 16;                         // signed baseband sample width
  localparam int LLR_W            = 8;                          // signed soft-bit width
  localparam int LLR_SHIFT        = 6;                          // llr = sat(t * LLR_GAIN >>> LLR_SHIFT)
  localparam int LLR_GAIN         = 1;

  // ---- interleaver geometry (symbol-level block interleaver, ROWS*COLS = NUM_DATA_SC) ----
  localparam int IL_COLS          = 20;
  localparam int IL_ROWS          = 55;
  localparam int PILOT_AMP        = 3 * QAM_UNIT;
  localparam int SYNC_AMP         = 4 * QAM_UNIT;

  // ---- FEC (rate expressed as num/den) ----
  localparam int LDPC_RATE_NUM    = 5;
  localparam int LDPC_RATE_DEN    = 6;
  localparam int CODED_BITS_PER_OFDM = NUM_DATA_SC * BITS_PER_SYM;          // 4400
  localparam int BYTES_PER_OFDM   = CODED_BITS_PER_OFDM / 8;                // 550 (uncoded mode: 1 byte = 2 QAM words)
  localparam int TX_MAX_SYMS      = 8;                                      // max data OFDM symbols per packet

  // ---- known sequences (x^15+x^14+1 LFSR seeds) ----
  localparam logic [14:0] PILOT_SEED = 15'h7FFF;
  localparam logic [14:0] SYNC_SEED  = 15'h1ACE;
  localparam logic [14:0] LTS_SEED   = 15'h2B5D;

  // ---- scrambler / CRC ----
  localparam logic [14:0] SCR_SEED = 15'h7FFF;                  // x^15 + x^14 + 1
  localparam logic [31:0] CRC32_POLY_REV = 32'hEDB88320;
  localparam logic [31:0] CRC32_INIT     = 32'hFFFF_FFFF;
  localparam logic [31:0] CRC32_RESIDUE  = 32'hDEBB_20E3;       // register value after good frame (no final xor)

  // ---- phy_fft_core latency (cycles, continuous input): structural N-1 + pipeline of every stage (2; 7 if D>=4)
  function automatic int fft_core_latency(input int n_log);
    int t;
    t = (1 << n_log) - 1;
    for (int s = 0; s < n_log; s++) t += 1 + ((((1 << (n_log - 1 - s)) >= 4)) ? 6 : 1);
    return t;
  endfunction

endpackage
