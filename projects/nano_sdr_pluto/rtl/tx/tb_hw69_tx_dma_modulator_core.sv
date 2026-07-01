`timescale 1ns / 1ps

module tb_hw69_tx_dma_modulator_core;
    localparam int unsigned CLK_PERIOD_NS = 10;
    localparam logic [63:0] TEST_WORD = 64'h0000_0000_3333_3833;

    logic axis_aclk = 1'b0;
    logic axis_rst = 1'b1;
    logic [63:0] s_axis_tdata = '0;
    logic s_axis_tvalid = 1'b0;
    logic s_axis_tready;
    logic control_enable = 1'b1;
    logic control_restart = 1'b0;
    logic tx_sample_strobe = 1'b0;
    logic [15:0] tx_i0;
    logic [15:0] tx_q0;
    logic [15:0] tx_i1;
    logic [15:0] tx_q1;
    logic tx_underflow;
    logic [31:0] dbg_axis_word_lo;
    logic [31:0] dbg_axis_word_hi;
    logic [31:0] dbg_current_word_lo;
    logic [31:0] dbg_current_word_hi;
    logic [31:0] dbg_state_flags;
    logic [31:0] dbg_fifo_state;
    logic [31:0] dbg_accepted_words;
    logic [31:0] dbg_emitted_bits;
    logic [31:0] dbg_underflows;
    logic [31:0] dbg_mod_state;
    logic [31:0] dbg_tx_samples_lo;
    logic [31:0] dbg_tx_samples_hi;

    int emitted_count = 0;
    bit expected_bits [0:15] = '{
        1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1,
        1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0
    };

    hw69_tx_dma_modulator_core #(
        .SYMBOL_CLKS_PER_BIT(4)
    ) dut (
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

    always #(CLK_PERIOD_NS / 2) axis_aclk = ~axis_aclk;

    always_ff @(posedge axis_aclk) begin
        if (axis_rst) begin
            emitted_count <= 0;
        end else if (dut.bit_valid && emitted_count < 16) begin
            if (dut.tx_bit !== expected_bits[emitted_count]) begin
                $error("bit %0d mismatch: got %0b expected %0b", emitted_count,
                       dut.tx_bit, expected_bits[emitted_count]);
                $fatal(1);
            end
            emitted_count <= emitted_count + 1;
        end
    end

    initial begin
        repeat (4) @(posedge axis_aclk);
        axis_rst <= 1'b0;
        wait (s_axis_tready == 1'b1);
        s_axis_tdata <= TEST_WORD;
        s_axis_tvalid <= 1'b1;
        @(posedge axis_aclk);
        s_axis_tvalid <= 1'b0;
        s_axis_tdata <= '0;

        wait (dbg_accepted_words == 32'd1);
        tx_sample_strobe <= 1'b1;
        wait (dut.word_active == 1'b1);
        wait (emitted_count == 16);

        if (dbg_current_word_lo !== TEST_WORD[31:0]) begin
            $error("current_word_lo mismatch: got 0x%08x expected 0x%08x",
                   dbg_current_word_lo, TEST_WORD[31:0]);
            $fatal(1);
        end

        if (dbg_current_word_hi !== TEST_WORD[63:32]) begin
            $error("current_word_hi mismatch: got 0x%08x expected 0x%08x",
                   dbg_current_word_hi, TEST_WORD[63:32]);
            $fatal(1);
        end

        if (dbg_emitted_bits < 32'd16) begin
            $error("expected at least 16 emitted bits, got %0d", dbg_emitted_bits);
            $fatal(1);
        end

        if (dbg_underflows != 32'd0) begin
            $error("unexpected underflows: %0d", dbg_underflows);
            $fatal(1);
        end

        $display("PASS accepted=%0d current_lo=0x%08x current_hi=0x%08x emitted=%0d tx_lo=0x%08x",
                 dbg_accepted_words, dbg_current_word_lo, dbg_current_word_hi,
                 dbg_emitted_bits, dbg_tx_samples_lo);
        $finish;
    end
endmodule