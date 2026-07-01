`timescale 1ns / 1ps

module hw69_tx_dma_modulator_core #(
    parameter int unsigned AXIS_DATA_WIDTH = 64,
    parameter int unsigned FIFO_DEPTH_LOG2 = 4,
    parameter int unsigned SAMPLE_WIDTH = 18,
    parameter int unsigned FRAC_BITS = 16,
    parameter int unsigned IQ_WIDTH = 16,
    parameter int unsigned SYMBOL_CLKS_PER_BIT = 100,
    parameter int unsigned PHASE_WIDTH = 32,
    parameter logic signed [PHASE_WIDTH-1:0] CARRIER_PHASE_WORD = 32'sd268435456,
    parameter logic signed [PHASE_WIDTH-1:0] DEVIATION_PHASE_WORD = 32'sd78293675
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis, ASSOCIATED_RESET axis_rst" *)
    input  logic axis_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  logic axis_rst,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  logic [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  logic s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output logic s_axis_tready,

    (* X_INTERFACE_IGNORE = "true" *) input  logic control_enable,
    (* X_INTERFACE_IGNORE = "true" *) input  logic control_restart,

    (* X_INTERFACE_IGNORE = "true" *) input  logic tx_sample_strobe,
    (* X_INTERFACE_IGNORE = "true" *) output logic [15:0] tx_i0,
    (* X_INTERFACE_IGNORE = "true" *) output logic [15:0] tx_q0,
    (* X_INTERFACE_IGNORE = "true" *) output logic [15:0] tx_i1,
    (* X_INTERFACE_IGNORE = "true" *) output logic [15:0] tx_q1,
    (* X_INTERFACE_IGNORE = "true" *) output logic tx_underflow,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_axis_word_lo,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_axis_word_hi,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_current_word_lo,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_current_word_hi,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_state_flags,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_fifo_state,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_accepted_words,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_emitted_bits,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_underflows,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_mod_state,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_tx_samples_lo,
    (* X_INTERFACE_IGNORE = "true" *) output logic [31:0] dbg_tx_samples_hi
);
    localparam int unsigned FIFO_DEPTH = 1 << FIFO_DEPTH_LOG2;
    localparam int unsigned BYTES_PER_WORD = AXIS_DATA_WIDTH / 8;
    localparam int unsigned BYTE_INDEX_WIDTH = $clog2(BYTES_PER_WORD);
    logic enable_meta;
    logic enable_sync;
    logic restart_meta;
    logic restart_sync;
    logic restart_sync_d;
    logic restart_pulse;

    logic [31:0] accepted_words_axis;
    logic [31:0] emitted_bits_axis;
    logic [31:0] underflows_axis;

    logic [AXIS_DATA_WIDTH-1:0] fifo_mem [FIFO_DEPTH];
    logic [FIFO_DEPTH_LOG2-1:0] wr_ptr;
    logic [FIFO_DEPTH_LOG2-1:0] rd_ptr;
    logic [FIFO_DEPTH_LOG2:0] fifo_count;
    logic fifo_push;
    logic fifo_pop;

    logic [AXIS_DATA_WIDTH-1:0] current_word;
    logic word_active;
    logic [BYTE_INDEX_WIDTH-1:0] byte_index;
    logic [2:0] bit_index;
    logic bit_ce;
    logic sample_tick;
    logic bit_valid;
    logic tx_bit;
    logic burst_gate;

    logic [$clog2(SYMBOL_CLKS_PER_BIT)-1:0] symbol_divider;

    logic iq_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;

    logic gate_valid;
    logic signed [SAMPLE_WIDTH-1:0] gate_sample;
    logic gate_open;

    logic [7:0] dbg_active_byte;

    assign dbg_axis_word_lo = s_axis_tdata[31:0];
    assign dbg_axis_word_hi = s_axis_tdata[63:32];
    assign dbg_current_word_lo = current_word[31:0];
    assign dbg_current_word_hi = current_word[63:32];
    assign dbg_accepted_words = accepted_words_axis;
    assign dbg_emitted_bits = emitted_bits_axis;
    assign dbg_underflows = underflows_axis;
    assign dbg_tx_samples_lo = {tx_i0, tx_q0};
    assign dbg_tx_samples_hi = {tx_i1, tx_q1};
    assign dbg_active_byte = word_active ? current_word[(byte_index * 8) +: 8] :
        ((fifo_count != 0) ? fifo_mem[rd_ptr][7:0] : 8'h00);

    always_comb begin
        dbg_state_flags = '0;
        dbg_state_flags[0] = control_enable;
        dbg_state_flags[1] = enable_meta;
        dbg_state_flags[2] = enable_sync;
        dbg_state_flags[3] = control_restart;
        dbg_state_flags[4] = restart_meta;
        dbg_state_flags[5] = restart_sync;
        dbg_state_flags[6] = restart_pulse;
        dbg_state_flags[7] = s_axis_tvalid;
        dbg_state_flags[8] = s_axis_tready;
        dbg_state_flags[9] = fifo_push;
        dbg_state_flags[10] = fifo_pop;
        dbg_state_flags[11] = word_active;
        dbg_state_flags[12] = bit_valid;
        dbg_state_flags[13] = tx_bit;
        dbg_state_flags[14] = burst_gate;
        dbg_state_flags[15] = bit_ce;
        dbg_state_flags[16] = sample_tick;
        dbg_state_flags[17] = iq_valid;
        dbg_state_flags[18] = gate_valid;
        dbg_state_flags[19] = gate_open;
        dbg_state_flags[20] = tx_underflow;
        dbg_state_flags[23:21] = bit_index;
        dbg_state_flags[26:24] = byte_index;
    end

    always_comb begin
        dbg_fifo_state = '0;
        dbg_fifo_state[FIFO_DEPTH_LOG2:0] = fifo_count;
        dbg_fifo_state[8 +: FIFO_DEPTH_LOG2] = wr_ptr;
        dbg_fifo_state[12 +: FIFO_DEPTH_LOG2] = rd_ptr;
        dbg_fifo_state[13 +: $clog2(SYMBOL_CLKS_PER_BIT)] = symbol_divider;
        dbg_fifo_state[31:24] = dbg_active_byte;
    end

    always_comb begin
        dbg_mod_state = '0;
        dbg_mod_state[SAMPLE_WIDTH-1:0] = gate_sample;
        dbg_mod_state[18] = gate_valid;
        dbg_mod_state[19] = gate_open;
        dbg_mod_state[20] = iq_valid;
        dbg_mod_state[21] = tx_bit;
        dbg_mod_state[22] = burst_gate;
        dbg_mod_state[23] = bit_ce;
        dbg_mod_state[24] = sample_tick;
        dbg_mod_state[25] = tx_underflow;
    end

    assign fifo_push = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = enable_sync && (fifo_count < FIFO_DEPTH);
    assign sample_tick = tx_sample_strobe;
    assign fifo_pop = bit_ce && enable_sync && !word_active && (fifo_count != 0);

always_ff @(posedge axis_aclk) begin
    if (axis_rst || restart_pulse) begin
        enable_meta <= 1'b1;
        enable_sync <= 1'b1;
        restart_meta <= 1'b0;
        restart_sync <= 1'b0;
        restart_sync_d <= 1'b0;
    end else begin
        enable_meta <= 1'b1;
        enable_sync <= 1'b1;
        restart_meta <= control_restart;
        restart_sync <= restart_meta;
        restart_sync_d <= restart_sync;
    end
end

    assign restart_pulse = restart_sync ^ restart_sync_d;

    always_ff @(posedge axis_aclk) begin
        if (axis_rst || restart_pulse) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            fifo_count <= '0;
            current_word <= '0;
            word_active <= 1'b0;
            byte_index <= '0;
            bit_index <= 3'd7;
            bit_valid <= 1'b0;
            tx_bit <= 1'b0;
            burst_gate <= 1'b0;
            accepted_words_axis <= '0;
            emitted_bits_axis <= '0;
            underflows_axis <= '0;
            tx_underflow <= 1'b0;
        end else begin
            bit_valid <= 1'b0;
            burst_gate <= 1'b0;
            tx_underflow <= 1'b0;

            if (fifo_push) begin
                fifo_mem[wr_ptr] <= s_axis_tdata;
                wr_ptr <= wr_ptr + 1'b1;
                accepted_words_axis <= accepted_words_axis + 1'b1;
            end

            if (bit_ce && enable_sync) begin
                if (!word_active) begin
                    if (fifo_count != 0) begin
                        current_word <= fifo_mem[rd_ptr];
                        rd_ptr <= rd_ptr + 1'b1;
                        word_active <= 1'b1;
                        byte_index <= '0;
                        bit_index <= 3'd6;
                        bit_valid <= 1'b1;
                        tx_bit <= fifo_mem[rd_ptr][7];
                        burst_gate <= 1'b1;
                        emitted_bits_axis <= emitted_bits_axis + 1'b1;
                    end else begin
                        tx_bit <= 1'b0;
                        underflows_axis <= underflows_axis + 1'b1;
                        tx_underflow <= 1'b1;
                    end
                end else begin
                    bit_valid <= 1'b1;
                    tx_bit <= current_word[(byte_index * 8) + bit_index];
                    burst_gate <= 1'b1;
                    emitted_bits_axis <= emitted_bits_axis + 1'b1;

                    if (bit_index == 3'd0) begin
                        bit_index <= 3'd7;
                        if (byte_index == BYTES_PER_WORD - 1) begin
                            byte_index <= '0;
                            word_active <= 1'b0;
                        end else begin
                            byte_index <= byte_index + 1'b1;
                        end
                    end else begin
                        bit_index <= bit_index - 1'b1;
                    end
                end
            end

            unique case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    always_ff @(posedge axis_aclk) begin
        if (axis_rst || restart_pulse || !enable_sync) begin
            symbol_divider <= '0;
            bit_ce <= 1'b0;
        end else if (!sample_tick) begin
            bit_ce <= 1'b0;
        end else if (symbol_divider == '0) begin
            symbol_divider <= SYMBOL_CLKS_PER_BIT - 1'b1;
            bit_ce <= 1'b1;
        end else begin
            symbol_divider <= symbol_divider - 1'b1;
            bit_ce <= 1'b0;
        end
    end

    hw69_tx_modulator_from_bits #(
        .SAMPLE_WIDTH(SAMPLE_WIDTH),
        .FRAC_BITS(FRAC_BITS),
        .IQ_WIDTH(IQ_WIDTH),
        .SYMBOL_CLKS_PER_BIT(SYMBOL_CLKS_PER_BIT),
        .PHASE_WIDTH(PHASE_WIDTH),
        .CARRIER_PHASE_WORD(CARRIER_PHASE_WORD),
        .DEVIATION_PHASE_WORD(DEVIATION_PHASE_WORD)
    ) tx_modulator (
        .clk(axis_aclk),
        .rst(axis_rst || restart_pulse),
        .bit_valid(bit_valid),
        .tx_bit(tx_bit),
        .burst_gate(burst_gate),
        .phase_valid(),
        .phase_word(),
        .iq_valid(iq_valid),
        .i_sample(i_sample),
        .q_sample(q_sample),
        .gate_valid(gate_valid),
        .gate_sample(gate_sample),
        .shaped_freq_control()
    );

    always_ff @(posedge axis_aclk) begin
        if (axis_rst || restart_pulse || !enable_sync) begin
            gate_open <= 1'b0;
            tx_i0 <= '0;
            tx_q0 <= '0;
            tx_i1 <= '0;
            tx_q1 <= '0;
        end else begin
            if (gate_valid) begin
                gate_open <= (gate_sample != '0);
            end
            if (iq_valid) begin
                if (gate_open) begin
                    tx_i0 <= i_sample;
                    tx_q0 <= q_sample;
                end else begin
                    tx_i0 <= '0;
                    tx_q0 <= '0;
                end
            end
            tx_i1 <= '0;
            tx_q1 <= '0;
        end
    end
endmodule