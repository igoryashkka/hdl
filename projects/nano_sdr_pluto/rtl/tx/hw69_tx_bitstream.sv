`timescale 1ns / 1ps

module hw69_tx_bitstream #(
    parameter int unsigned PREAMBLE_BYTES = 80,
    parameter int unsigned MAX_PACKETS = 100,
    parameter int unsigned PACKET_PERIOD_BITS = 9600,
    parameter int unsigned TAIL_GUARD_BITS = 24,
    parameter logic [8:0] PN9_SEED = 9'h1ff
) (
    input  logic clk,
    input  logic rst,
    input  logic bit_ce,
    input  logic enable,
    input  logic restart,
    output logic bit_valid,
    output logic tx_bit,
    output logic burst_gate,
    output logic packet_start,
    output logic packet_done,
    output logic tx_done,
    output logic [31:0] sent_count
);
    localparam int unsigned PREAMBLE_BITS = PREAMBLE_BYTES * 8;
    localparam int unsigned SYNC_BITS = 16;
    localparam int unsigned POST_SYNC_BITS = 16;
    localparam int unsigned PAYLOAD_BYTES = 14;
    localparam int unsigned PAYLOAD_BITS = PAYLOAD_BYTES * 8;
    localparam int unsigned FRAME_BITS = PREAMBLE_BITS + SYNC_BITS + POST_SYNC_BITS + PAYLOAD_BITS;
    localparam int unsigned IDLE_BITS = (PACKET_PERIOD_BITS > (FRAME_BITS + TAIL_GUARD_BITS))
        ? (PACKET_PERIOD_BITS - FRAME_BITS - TAIL_GUARD_BITS)
        : 0;

    typedef enum logic [2:0] {
        S_IDLE,
        S_PREAMBLE,
        S_SYNC,
        S_POST,
        S_PAYLOAD,
        S_TAIL,
        S_GAP
    } tx_state_t;

    tx_state_t state;
    logic [15:0] bit_index;
    logic [31:0] current_counter;
    logic [8:0] pn9_state;
    logic last_frame_bit;

    function automatic int unsigned counter_byte_count(input logic [31:0] counter);
        if (counter > 32'h00ff_ffff) begin
            return 4;
        end
        if (counter > 32'h0000_ffff) begin
            return 3;
        end
        if (counter > 32'h0000_00ff) begin
            return 2;
        end
        return 1;
    endfunction

    function automatic logic [7:0] payload_byte(
        input int unsigned byte_index,
        input logic [31:0] counter
    );
        int unsigned counter_bytes;

        counter_bytes = counter_byte_count(counter);

        unique case (byte_index)
            0: payload_byte = 8'h11;
            1: payload_byte = 8'h22;
            2: payload_byte = 8'h33;
            3: payload_byte = 8'h44;
            4: payload_byte = 8'h55;
            5: begin
                unique case (counter_bytes)
                    4: payload_byte = counter[31:24];
                    3: payload_byte = counter[23:16];
                    2: payload_byte = counter[15:8];
                    default: payload_byte = counter[7:0];
                endcase
            end
            6: begin
                unique case (counter_bytes)
                    4: payload_byte = counter[23:16];
                    3: payload_byte = counter[15:8];
                    2: payload_byte = counter[7:0];
                    default: payload_byte = 8'h88;
                endcase
            end
            7: begin
                unique case (counter_bytes)
                    4: payload_byte = counter[15:8];
                    3: payload_byte = counter[7:0];
                    default: payload_byte = 8'h88;
                endcase
            end
            8: begin
                if (counter_bytes == 4) begin
                    payload_byte = counter[7:0];
                end else begin
                    payload_byte = 8'h88;
                end
            end
            default: payload_byte = 8'h88;
        endcase
    endfunction

    function automatic logic payload_bit(
        input int unsigned payload_bit_index,
        input logic [31:0] counter
    );
        logic [7:0] value;
        int unsigned byte_index;
        int unsigned bit_in_byte;

        byte_index = payload_bit_index >> 3;
        bit_in_byte = 7 - (payload_bit_index & 3'h7);
        value = payload_byte(byte_index, counter);
        return value[bit_in_byte];
    endfunction

    function automatic logic word_bit(input logic [15:0] value, input int unsigned word_bit_index);
        return value[15 - word_bit_index];
    endfunction

    always_ff @(posedge clk) begin
        logic payload_raw_bit;
        logic whitened_bit;
        logic pn9_feedback;

        if (rst || restart) begin
            state <= S_IDLE;
            bit_index <= '0;
            current_counter <= '0;
            pn9_state <= PN9_SEED;
            last_frame_bit <= 1'b0;
            bit_valid <= 1'b0;
            tx_bit <= 1'b0;
            burst_gate <= 1'b0;
            packet_start <= 1'b0;
            packet_done <= 1'b0;
            tx_done <= 1'b0;
            sent_count <= '0;
        end else begin
            bit_valid <= 1'b0;
            packet_start <= 1'b0;
            packet_done <= 1'b0;
            tx_done <= (sent_count >= MAX_PACKETS) && (state == S_IDLE);

            if (bit_ce) begin
                bit_valid <= 1'b1;
                tx_bit <= 1'b0;
                burst_gate <= 1'b0;

                unique case (state)
                    S_IDLE: begin
                        if (enable && (sent_count < MAX_PACKETS)) begin
                            current_counter <= sent_count + 32'd1;
                            state <= S_PREAMBLE;
                            bit_index <= 16'd1;
                            pn9_state <= PN9_SEED;
                            tx_bit <= 1'b1;
                            last_frame_bit <= 1'b1;
                            burst_gate <= 1'b1;
                            packet_start <= 1'b1;
                        end
                    end

                    S_PREAMBLE: begin
                        tx_bit <= ~bit_index[0];
                        last_frame_bit <= ~bit_index[0];
                        burst_gate <= 1'b1;

                        if (bit_index == PREAMBLE_BITS - 1) begin
                            state <= S_SYNC;
                            bit_index <= '0;
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    S_SYNC: begin
                        tx_bit <= word_bit(16'h91d3, bit_index);
                        last_frame_bit <= word_bit(16'h91d3, bit_index);
                        burst_gate <= 1'b1;

                        if (bit_index == SYNC_BITS - 1) begin
                            state <= S_POST;
                            bit_index <= '0;
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    S_POST: begin
                        tx_bit <= word_bit(16'h2dd4, bit_index);
                        last_frame_bit <= word_bit(16'h2dd4, bit_index);
                        burst_gate <= 1'b1;

                        if (bit_index == POST_SYNC_BITS - 1) begin
                            state <= S_PAYLOAD;
                            bit_index <= '0;
                            pn9_state <= PN9_SEED;
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    S_PAYLOAD: begin
                        payload_raw_bit = payload_bit(bit_index, current_counter);
                        whitened_bit = payload_raw_bit ^ pn9_state[0];
                        pn9_feedback = pn9_state[0] ^ pn9_state[5];

                        tx_bit <= whitened_bit;
                        last_frame_bit <= whitened_bit;
                        burst_gate <= 1'b1;
                        pn9_state <= {pn9_feedback, pn9_state[8:1]};

                        if (bit_index == PAYLOAD_BITS - 1) begin
                            sent_count <= sent_count + 32'd1;
                            packet_done <= 1'b1;
                            bit_index <= '0;

                            if (TAIL_GUARD_BITS > 0) begin
                                state <= S_TAIL;
                            end else if (IDLE_BITS > 0) begin
                                state <= S_GAP;
                            end else begin
                                state <= S_IDLE;
                            end
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    S_TAIL: begin
                        tx_bit <= last_frame_bit;
                        burst_gate <= 1'b1;

                        if (bit_index == TAIL_GUARD_BITS - 1) begin
                            bit_index <= '0;
                            if (IDLE_BITS > 0) begin
                                state <= S_GAP;
                            end else begin
                                state <= S_IDLE;
                            end
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    S_GAP: begin
                        tx_bit <= 1'b0;
                        burst_gate <= 1'b0;

                        if (bit_index == IDLE_BITS - 1) begin
                            bit_index <= '0;
                            state <= S_IDLE;
                        end else begin
                            bit_index <= bit_index + 16'd1;
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                        bit_index <= '0;
                    end
                endcase
            end
        end
    end
endmodule
