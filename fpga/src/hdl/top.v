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
  parameter OVERSAMPLE_RATIO = 128;

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
   reg signed [15:0] sample_wait_cnt;
   
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

   linear_interpolation #(
        .DATA_WIDTH(16),
        .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO)
    ) interpolation_l (
        .clk(sys_clk),
        .rst_n(reset_n),
        .data_in(axis_tdata[15:0]),
        .interval_cnt(sample_wait_cnt),
        .data_out(pdm_val_l)
   );
   
  linear_interpolation #(
        .DATA_WIDTH(16),
        .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO)
  ) interpolation_r (
        .clk(sys_clk),
        .rst_n(reset_n),
        .data_in(axis_tdata[31:16]),
        .interval_cnt(sample_wait_cnt),
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
