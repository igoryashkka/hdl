`timescale 1ns / 1ps

module tb_hw69_tx_dma_modulator_core_burst;
    localparam int unsigned CLK_PERIOD_NS = 10;
    localparam logic [63:0] WORD0 = 64'h0000_0000_3333_3833;
    localparam logic [63:0] WORD1 = 64'h0000_0000_3534_3132;

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

    int bit_count = 0;

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

    task automatic send_axis_word(input logic [63:0] word);
        begin
            s_axis_tdata <= word;
            s_axis_tvalid <= 1'b1;
            do begin
                @(posedge axis_aclk);
            end while (!s_axis_tready);
            s_axis_tvalid <= 1'b0;
            s_axis_tdata <= '0;
        end
    endtask

    always_ff @(posedge axis_aclk) begin
        if (axis_rst) begin
            bit_count <= 0;
        end else if (dut.bit_valid) begin
            bit_count <= bit_count + 1;
        end
    end

    initial begin
        repeat (4) @(posedge axis_aclk);
        axis_rst <= 1'b0;
        tx_sample_strobe <= 1'b1;

        wait (s_axis_tready == 1'b1);
        send_axis_word(WORD0);
        send_axis_word(WORD1);

        wait (dbg_accepted_words == 32'd2);

        if (dbg_current_word_lo !== WORD0[31:0]) begin
            $error("expected first current word lo 0x%08x, got 0x%08x",
                   WORD0[31:0], dbg_current_word_lo);
            $fatal(1);
        end

        wait (bit_count >= 8 * 8);
        wait (dbg_current_word_lo == WORD1[31:0]);

        if (dbg_underflows != 32'd0) begin
            $error("unexpected underflows during burst: %0d", dbg_underflows);
            $fatal(1);
        end

        if (dbg_emitted_bits < 32'd64) begin
            $error("expected at least 64 emitted bits before second word, got %0d",
                   dbg_emitted_bits);
            $fatal(1);
        end

        if (dbg_tx_samples_lo == 32'd0) begin
            $error("expected non-zero tx samples during burst");
            $fatal(1);
        end

        $display("PASS burst accepted=%0d emitted=%0d fifo=0x%08x first_lo=0x%08x second_lo=0x%08x tx_lo=0x%08x",
                 dbg_accepted_words, dbg_emitted_bits, dbg_fifo_state,
                 WORD0[31:0], dbg_current_word_lo, dbg_tx_samples_lo);
        $finish;
    end
endmodule