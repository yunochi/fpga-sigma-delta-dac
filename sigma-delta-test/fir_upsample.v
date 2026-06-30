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

    // 63-tap Half-Band filter (32 non-zero coefficients)
    reg signed [DATA_WIDTH-1:0] x_reg [0:31];

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

    // Coefficient Lookup Function
    function signed [15:0] get_coef(input [3:0] idx);
        begin
            case (idx)
                4'd0:  get_coef = -54;
                4'd1:  get_coef = 64;
                4'd2:  get_coef = -90;
                4'd3:  get_coef = 136;
                4'd4:  get_coef = -202;
                4'd5:  get_coef = 294;
                4'd6:  get_coef = -418;
                4'd7:  get_coef = 578;
                4'd8:  get_coef = -785;
                4'd9:  get_coef = 1053;
                4'd10: get_coef = -1411;
                4'd11: get_coef = 1908;
                4'd12: get_coef = -2654;
                4'd13: get_coef = 3937;
                4'd14: get_coef = -6818;
                4'd15: get_coef = 20846;
                default: get_coef = 0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------
    // Pipelined Serial MAC (Multiply-Accumulate)
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH:0] pre_add;
    reg signed [15:0] coef_reg;
    reg signed [DATA_WIDTH+16:0] mul_val;
    reg signed [DATA_WIDTH+20:0] accum;
    reg signed [DATA_WIDTH-1:0] even_out;

    // Cycle t: Pre-adder & Coefficient fetch (1-cycle delay)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_add <= 0;
            coef_reg <= 0;
        end else if (interval_cnt < 16) begin
            pre_add <= $signed(x_reg[interval_cnt[3:0]]) + $signed(x_reg[31 - interval_cnt[3:0]]);
            coef_reg <= get_coef(interval_cnt[3:0]);
        end
    end

    // Cycle t+1: Multiplier (1-cycle delay)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_val <= 0;
        end else if (interval_cnt >= 1 && interval_cnt <= 16) begin
            mul_val <= pre_add * coef_reg;
        end
    end

    // Cycle t+2: Accumulator and Even Output Register (1-cycle delay)
    wire signed [21:0] sum_shifted = accum >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum <= 0;
            even_out <= 0;
        end else begin
            if (interval_cnt == 2) begin
                accum <= mul_val;
            end else if (interval_cnt >= 3 && interval_cnt <= 17) begin
                accum <= accum + mul_val;
            end

            // Accumulation complete at the end of interval_cnt == 17 (meaning accum has final sum during 18).
            // Saturation logic is clocked at the transition from 18 to 19 (latency of 19 cycles total).
            if (interval_cnt == 18) begin
                if (sum_shifted > 32767)
                    even_out <= 32767;
                else if (sum_shifted < -32768)
                    even_out <= -32768;
                else
                    even_out <= sum_shifted[15:0];
            end
        end
    end

    // -------------------------------------------------------------
    // Center Tap Delay Pipeline (19-cycle latency matching even_out)
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] odd_delay [0:18];
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 19; k = k + 1) begin
                odd_delay[k] <= 0;
            end
        end else begin
            odd_delay[0] <= x_reg[15];
            for (k = 1; k < 19; k = k + 1) begin
                odd_delay[k] <= odd_delay[k-1];
            end
        end
    end
    wire signed [DATA_WIDTH-1:0] odd_pipe3 = odd_delay[18];

    // Output MUX (Output transitions are synchronous with 19-cycle latency)
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

