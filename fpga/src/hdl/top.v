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

    // =========================================================================
    // Filter Architecture & Storage
    // =========================================================================
    // 63-tap symmetric Half-Band FIR filter.
    // Since it's a Half-Band filter, every odd tap (except the center tap) is zero.
    // Thus, we only need to store 32 input samples to compute the symmetric even samples.
    reg signed [DATA_WIDTH-1:0] x_reg [0:31];

    // Shift register for input samples.
    // Triggered at the beginning of a new input sample period (interval_cnt == 0).
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) begin
                x_reg[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (interval_cnt == 16'd0) begin
            x_reg[0] <= data_in;
            for (i = 1; i < 32; i = i + 1) begin
                x_reg[i] <= x_reg[i-1];
            end
        end
    end

    // 16 non-zero coefficients for the symmetric taps (left/right half).
    // Q15 fixed-point representation.
    function signed [15:0] get_coef(input [3:0] idx);
        begin
            case (idx)
                4'd0:  get_coef = -16'sd54;
                4'd1:  get_coef = 16'sd64;
                4'd2:  get_coef = -16'sd90;
                4'd3:  get_coef = 16'sd136;
                4'd4:  get_coef = -16'sd202;
                4'd5:  get_coef = 16'sd294;
                4'd6:  get_coef = -16'sd418;
                4'd7:  get_coef = 16'sd578;
                4'd8:  get_coef = -16'sd785;
                4'd9:  get_coef = 16'sd1053;
                4'd10: get_coef = -16'sd1411;
                4'd11: get_coef = 16'sd1908;
                4'd12: get_coef = -16'sd2654;
                4'd13: get_coef = 16'sd3937;
                4'd14: get_coef = -16'sd6818;
                4'd15: get_coef = 16'sd20846;
                default: get_coef = 16'sd0;
            endcase
        end
    endfunction

    // =========================================================================
    // Pipelined Serial MAC (Multiply-Accumulate) Control & Datapath
    // =========================================================================
    // The MAC unit computes the even sample using symmetric pre-addition.
    // 
    // Pipeline Timeline:
    // Cycle t   (interval_cnt 0 ~ 15)  : Pre-adder & Coefficient fetch
    // Cycle t+1 (interval_cnt 1 ~ 16)  : Multiplication
    // Cycle t+2 (interval_cnt 2 ~ 17)  : Accumulation (init on cycle 2)
    // Cycle t+3 (interval_cnt 18)      : Saturation and Registering even output

    // Pipeline Stage Enables
    wire preadd_en  = (interval_cnt < 16);
    wire mul_en     = (interval_cnt >= 1 && interval_cnt <= 16);
    wire accum_init = (interval_cnt == 2);
    wire accum_en   = (interval_cnt >= 3 && interval_cnt <= 17);
    wire out_en     = (interval_cnt == 18);

    // Datapath Registers
    reg signed [DATA_WIDTH:0]    pre_add;  // Pre-adder output (17 bits for 16-bit input)
    reg signed [15:0]            coef_reg; // Coefficient register
    reg signed [DATA_WIDTH+16:0] mul_val;  // Multiplier output (33 bits)
    reg signed [DATA_WIDTH+20:0] accum;    // Accumulator (adds 16 products, needs +4 bits headroom)
    reg signed [DATA_WIDTH-1:0]  even_out; // Registered even output sample

    // Cycle t: Pre-adder & Coefficient fetch (1-cycle latency)
    // Pre-adds symmetric input samples: x[idx] + x[31 - idx]
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_add  <= {(DATA_WIDTH+1){1'b0}};
            coef_reg <= 16'sd0;
        end else if (preadd_en) begin
            pre_add  <= $signed(x_reg[interval_cnt[3:0]]) + $signed(x_reg[31 - interval_cnt[3:0]]);
            coef_reg <= get_coef(interval_cnt[3:0]);
        end
    end

    // Cycle t+1: Multiplier (1-cycle latency)
    // Computes pre_add * coef_reg
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_val <= {(DATA_WIDTH+17){1'b0}};
        end else if (mul_en) begin
            mul_val <= pre_add * coef_reg;
        end
    end

    // Cycle t+2: Accumulator (1-cycle latency)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum <= {(DATA_WIDTH+21){1'b0}};
        end else begin
            if (accum_init) begin
                accum <= mul_val;
            end else if (accum_en) begin
                accum <= accum + mul_val;
            end
        end
    end

    // Cycle t+3: Saturation & Rounding (1-cycle latency)
    // The coefficients are in Q15 format, so we shift right by 15.
    // The accumulated sum is saturated to prevent overflow before assigning to 16-bit output.
    wire signed [21:0] sum_shifted = accum >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_out <= {DATA_WIDTH{1'b0}};
        end else if (out_en) begin
            if (sum_shifted > 32767) begin
                even_out <= 32767;
            end else if (sum_shifted < -32768) begin
                even_out <= -32768;
            end else begin
                even_out <= sum_shifted[15:0];
            end
        end
    end

    // =========================================================================
    // Center Tap Delay Pipeline
    // =========================================================================
    // For a half-band filter, the center tap is 0.5. To match the latency of the
    // even sample calculations (19 clock cycles), the center tap sample (x_reg[15])
    // must be delayed by exactly 19 clock cycles.
    reg signed [DATA_WIDTH-1:0] odd_delay [0:18];
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 19; k = k + 1) begin
                odd_delay[k] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            odd_delay[0] <= x_reg[15];
            for (k = 1; k < 19; k = k + 1) begin
                odd_delay[k] <= odd_delay[k-1];
            end
        end
    end

    wire signed [DATA_WIDTH-1:0] odd_out = odd_delay[18];

    // =========================================================================
    // Output Multiplexer (Even/Odd Interleaving)
    // =========================================================================
    // The output transitions are synchronized, resulting in a 2x upsampled stream.
    // 
    // - For the first half of the input sample period, output the even filter result.
    // - For the second half, output the delayed center-tap sample.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= {DATA_WIDTH{1'b0}};
        end else begin
            if (interval_cnt < (OVERSAMPLING_RATIO / 2)) begin
                data_out <= even_out;
            end else begin
                data_out <= odd_out;
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

