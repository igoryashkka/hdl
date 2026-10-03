// ***************************************************************************
// GFSK RX, one channel: IQ (fs = 4.5 MS/s) -> decoded frame bytes.
//   nco_mix -> CIC /8 -> FIR -> discriminator -> bit sync -> frame
// Channel selection is the phase_inc input (fc_bb - channel carrier offset from LO).
// ***************************************************************************
`timescale 1ns/100ps

module gfsk_rx_1ch (
  input  logic               clk,
  input  logic               rst,
  input  logic               in_valid,      // one IQ sample per strobe
  input  logic signed [15:0] i_in,
  input  logic signed [15:0] q_in,
  input  logic        [31:0] phase_inc,      // round(fc_bb/fs * 2^32)
  output logic               frame_start,
  output logic               byte_valid,
  output logic        [7:0]  byte_out,
  output logic               frame_done,
  output logic        [7:0]  frame_len
);
  logic signed [15:0] mi, mq;
  logic               mix_v;
  logic signed [15:0] ci, cq;
  logic               cic_en;
  logic signed [15:0] fi, fq;
  logic               fir_v;
  logic signed [23:0] dd;
  logic               dis_v;
  logic               bit_v, bit_b;

  gfsk_nco_mix #(.IN_W(16)) u_mix (
    .clk, .en(in_valid), .i_in, .q_in, .phase_inc,
    .i_out(mi), .q_out(mq), .out_valid(mix_v)
  );

  logic cic_en_q, cic_en_i;
  gfsk_cic_dec #(.IN_W(16), .R(8)) u_cic_i (
    .clk, .en_in(mix_v), .din(mi), .en_out(cic_en_i), .dout(ci)
  );
  gfsk_cic_dec #(.IN_W(16), .R(8)) u_cic_q (
    .clk, .en_in(mix_v), .din(mq), .en_out(cic_en_q), .dout(cq)
  );
  assign cic_en = cic_en_i;   // both decimators run on the same counter

  gfsk_fir #(.IN_W(16)) u_fir (
    .clk, .en(cic_en), .i_in(ci), .q_in(cq), .i_out(fi), .q_out(fq), .out_valid(fir_v)
  );

  gfsk_discrim #(.IN_W(16)) u_dis (
    .clk, .en(fir_v), .i_in(fi), .q_in(fq), .d_out(dd), .out_valid(dis_v)
  );

  gfsk_bitsync u_bs (
    .clk, .en(dis_v), .d_in(dd), .bit_valid(bit_v), .bit_out(bit_b)
  );

  gfsk_frame u_frame (
    .clk, .rst, .en(bit_v), .bit_in(bit_b),
    .frame_start, .byte_valid, .byte_out, .frame_done, .frame_len
  );
endmodule
