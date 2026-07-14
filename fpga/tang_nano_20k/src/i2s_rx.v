module i2s_rx #(
        parameter integer DATA_WIDTH = 16
    ) (
        input wire clk,
        input wire rst_n,
        input wire sck,
        input wire ws,
        input wire sd,
        input wire tready,
        output wire [31:0] tdata,
        output wire data_valid,
        output wire data_act_led,
        output wire fifo_empty,
        output wire fifo_full,
        output wire [12:0] fifo_data_count
    );


    // ------------- input CDC 처리 ---------------------
    (* keep = "true" *) (* dont_touch = "true" *) reg [3:0] sck_ff;
    (* keep = "true" *) (* dont_touch = "true" *) reg [3:0] ws_ff;
    (* keep = "true" *) (* dont_touch = "true" *) reg [3:0] sd_ff;

    wire sck_rise_edge = (sck_ff[3] == 0 && sck_ff[2] == 1);
    wire sd_sync = sd_ff[3];
    wire ws_sync = ws_ff[3];
    reg data_act_reg;
    assign data_act_led = data_act_reg;
    always @(posedge clk) begin
        if (!rst_n) begin
            sck_ff <= 0; ws_ff <= 0; sd_ff <= 0;
        end
        else begin
            sck_ff <= {sck_ff[2:0], sck};
            ws_ff <= {ws_ff[2:0], ws};
            sd_ff <= {sd_ff[2:0], sd};
        end
    end
    // ----------------------------------------------
    // ------------- Data push ---------------------
    reg [DATA_WIDTH-1:0] data_left;
    reg [DATA_WIDTH-1:0] data_right;
    wire [(DATA_WIDTH*2)-1:0] data_left_right;
    assign data_left_right = {data_right, data_left};
    reg ws_sync_d;
    reg wvalid;
    wire frame_end = (ws_sync_d == 1 && ws_sync == 0);
    reg [10:0] data_led_cnt;
    reg [4:0] data_cnt;
    always @(posedge clk) begin
        wvalid <= 0;
        if (!rst_n) begin
            ws_sync_d <= 0; data_left <= 0; data_right <= 0;
            data_act_reg <= 1; data_led_cnt <= 0;
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
                data_led_cnt <= data_led_cnt + 1;
                if (data_led_cnt == 11'd2047) begin
                    data_act_reg <= ~data_act_reg;
                end
            end
        end
    end


    fwft_fifo #(
                  .DATA_WIDTH(DATA_WIDTH*2),
                  .FIFO_DEPTH(4096)
              ) i2s_fifo_inst (
                  .clk(clk),
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
