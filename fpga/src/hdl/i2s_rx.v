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
        output wire prog_full,
        output wire prog_empty,
        output wire data_act_led
    );


    // ------------- input CDC 처리 ---------------------
    (* ASYNC_REG = "TRUE" *)
    reg [3:0] sck_ff;
    (* ASYNC_REG = "TRUE" *)
    reg [3:0] ws_ff;
    (* ASYNC_REG = "TRUE" *)
    reg [3:0] sd_ff;

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
    reg [31:0] data_shift_reg;
    reg last_ws;
    reg wvalid;
    wire frame_end = (last_ws == 1 && ws_sync == 0);
    reg [10:0] data_cnt;
    always @(posedge clk) begin
        wvalid <= 0;
        if (!rst_n) begin
            last_ws <= 0; data_shift_reg <= 0;
            data_act_reg <= 0; data_cnt <= 0;
        end
        else if (sck_rise_edge) begin
            last_ws <= ws_sync;
            data_shift_reg <= {data_shift_reg[30:0], sd_sync};
            if (frame_end) begin
                wvalid <= 1;
                data_cnt <= data_cnt + 1;
                if (data_cnt == 11'd2047) begin
                    data_act_reg <= ~data_act_reg;
                end
            end
        end
    end


     i2s_fifo i2s_fifo_inst (
                  .clk(clk),      // input wire clk
                  .srst(!rst_n),                // input wire srst
                  .din(data_shift_reg),      // input wire [31 : 0] din
                  .wr_en(wvalid),  // input wire wr_en
                  .rd_en(tready),  // input wire rd_en
                  .dout(tdata),    // output wire [31 : 0] dout
                  .full(),    // output wire full
                  .empty(),  // output wire empty
                  .valid(data_valid),
                  .prog_full(prog_full),      // output wire prog_full
                  .prog_empty(prog_empty)    // output wire prog_empty
              );
endmodule
