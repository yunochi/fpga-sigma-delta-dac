`timescale 1ns / 1ps
`include "sigma-delta-3rd-order.v"
`include "sigma-delta-2nd-order.v"
`include "fir_upsample.v"
`include "linear_upsample.v"

// Synthesizable DUT wrapper for Verilator simulation.
// All testbench concerns (clock gen, stimulus, file I/O) live in the C++ tb.
module sim_dut #(
        parameter integer OVERSAMPLING_RATIO = 128
    ) (
        input wire clk,
        input wire rst_n,
        input wire signed [15:0] data_in,
        input wire [15:0] data_interval_cnt,
        output wire sdm_out
    );

    `ifdef USE_3RD_ORDER
    `else
    `endif

    wire signed [15:0] fir_out_2x;
    wire signed [15:0] fir_out_4x;
    wire [15:0] interval_cnt_div2 = data_interval_cnt & (OVERSAMPLING_RATIO / 2 - 1);
    wire [15:0] interval_cnt_div4 = data_interval_cnt & (OVERSAMPLING_RATIO / 4 - 1);
    wire signed [15:0] data_val;

    fir_upsampler_2x #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO)) upsampler_2x (
                         .clk(clk),
                         .rst_n(rst_n),
                         .data_in(data_in),
                         .interval_cnt(data_interval_cnt),
                         .data_out(fir_out_2x)
                     );
    fir_upsampler_2x #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO / 2)) upsampler_4x (
                         .clk(clk),
                         .rst_n(rst_n),
                         .data_in(fir_out_2x),
                         .interval_cnt(interval_cnt_div2),
                         .data_out(fir_out_4x)
                     );

    linear_interpolation #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO / 4)) interpolator (
                              .clk(clk),
                              .rst_n(rst_n),
                              .data_in(fir_out_4x),
                              .interval_cnt(interval_cnt_div4),
                              .data_out(data_val)
                          );

    sigma_delta_3rd_order #(.WIDTH(32)) uut (
                              .clk(clk),
                              .rst_n(rst_n),
                              .din(data_val),
                              .dout(sdm_out)
                          );
endmodule
