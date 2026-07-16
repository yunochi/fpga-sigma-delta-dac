`timescale 1ns / 1ps

module top(
        output pdm_out_l,
        output pdm_out_r,
        input sys_clk_in,
        input reset_in,
        input s_i2s_sck,
        input s_i2s_ws,
        input s_i2s_sd,
        output wire fifo_full_led,
        output wire fifo_empty_led,
        output wire data_act_led,
        output wire play_led
    );

    wire sys_clk; // 24.576 MHz clock
    wire pll_lock;
    wire reset_n;
    Gowin_rPLL gowin_rpll_inst(
                   .clkin(sys_clk_in), //input clkin
                   .reset(reset_in), //input reset
                   .lock(pll_lock), //output lock
                   .clkout(sys_clk) //output clkout
               );
    reset_sync sync_reset_inst(
                   .clk(sys_clk),
                   .i_nrst_async(pll_lock),
                   .o_rst_sync(),
                   .o_nrst_sync(reset_n)
               );

    wire fifo_full;
    wire fifo_empty;
    assign fifo_full_led = (reset_n == 0) ? 1 : !fifo_full;
    assign fifo_empty_led = (reset_n == 0) ? 1 : !fifo_empty;
    parameter OVERSAMPLE_RATIO = 256;

    wire [12:0] fifo_data_count;
    wire [31:0]axis_tdata;
    wire axis_tlast;
    reg axis_tready;
    wire axis_tvalid;

    i2s_rx i2s_rx_inst(
               .clk(sys_clk),
               .rst_n(reset_n),
               .sck(s_i2s_sck),
               .ws(s_i2s_ws),
               .sd(s_i2s_sd),
               .tready(axis_tready),
               .tdata(axis_tdata),
               .data_valid(axis_tvalid),
               .data_act_led(data_act_led),
               .fifo_empty(fifo_empty),
               .fifo_full(fifo_full),
               .fifo_data_count(fifo_data_count)
           );
    wire signed [15:0] pdm_val_l;
    wire signed [15:0] pdm_val_r;
    wire signed [15:0] fir_out_l_2x;
    wire signed [15:0] fir_out_l_4x;
    wire signed [15:0] fir_out_r_2x;
    wire signed [15:0] fir_out_r_4x;

    reg [15:0] sample_wait_cnt;
    reg [15:0] pcm_in_l;
    reg [15:0] pcm_in_r;

    reg play_started;
    assign play_led = !play_started;

    // TODO: flow control 기능 구현
    always @(posedge sys_clk) begin
        if (!reset_n) begin
            play_started <= 0;
        end
        else if (!play_started && fifo_data_count > 13'd1024) begin
            // 중간까지 FIFO가 차면 play 시작
            play_started <= 1;
        end
        else if (fifo_empty) begin
            // FIFO가 비면 play 정지
            play_started <= 0;
        end
    end

    always @(posedge sys_clk) begin
        if (!reset_n) begin
            axis_tready <= 0;
            sample_wait_cnt <= 0;
            pcm_in_l <= 0; pcm_in_r <= 0;
        end
        else begin
            if (!play_started) begin
                axis_tready <= 0;
                sample_wait_cnt <= 0;
            end
            else if (axis_tvalid && axis_tready) begin
                axis_tready <= 0;
                sample_wait_cnt <= 0;
                pcm_in_l <= axis_tdata[15:0];
                pcm_in_r <= axis_tdata[31:16];
            end
            else begin
                // 카운터가 끝에 도달할 때까지 증가 (데이터가 안 오면 OVERSAMPLE_RATIO-1 에서 유지)
                if (sample_wait_cnt < OVERSAMPLE_RATIO-1) begin
                    sample_wait_cnt <= sample_wait_cnt + 1;
                end
                if (sample_wait_cnt == OVERSAMPLE_RATIO-2) begin
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
                         .data_in(pcm_in_l),
                         .interval_cnt(sample_wait_cnt),
                         .data_out(fir_out_l_2x)
                     );
    linear_interpolation #(
                             .DATA_WIDTH(16),
                             .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 2)
                         ) interpolation_l (
                             .clk(sys_clk),
                             .rst_n(reset_n),
                             .data_in(fir_out_l_2x),
                             .interval_cnt(sample_wait_cnt),
                             .data_out(pdm_val_l)
                         );

    fir_upsampler_2x #(
                         .DATA_WIDTH(16),
                         .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO)
                     ) fir_r_2x (
                         .clk(sys_clk),
                         .rst_n(reset_n),
                         .data_in(pcm_in_r),
                         .interval_cnt(sample_wait_cnt),
                         .data_out(fir_out_r_2x)
                     );
    linear_interpolation #(
                             .DATA_WIDTH(16),
                             .OVERSAMPLING_RATIO(OVERSAMPLE_RATIO / 2)
                         ) interpolation_r (
                             .clk(sys_clk),
                             .rst_n(reset_n),
                             .data_in(fir_out_r_2x),
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


