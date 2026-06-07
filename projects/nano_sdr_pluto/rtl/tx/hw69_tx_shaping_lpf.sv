`timescale 1ns / 1ps

module hw69_tx_shaping_lpf #(
    parameter int unsigned DATA_WIDTH = 18,
    parameter int unsigned COEFF_WIDTH = 20,
    parameter int unsigned COEFF_FRAC_BITS = 18,
    parameter int unsigned NUM_TAPS = 129
) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic signed [DATA_WIDTH-1:0] data_in,
    output logic out_valid,
    output logic signed [DATA_WIDTH-1:0] data_out
);
    localparam int unsigned PRODUCT_WIDTH = DATA_WIDTH + COEFF_WIDTH;
    localparam int unsigned ACC_WIDTH = PRODUCT_WIDTH + $clog2(NUM_TAPS + 1);

    logic signed [DATA_WIDTH-1:0] delay_line [0:NUM_TAPS-2];

    function automatic logic signed [COEFF_WIDTH-1:0] coeff(input int unsigned index);
        unique case (index)
            0: coeff = 20'sd16;
            1: coeff = 20'sd22;
            2: coeff = 20'sd29;
            3: coeff = 20'sd37;
            4: coeff = 20'sd46;
            5: coeff = 20'sd57;
            6: coeff = 20'sd69;
            7: coeff = 20'sd83;
            8: coeff = 20'sd100;
            9: coeff = 20'sd119;
            10: coeff = 20'sd141;
            11: coeff = 20'sd167;
            12: coeff = 20'sd195;
            13: coeff = 20'sd228;
            14: coeff = 20'sd264;
            15: coeff = 20'sd304;
            16: coeff = 20'sd349;
            17: coeff = 20'sd398;
            18: coeff = 20'sd451;
            19: coeff = 20'sd510;
            20: coeff = 20'sd573;
            21: coeff = 20'sd641;
            22: coeff = 20'sd714;
            23: coeff = 20'sd792;
            24: coeff = 20'sd875;
            25: coeff = 20'sd963;
            26: coeff = 20'sd1055;
            27: coeff = 20'sd1153;
            28: coeff = 20'sd1255;
            29: coeff = 20'sd1361;
            30: coeff = 20'sd1471;
            31: coeff = 20'sd1585;
            32: coeff = 20'sd1703;
            33: coeff = 20'sd1824;
            34: coeff = 20'sd1948;
            35: coeff = 20'sd2074;
            36: coeff = 20'sd2203;
            37: coeff = 20'sd2333;
            38: coeff = 20'sd2464;
            39: coeff = 20'sd2597;
            40: coeff = 20'sd2730;
            41: coeff = 20'sd2862;
            42: coeff = 20'sd2994;
            43: coeff = 20'sd3125;
            44: coeff = 20'sd3254;
            45: coeff = 20'sd3381;
            46: coeff = 20'sd3505;
            47: coeff = 20'sd3626;
            48: coeff = 20'sd3743;
            49: coeff = 20'sd3856;
            50: coeff = 20'sd3964;
            51: coeff = 20'sd4067;
            52: coeff = 20'sd4165;
            53: coeff = 20'sd4256;
            54: coeff = 20'sd4341;
            55: coeff = 20'sd4419;
            56: coeff = 20'sd4490;
            57: coeff = 20'sd4553;
            58: coeff = 20'sd4608;
            59: coeff = 20'sd4656;
            60: coeff = 20'sd4695;
            61: coeff = 20'sd4725;
            62: coeff = 20'sd4747;
            63: coeff = 20'sd4760;
            64: coeff = 20'sd4765;
            65: coeff = 20'sd4760;
            66: coeff = 20'sd4747;
            67: coeff = 20'sd4725;
            68: coeff = 20'sd4695;
            69: coeff = 20'sd4656;
            70: coeff = 20'sd4608;
            71: coeff = 20'sd4553;
            72: coeff = 20'sd4490;
            73: coeff = 20'sd4419;
            74: coeff = 20'sd4341;
            75: coeff = 20'sd4256;
            76: coeff = 20'sd4165;
            77: coeff = 20'sd4067;
            78: coeff = 20'sd3964;
            79: coeff = 20'sd3856;
            80: coeff = 20'sd3743;
            81: coeff = 20'sd3626;
            82: coeff = 20'sd3505;
            83: coeff = 20'sd3381;
            84: coeff = 20'sd3254;
            85: coeff = 20'sd3125;
            86: coeff = 20'sd2994;
            87: coeff = 20'sd2862;
            88: coeff = 20'sd2730;
            89: coeff = 20'sd2597;
            90: coeff = 20'sd2464;
            91: coeff = 20'sd2333;
            92: coeff = 20'sd2203;
            93: coeff = 20'sd2074;
            94: coeff = 20'sd1948;
            95: coeff = 20'sd1824;
            96: coeff = 20'sd1703;
            97: coeff = 20'sd1585;
            98: coeff = 20'sd1471;
            99: coeff = 20'sd1361;
            100: coeff = 20'sd1255;
            101: coeff = 20'sd1153;
            102: coeff = 20'sd1055;
            103: coeff = 20'sd963;
            104: coeff = 20'sd875;
            105: coeff = 20'sd792;
            106: coeff = 20'sd714;
            107: coeff = 20'sd641;
            108: coeff = 20'sd573;
            109: coeff = 20'sd510;
            110: coeff = 20'sd451;
            111: coeff = 20'sd398;
            112: coeff = 20'sd349;
            113: coeff = 20'sd304;
            114: coeff = 20'sd264;
            115: coeff = 20'sd228;
            116: coeff = 20'sd195;
            117: coeff = 20'sd167;
            118: coeff = 20'sd141;
            119: coeff = 20'sd119;
            120: coeff = 20'sd100;
            121: coeff = 20'sd83;
            122: coeff = 20'sd69;
            123: coeff = 20'sd57;
            124: coeff = 20'sd46;
            125: coeff = 20'sd37;
            126: coeff = 20'sd29;
            127: coeff = 20'sd22;
            128: coeff = 20'sd16;
            default: coeff = '0;
        endcase
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] saturate(input logic signed [ACC_WIDTH-1:0] value);
        logic signed [DATA_WIDTH-1:0] max_value;
        logic signed [DATA_WIDTH-1:0] min_value;
        begin
            max_value = {1'b0, {(DATA_WIDTH - 1){1'b1}}};
            min_value = {1'b1, {(DATA_WIDTH - 1){1'b0}}};

            if (value > {{ACC_WIDTH-DATA_WIDTH{max_value[DATA_WIDTH-1]}}, max_value}) begin
                return max_value;
            end
            if (value < {{ACC_WIDTH-DATA_WIDTH{min_value[DATA_WIDTH-1]}}, min_value}) begin
                return min_value;
            end
            return value[DATA_WIDTH-1:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        logic signed [ACC_WIDTH-1:0] acc;
        logic signed [ACC_WIDTH-1:0] shifted;

        if (rst) begin
            out_valid <= 1'b0;
            data_out <= '0;
            for (int unsigned i = 0; i < NUM_TAPS - 1; i++) begin
                delay_line[i] <= '0;
            end
        end else begin
            out_valid <= in_valid;

            if (in_valid) begin
                acc = $signed(data_in) * $signed(coeff(0));
                for (int unsigned i = 1; i < NUM_TAPS; i++) begin
                    acc += $signed(delay_line[i - 1]) * $signed(coeff(i));
                end

                shifted = acc >>> COEFF_FRAC_BITS;
                data_out <= saturate(shifted);

                for (int unsigned i = NUM_TAPS - 2; i > 0; i--) begin
                    delay_line[i] <= delay_line[i - 1];
                end
                delay_line[0] <= data_in;
            end
        end
    end
endmodule