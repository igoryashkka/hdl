`timescale 1ns / 1ps

module hw69_tx_modulator_chain #(
    parameter int unsigned SAMPLE_WIDTH = 18,
    parameter int unsigned FRAC_BITS = 16,
    parameter int unsigned IQ_WIDTH = 16,
    parameter int unsigned SYMBOL_CLKS_PER_BIT = 100,
    parameter int unsigned PREAMBLE_BYTES = 80,
    parameter int unsigned MAX_PACKETS = 100,
    parameter int unsigned PACKET_PERIOD_BITS = 9600,
    parameter int unsigned TAIL_GUARD_BITS = 24,
    parameter logic [8:0] PN9_SEED = 9'h1ff,
    parameter int unsigned PHASE_WIDTH = 32,
    parameter logic signed [PHASE_WIDTH-1:0] CARRIER_PHASE_WORD = 32'sd268435456,
    parameter logic signed [PHASE_WIDTH-1:0] DEVIATION_PHASE_WORD = 32'sd78293675
) (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    input  logic restart,
    output logic phase_valid,
    output logic [PHASE_WIDTH-1:0] phase_word,
    output logic iq_valid,
    output logic signed [IQ_WIDTH-1:0] i_sample,
    output logic signed [IQ_WIDTH-1:0] q_sample,
    output logic gate_valid,
    output logic signed [SAMPLE_WIDTH-1:0] gate_sample,
    output logic signed [SAMPLE_WIDTH-1:0] shaped_freq_control,
    output logic packet_start,
    output logic packet_done,
    output logic tx_done,
    output logic [31:0] sent_count
);
    localparam logic signed [SAMPLE_WIDTH-1:0] NEG_HALF_Q = -(1 <<< (FRAC_BITS - 1));
    localparam logic signed [19:0] TWO_Q = 20'sd131072;

    logic [$clog2(SYMBOL_CLKS_PER_BIT)-1:0] symbol_divider;
    logic bit_ce;

    logic bit_valid;
    logic tx_bit;
    logic burst_gate;

    logic bit_fixed_valid;
    logic signed [SAMPLE_WIDTH-1:0] bit_fixed;
    logic add_valid;
    logic signed [SAMPLE_WIDTH-1:0] add_data;
    logic scale_valid;
    logic signed [SAMPLE_WIDTH-1:0] scaled_symbol;
    logic symbol_sample_valid;
    logic signed [SAMPLE_WIDTH-1:0] symbol_sample;
    logic lpf_valid;
    logic signed [SAMPLE_WIDTH-1:0] lpf_sample;
    logic modulator_in_valid;

    logic gate_fixed_valid;
    logic signed [SAMPLE_WIDTH-1:0] gate_fixed;

    always_ff @(posedge clk) begin
        if (rst || restart) begin
            symbol_divider <= '0;
            bit_ce <= 1'b0;
        end else begin
            if (symbol_divider == '0) begin
                symbol_divider <= SYMBOL_CLKS_PER_BIT - 1'b1;
                bit_ce <= 1'b1;
            end else begin
                symbol_divider <= symbol_divider - 1'b1;
                bit_ce <= 1'b0;
            end
        end
    end

    hw69_tx_bitstream #(
        .PREAMBLE_BYTES(PREAMBLE_BYTES),
        .MAX_PACKETS(MAX_PACKETS),
        .PACKET_PERIOD_BITS(PACKET_PERIOD_BITS),
        .TAIL_GUARD_BITS(TAIL_GUARD_BITS),
        .PN9_SEED(PN9_SEED)
    ) packet_source (
        .clk(clk),
        .rst(rst),
        .bit_ce(bit_ce),
        .enable(enable),
        .restart(restart),
        .bit_valid(bit_valid),
        .tx_bit(tx_bit),
        .burst_gate(burst_gate),
        .packet_start(packet_start),
        .packet_done(packet_done),
        .tx_done(tx_done),
        .sent_count(sent_count)
    );

    hw69_char_to_fixed #(
        .OUT_WIDTH(SAMPLE_WIDTH),
        .FRAC_BITS(FRAC_BITS)
    ) bit_char_to_fixed (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_valid),
        .char_in({7'b0, tx_bit}),
        .out_valid(bit_fixed_valid),
        .fixed_out(bit_fixed)
    );

    hw69_fixed_add_const #(
        .DATA_WIDTH(SAMPLE_WIDTH),
        .CONST_Q(NEG_HALF_Q)
    ) bit_add_const (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_fixed_valid),
        .data_in(bit_fixed),
        .out_valid(add_valid),
        .data_out(add_data)
    );

    hw69_fixed_multiply_const #(
        .DATA_WIDTH(SAMPLE_WIDTH),
        .CONST_WIDTH(20),
        .CONST_FRAC_BITS(FRAC_BITS),
        .CONST_Q(TWO_Q)
    ) bit_multiply_const (
        .clk(clk),
        .rst(rst),
        .in_valid(add_valid),
        .data_in(add_data),
        .out_valid(scale_valid),
        .data_out(scaled_symbol)
    );

    hw69_zoh_resampler #(
        .DATA_WIDTH(SAMPLE_WIDTH),
        .INTERP(SYMBOL_CLKS_PER_BIT)
    ) bit_resampler (
        .clk(clk),
        .rst(rst),
        .in_valid(scale_valid),
        .data_in(scaled_symbol),
        .out_valid(symbol_sample_valid),
        .data_out(symbol_sample)
    );

    hw69_tx_shaping_lpf #(
        .DATA_WIDTH(SAMPLE_WIDTH)
    ) tx_shape_filter (
        .clk(clk),
        .rst(rst),
        .in_valid(symbol_sample_valid),
        .data_in(symbol_sample),
        .out_valid(lpf_valid),
        .data_out(lpf_sample)
    );

    // Keep burst gating out of the DDS path for now; gate_sample remains a separate post-modulation control path.
    assign modulator_in_valid = lpf_valid;

    hw69_fsk_iq_modulator #(
        .CONTROL_WIDTH(SAMPLE_WIDTH),
        .CONTROL_FRAC_BITS(FRAC_BITS),
        .PHASE_WIDTH(PHASE_WIDTH),
        .IQ_WIDTH(IQ_WIDTH),
        .CARRIER_PHASE_WORD(CARRIER_PHASE_WORD),
        .DEVIATION_PHASE_WORD(DEVIATION_PHASE_WORD)
    ) fsk_iq_modulator (
        .clk(clk),
        .rst(rst),
        .in_valid(modulator_in_valid),
        .freq_control(lpf_sample),
        .phase_valid(phase_valid),
        .phase_word(phase_word),
        .out_valid(iq_valid),
        .i_out(i_sample),
        .q_out(q_sample)
    );

    hw69_char_to_fixed #(
        .OUT_WIDTH(SAMPLE_WIDTH),
        .FRAC_BITS(FRAC_BITS)
    ) gate_char_to_fixed (
        .clk(clk),
        .rst(rst),
        .in_valid(bit_valid),
        .char_in({7'b0, burst_gate}),
        .out_valid(gate_fixed_valid),
        .fixed_out(gate_fixed)
    );

    hw69_zoh_resampler #(
        .DATA_WIDTH(SAMPLE_WIDTH),
        .INTERP(SYMBOL_CLKS_PER_BIT)
    ) gate_resampler (
        .clk(clk),
        .rst(rst),
        .in_valid(gate_fixed_valid),
        .data_in(gate_fixed),
        .out_valid(gate_valid),
        .data_out(gate_sample)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            shaped_freq_control <= '0;
        end else if (lpf_valid) begin
            shaped_freq_control <= lpf_sample;
        end
    end
endmodule