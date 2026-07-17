module i2s_rx #(
        parameter integer DATA_WIDTH = 16,
        parameter integer BCLK_DIV = 8
    ) (
        input wire clk,
        input wire rst_n,
        output reg sck,
        output reg ws,
        input wire sd,
        input wire tready,
        output wire [31:0] tdata,
        output wire data_valid,
        output wire data_act_led,
        output wire fifo_empty,
        output wire fifo_full,
        output wire [12:0] fifo_data_count
    );

    // ----------------- BCLK / WS 생성 ----------------------
    reg [7:0] clock_div_cnt;
    reg [7:0] ws_div_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            sck <= 0; ws <= 0;
            clock_div_cnt <= 0;
            ws_div_cnt <= 0;
        end
        else begin
            clock_div_cnt <= clock_div_cnt + 1;
            if (clock_div_cnt == (BCLK_DIV/2)-1) begin
                clock_div_cnt <= 0;
                sck <= !sck;
                // sck falling edge
                if (sck == 1) begin
                    ws_div_cnt <= ws_div_cnt + 1;
                    if (ws_div_cnt == DATA_WIDTH-1) begin
                        ws_div_cnt <= 0;
                        ws <= !ws;
                    end
                end
            end
        end
    end


    // ------------- input CDC 처리 ---------------------
    reg [1:0] sck_ff;
    reg [1:0] ws_ff;
    (* keep = "true" *) (* dont_touch = "true" *) reg [2:0] sd_ff;

    wire sck_rise_edge = (sck_ff[1] == 0 && sck_ff[0] == 1);
    wire sd_sync = sd_ff[2];
    wire ws_sync = ws_ff[1];
    reg data_act_reg;
    assign data_act_led = data_act_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            sck_ff <= 0; ws_ff <= 0; sd_ff <= 0;
        end
        else begin
            sck_ff <= {sck_ff[0], sck};
            ws_ff <= {ws_ff[0], ws};
            sd_ff <= {sd_ff[1:0], sd};
        end
    end
    // ------------- Data push ---------------------
    reg [DATA_WIDTH-1:0] data_left;
    reg [DATA_WIDTH-1:0] data_right;
    wire [(DATA_WIDTH*2)-1:0] data_left_right;
    assign data_left_right = {data_right, data_left};
    reg ws_sync_d;
    reg wvalid;
    wire frame_end = (ws_sync_d == 1 && ws_sync == 0);
    reg [4:0] data_cnt;
    always @(posedge clk) begin
        wvalid <= 0;
        if (!rst_n) begin
            ws_sync_d <= 0; data_left <= 0; data_right <= 0;
            data_cnt <= 5'd0;
        end
        else if (sck_rise_edge) begin
            ws_sync_d <= ws_sync;
            // 표준 i2s는 WS가 한 클럭 늦음
            if (ws_sync_d == 1'b0) begin
                // Left channel
                if (data_cnt < DATA_WIDTH) begin
                    data_left <= {data_left[DATA_WIDTH-2:0], sd_sync};
                    data_cnt <= data_cnt + 5'd1;
                end
            end
            else begin
                if (data_cnt < DATA_WIDTH) begin
                    data_right <= {data_right[DATA_WIDTH-2:0], sd_sync};
                    data_cnt <= data_cnt + 5'd1;
                end
            end
            if (ws_sync != ws_sync_d) begin
                // Left / Right 전환
                data_cnt <= 0;
            end
            if (frame_end) begin
                wvalid <= 1;
            end
        end
    end

    // -------------- LED -----------------------
    reg [10:0] data_led_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_led_cnt <= 0;
            data_act_reg <= 1;
        end
        else if (sck_rise_edge && frame_end) begin
            data_led_cnt <= data_led_cnt + 1;
            if (data_led_cnt == 0) begin
                data_act_reg <= ~data_act_reg;
            end
        end
    end

    fwft_fifo #(
                  .DATA_WIDTH(DATA_WIDTH*2),
                  .FIFO_DEPTH(256)
              ) i2s_fifo_inst (
                  .clk(clk),
                  .rstn(rst_n),
                  .wr_en(wvalid),
                  .rd_en(tready),
                  .data_in(data_left_right),
                  .data_out(tdata),
                  .empty(fifo_empty),
                  .valid(data_valid),
                  .full(fifo_full),
                  .data_count(fifo_data_count)
              );

endmodule
