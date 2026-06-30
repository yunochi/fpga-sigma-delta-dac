`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 05/28/2026 10:24:06 AM
// Design Name:
// Module Name: top
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module top(
        output pdm_out_l,
        output pdm_out_r,
        input clk_200M_p,
        input clk_200M_n
    );
    wire diff_buf_out;
    IBUFDS IBUFDS_inst (
               .O(diff_buf_out),
               .I(clk_200M_p),
               .IB(clk_200M_n)
           );
    wire clk_200M;
    BUFG BUFG_inst (
             .O(clk_200M), // 1-bit output: Clock output.
             .I(diff_buf_out)  // 1-bit input: Clock input.
         );

    wire sys_clk; //12.288MHz Clock
    parameter OVERSAMPLE_RATIO = 256;

    wire reset_n;
    wire [31:0]axis_tdata;
    wire axis_tlast;
    reg axis_tready;
    wire axis_tvalid;
    design_1_wrapper design_1_wrapper_inst (
                         .clk_200M(clk_200M),
                         .sys_clk(sys_clk),
                         .reset_n(reset_n),
                         .M_AXIS_0_tdata(axis_tdata),
                         .M_AXIS_0_tlast(axis_tlast),
                         .M_AXIS_0_tready(axis_tready),
                         .M_AXIS_0_tvalid(axis_tvalid)
                     );

    wire signed [15:0] pdm_val_l;
    wire signed [15:0] pdm_val_r;
    wire signed [15:0] fir_out_l_2x;
    wire signed [15:0] fir_out_l_4x;
    wire signed [15:0] fir_out_r_2x;
    wire signed [15:0] fir_out_r_4x;

    reg signed [15:0] sample_wait_cnt;
    wire [15:0] wait_cnt_128 = sample_wait_cnt[6:0];
    wire [15:0] wait_cnt_64 = sample_wait_cnt[5:0];
    wire [15:0] wait_cnt_32 = sample_wait_cnt[4:0];


    always @(posedge sys_clk) begin
        if (!reset_n) begin
            axis_tready <= 0;
            sample_wait_cnt <= 0;
        end
        else begin
            if (axis_tvalid && axis_tready) begin
                axis_tready <= 0;
                sample_wait_cnt <= 0;
            end
            else begin
                // 카운터가 끝에 끝에 도달할 때까지 증가 (데이터가 안 오면 OVERSAMPLE_RATIO-1 에서 유지)
                if (sample_wait_cnt < OVERSAMPLE_RATIO-1) begin
                    sample_wait_cnt <= sample_wait_cnt + 1;
                end
                if (sample_wait_cnt >= OVERSAMPLE_RATIO-2) begin // 12.288MHz / 128 =  96kHz
                    // 다음 클럭에 새 데이터 캡쳐하기 위해 미리 tready 를 1로 설정
                    axis_tready <= 1;
                end
            end
        end
    end
    fir_upsampler_2x #(
                         .DATA_WIDTH(16),
                         .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO)
                     ) fir_l_2x (
                         .clk(sys_clk),
                         .rst_n(reset_n),
                         .data_in(axis_tdata[15:0]),
                         .interval_cnt(sample_wait_cnt),
                         .data_out(fir_out_l_2x)
                     );
    fir_upsampler_2x #(
                         .DATA_WIDTH(16),
                         .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 2)
                     ) fir_l_4x (
                         .clk(sys_clk),
                         .rst_n(reset_n),
                         .data_in(fir_out_l_2x),
                         .interval_cnt(wait_cnt_128),
                         .data_out(fir_out_l_4x)
                     );
    linear_interpolation #(
                             .DATA_WIDTH(16),
                             .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 4)
                         ) interpolation_l (
                             .clk(sys_clk),
                             .rst_n(reset_n),
                             .data_in(fir_out_l_4x),
                             .interval_cnt(wait_cnt_64),
                             .data_out(pdm_val_l)
                         );

    fir_upsampler_2x #(
                         .DATA_WIDTH(16),
                         .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO)
                     ) fir_r_2x (
                         .clk(sys_clk),
                         .rst_n(reset_n),
                         .data_in(axis_tdata[31:16]),
                         .interval_cnt(sample_wait_cnt),
                         .data_out(fir_out_r_2x)
                     );
    fir_upsampler_2x #(
                         .DATA_WIDTH(16),
                         .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 2)
                     ) fir_r_4x (
                         .clk(sys_clk),
                         .rst_n(reset_n),
                         .data_in(fir_out_r_2x),
                         .interval_cnt(wait_cnt_128),
                         .data_out(fir_out_r_4x)
                     );
    linear_interpolation #(
                             .DATA_WIDTH(16),
                             .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 4)
                         ) interpolation_r (
                             .clk(sys_clk),
                             .rst_n(reset_n),
                             .data_in(fir_out_r_4x),
                             .interval_cnt(wait_cnt_64),
                             .data_out(pdm_val_r)
                         );

    sigma_delta_3rd_order sg_inst_l (
                              .clk(sys_clk),
                              .rst_n(reset_n),
                              .din(pdm_val_l),
                              .dout(pdm_out_l)
                          );
    sigma_delta_3rd_order sg_inst_r (
                              .clk(sys_clk),
                              .rst_n(reset_n),
                              .din(pdm_val_r),
                              .dout(pdm_out_r)
                          );

endmodule


module fir_upsampler_2x #(
        parameter integer DATA_WIDTH = 16,
        parameter integer OVERSAMPLING_RATIO = 256
    ) (
        input wire clk,
        input wire rst_n,
        input wire signed [DATA_WIDTH-1:0] data_in,
        input wire [15:0] interval_cnt,
        output reg signed [DATA_WIDTH-1:0] data_out
    );

    // 63-tap Half-Band filter (32 non-zero coefficients, symmetric pre-adder reduces to 16 multipliers)
    reg signed [DATA_WIDTH-1:0] x_reg [0:31];
    localparam signed [DATA_WIDTH-1:0] H0_31 = -54;
    localparam signed [DATA_WIDTH-1:0] H1_30 = 64;
    localparam signed [DATA_WIDTH-1:0] H2_29 = -90;
    localparam signed [DATA_WIDTH-1:0] H3_28 = 136;
    localparam signed [DATA_WIDTH-1:0] H4_27 = -202;
    localparam signed [DATA_WIDTH-1:0] H5_26 = 294;
    localparam signed [DATA_WIDTH-1:0] H6_25 = -418;
    localparam signed [DATA_WIDTH-1:0] H7_24 = 578;
    localparam signed [DATA_WIDTH-1:0] H8_23 = -785;
    localparam signed [DATA_WIDTH-1:0] H9_22 = 1053;
    localparam signed [DATA_WIDTH-1:0] H10_21 = -1411;
    localparam signed [DATA_WIDTH-1:0] H11_20 = 1908;
    localparam signed [DATA_WIDTH-1:0] H12_19 = -2654;
    localparam signed [DATA_WIDTH-1:0] H13_18 = 3937;
    localparam signed [DATA_WIDTH-1:0] H14_17 = -6818;
    localparam signed [DATA_WIDTH-1:0] H15_16 = 20846;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < 32; j = j + 1) begin
                x_reg[j] <= 0;
            end
        end
        else if (interval_cnt == 0) begin
            x_reg[0] <= data_in;
            for (j = 1; j < 32; j = j + 1) begin
                x_reg[j] <= x_reg[j-1];
            end
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 1: Symmetric Pre-Adder
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH:0] s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15;

    // Odd Path용 타이밍 동기화 지연 파이프라인
    reg signed [DATA_WIDTH-1:0] odd_pipe1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0;
            s4 <= 0; s5 <= 0; s6 <= 0; s7 <= 0;
            s8 <= 0; s9 <= 0; s10 <= 0; s11 <= 0;
            s12 <= 0; s13 <= 0; s14 <= 0; s15 <= 0;
            odd_pipe1 <= 0;
        end else begin
            s0  <= $signed(x_reg[0])  + $signed(x_reg[31]);
            s1  <= $signed(x_reg[1])  + $signed(x_reg[30]);
            s2  <= $signed(x_reg[2])  + $signed(x_reg[29]);
            s3  <= $signed(x_reg[3])  + $signed(x_reg[28]);
            s4  <= $signed(x_reg[4])  + $signed(x_reg[27]);
            s5  <= $signed(x_reg[5])  + $signed(x_reg[26]);
            s6  <= $signed(x_reg[6])  + $signed(x_reg[25]);
            s7  <= $signed(x_reg[7])  + $signed(x_reg[24]);
            s8  <= $signed(x_reg[8])  + $signed(x_reg[23]);
            s9  <= $signed(x_reg[9])  + $signed(x_reg[22]);
            s10 <= $signed(x_reg[10]) + $signed(x_reg[21]);
            s11 <= $signed(x_reg[11]) + $signed(x_reg[20]);
            s12 <= $signed(x_reg[12]) + $signed(x_reg[19]);
            s13 <= $signed(x_reg[13]) + $signed(x_reg[18]);
            s14 <= $signed(x_reg[14]) + $signed(x_reg[17]);
            s15 <= $signed(x_reg[15]) + $signed(x_reg[16]);

            odd_pipe1 <= x_reg[15];
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 2: Multipliers
    // -------------------------------------------------------------
    // 17비트 * 16비트 계수 = 33비트 결과
    reg signed [DATA_WIDTH+16:0] m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15;
    reg signed [DATA_WIDTH-1:0]  odd_pipe2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m0 <= 0; m1 <= 0; m2 <= 0; m3 <= 0;
            m4 <= 0; m5 <= 0; m6 <= 0; m7 <= 0;
            m8 <= 0; m9 <= 0; m10 <= 0; m11 <= 0;
            m12 <= 0; m13 <= 0; m14 <= 0; m15 <= 0;
            odd_pipe2 <= 0;
        end else begin
            m0  <= s0  * H0_31;
            m1  <= s1  * H1_30;
            m2  <= s2  * H2_29;
            m3  <= s3  * H3_28;
            m4  <= s4  * H4_27;
            m5  <= s5  * H5_26;
            m6  <= s6  * H6_25;
            m7  <= s7  * H7_24;
            m8  <= s8  * H8_23;
            m9  <= s9  * H9_22;
            m10 <= s10 * H10_21;
            m11 <= s11 * H11_20;
            m12 <= s12 * H12_19;
            m13 <= s13 * H13_18;
            m14 <= s14 * H14_17;
            m15 <= s15 * H15_16;

            odd_pipe2 <= odd_pipe1;
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 3: Tree Accumulation & Slicing / Saturation
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] even_out;
    reg signed [DATA_WIDTH-1:0] odd_pipe3;

    wire signed [DATA_WIDTH+20:0] sum_tree; // 37비트 공간
    assign sum_tree = m0 + m1 + m2 + m3 + m4 + m5 + m6 + m7 + m8 + m9 + m10 + m11 + m12 + m13 + m14 + m15;

    wire signed [21:0] sum_shifted = sum_tree >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_out  <= 0;
            odd_pipe3 <= 0;
        end else begin
            // Saturation Logic
            if (sum_shifted > 32767)
                even_out <= 32767;
            else if (sum_shifted < -32768)
                even_out <= -32768;
            else
                even_out <= sum_shifted[15:0];

            odd_pipe3 <= odd_pipe2;
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 4: Output MUX
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 0;
        end else begin
            if (interval_cnt < (OVERSAMPLING_RATIO / 2)) begin
                data_out <= even_out;
            end
            else begin
                data_out <= odd_pipe3;
            end
        end
    end
endmodule


module linear_interpolation #(
        parameter integer DATA_WIDTH = 16,
        parameter integer OVERSAMPLING_RATIO = 256
    ) (
        input wire clk,
        input wire rst_n,
        input wire signed [DATA_WIDTH-1:0] data_in,
        input wire [15:0] interval_cnt,
        output wire signed [DATA_WIDTH-1:0] data_out
    );

    reg signed [DATA_WIDTH + 16 -1:0] data_in_prev;
    reg signed [DATA_WIDTH + 16 -1:0] data_in_current;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in_prev <= 0;
            data_in_current <= 0;
        end
        else if (interval_cnt == OVERSAMPLING_RATIO - 1) begin
            data_in_prev <= data_in_current;
            data_in_current <= data_in <<< 8; // 256배 곱해서 정밀도 손실 최소화
        end
    end

    // 다시 256으로 나눠서 원래 범위로 복원
    assign data_out = (data_in_prev + ( (data_in_current - data_in_prev) * interval_cnt ) / OVERSAMPLING_RATIO) >>> 8;
endmodule

module sigma_delta_3rd_order #(
        parameter integer WIDTH = 32
    ) (
        input wire clk,
        input wire rst_n,
        input wire [15:0] din,
        output reg dout
    );

    localparam signed [WIDTH-1:0] POS_FB = 32767 <<< 8;
    localparam signed [WIDTH-1:0] NEG_FB = -32768 <<< 8;

    wire signed [WIDTH-1:0] signed_din;
    wire signed [WIDTH-1:0] fb;
    wire signed [WIDTH-1:0] error;

    assign signed_din = $signed(din) <<< 8;

    reg signed [WIDTH-1:0] integrator1;
    reg signed [WIDTH-1:0] integrator2;
    reg signed [WIDTH-1:0] integrator3;

    // Input scaling (approx 0.8125)
    wire signed [WIDTH-1:0] reduced_din = (signed_din * 26) >>> 5;

    assign fb = (dout == 1'b1) ? POS_FB : NEG_FB;
    assign error = reduced_din - fb;

    // CIFF Feed-forward Summation
    // Using a wider bit-width to prevent overflow during addition
    wire signed [WIDTH+2:0] sum = (integrator1 >>> 0) + (integrator2 >>> 2) + (integrator3 >>> 4) + (integrator3 >>> 6);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integrator1 <= 0;
            integrator2 <= 0;
            integrator3 <= 0;
            dout       <= 1'b0;
        end
        else begin
            integrator1 <= integrator1 + error;
            integrator2 <= integrator2 + (integrator1 >>> 1);
            integrator3 <= integrator3 + (integrator2 >>> 2);

            dout <= (sum >= 0) ? 1'b1 : 1'b0;
        end
    end
endmodule

