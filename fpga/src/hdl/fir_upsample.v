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


