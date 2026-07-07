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
    wire [15:0] interval_cnt_mod = interval_cnt & (OVERSAMPLING_RATIO - 1);
    reg signed [DATA_WIDTH-1:0] data_in_prev;
    reg signed [DATA_WIDTH-1:0] data_in_current;
    always @(posedge clk) begin
        if (!rst_n) begin
            data_in_prev <= 0;
            data_in_current <= 0;
        end
        else if (interval_cnt_mod == OVERSAMPLING_RATIO - 1) begin
            data_in_prev <= data_in_current;
            data_in_current <= data_in;
        end
    end

    wire signed [31:0] interp = (data_in_current - data_in_prev) * $signed({1'b0, interval_cnt_mod});
    assign data_out = data_in_prev + (interp >>> $clog2(OVERSAMPLING_RATIO));
endmodule
