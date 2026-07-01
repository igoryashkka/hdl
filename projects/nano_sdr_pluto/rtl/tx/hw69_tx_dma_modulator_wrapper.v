`timescale 1ns / 1ps

module hw69_tx_dma_modulator_wrapper #(
  parameter AXIS_DATA_WIDTH = 64,
  parameter FIFO_DEPTH_LOG2 = 4,
  parameter SAMPLE_WIDTH = 18,
  parameter FRAC_BITS = 16,
  parameter IQ_WIDTH = 16,
  parameter SYMBOL_CLKS_PER_BIT = 100,
  parameter PHASE_WIDTH = 32,
  parameter signed [31:0] CARRIER_PHASE_WORD = 32'sd268435456,
  parameter signed [31:0] DEVIATION_PHASE_WORD = 32'sd78293675
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis, ASSOCIATED_RESET axis_rst" *)
  input axis_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_rst RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
  input axis_rst,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
  input [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
  input s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
  output s_axis_tready,

  (* X_INTERFACE_IGNORE = "true" *) input control_enable,
  (* X_INTERFACE_IGNORE = "true" *) input control_restart,

  (* X_INTERFACE_IGNORE = "true" *) input tx_sample_strobe,
  (* X_INTERFACE_IGNORE = "true" *) output [15:0] tx_i0,
  (* X_INTERFACE_IGNORE = "true" *) output [15:0] tx_q0,
  (* X_INTERFACE_IGNORE = "true" *) output [15:0] tx_i1,
  (* X_INTERFACE_IGNORE = "true" *) output [15:0] tx_q1,
  (* X_INTERFACE_IGNORE = "true" *) output tx_underflow,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_axis_word_lo,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_axis_word_hi,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_current_word_lo,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_current_word_hi,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_state_flags,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_fifo_state,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_accepted_words,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_emitted_bits,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_underflows,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_mod_state,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_tx_samples_lo,
  (* X_INTERFACE_IGNORE = "true" *) output [31:0] dbg_tx_samples_hi
);

  hw69_tx_dma_modulator_core #(
    .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
    .FIFO_DEPTH_LOG2(FIFO_DEPTH_LOG2),
    .SAMPLE_WIDTH(SAMPLE_WIDTH),
    .FRAC_BITS(FRAC_BITS),
    .IQ_WIDTH(IQ_WIDTH),
    .SYMBOL_CLKS_PER_BIT(SYMBOL_CLKS_PER_BIT),
    .PHASE_WIDTH(PHASE_WIDTH),
    .CARRIER_PHASE_WORD(CARRIER_PHASE_WORD),
    .DEVIATION_PHASE_WORD(DEVIATION_PHASE_WORD)
  ) i_core (
    .axis_aclk(axis_aclk),
    .axis_rst(axis_rst),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .control_enable(control_enable),
    .control_restart(control_restart),
    .tx_sample_strobe(tx_sample_strobe),
    .tx_i0(tx_i0),
    .tx_q0(tx_q0),
    .tx_i1(tx_i1),
    .tx_q1(tx_q1),
    .tx_underflow(tx_underflow),
    .dbg_axis_word_lo(dbg_axis_word_lo),
    .dbg_axis_word_hi(dbg_axis_word_hi),
    .dbg_current_word_lo(dbg_current_word_lo),
    .dbg_current_word_hi(dbg_current_word_hi),
    .dbg_state_flags(dbg_state_flags),
    .dbg_fifo_state(dbg_fifo_state),
    .dbg_accepted_words(dbg_accepted_words),
    .dbg_emitted_bits(dbg_emitted_bits),
    .dbg_underflows(dbg_underflows),
    .dbg_mod_state(dbg_mod_state),
    .dbg_tx_samples_lo(dbg_tx_samples_lo),
    .dbg_tx_samples_hi(dbg_tx_samples_hi)
  );

endmodule