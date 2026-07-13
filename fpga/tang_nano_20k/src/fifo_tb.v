module fwft_fifo_tb();
    reg clk;
    reg [31:0]data_in;
    wire [31:0] data_out;
    reg wr_en;
    reg rd_en;
    wire empty;
    wire full;

    initial begin
        clk = 0;
        wr_en = 0;
        rd_en = 0;
        data_in = 0;
    end
    always #5 clk = ~clk;
    initial begin
        $dumpfile("fifo_tb.vcd");
        $dumpvars(0, fwft_fifo_tb);
        repeat (5) begin
            @(posedge clk);
        end;

        @(posedge clk) wr_en <= 1;
        repeat (9) begin
            @(posedge clk) begin
                 data_in <= data_in + 1;
             end;
        end;
        @(posedge clk) wr_en <= 0;
        repeat (5) begin
            @(posedge clk);
        end;
        @(posedge clk) rd_en <= 1;
        repeat (9) begin
            @(posedge clk);
        end;

        @(posedge clk) rd_en <= 0;
        repeat (5) begin
            @(posedge clk);
        end;
        @(posedge clk) begin
             data_in <= 0;
             wr_en <= 1;
             rd_en <= 1;
         end;
        repeat (9) begin
            @(posedge clk) begin
                 data_in <= data_in + 1;
             end;
        end;
        @(posedge clk) begin
             wr_en <= 0;
         end;
        @(posedge clk) begin
             rd_en <= 0;
         end;
        repeat (5) begin
            @(posedge clk);
        end

        $finish;
    end

    fwft_fifo #(
                  .DATA_WIDTH(32),
                  .FIFO_DEPTH(256)
              ) fifo_inst (
                  .clk(clk),
                  .wr_en(wr_en),
                  .rd_en(rd_en),
                  .data_in(data_in),
                  .data_out(data_out),
                  .empty(empty),
                  .full(full)
              );
endmodule
