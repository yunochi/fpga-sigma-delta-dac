`timescale 1ns / 1ps

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

module sigma_delta_2nd_order #(
        parameter integer WIDTH = 32
    ) (
        input wire clk,
        input wire rst_n,
        input wire [15:0] din,
        output reg dout
    );

    // Internal precision remains 32-bit for stability and high SNR head-room

    // Feedback and input are scaled to 16-bit signed range (max +/- 32767)
    localparam signed [WIDTH-1:0] POS_FB = 32767 <<< 8;
    localparam signed [WIDTH-1:0] NEG_FB = -32768 <<< 8;
    wire signed [WIDTH-1:0] signed_din;

    wire signed [WIDTH-1:0] fb;
    wire signed [WIDTH-1:0] integrator1_next;

    // Sign-extend 16-bit input to 32-bit internal width
    assign signed_din = $signed(din) <<< 8;
    reg signed [WIDTH-1:0] integrator1;
    reg signed [WIDTH-1:0] integrator2;

    // Input scaling (approx 0.8125)
    wire signed [WIDTH-1:0] reduced_din = (signed_din * 26) >>> 5;
    assign integrator1_next = integrator1 + (reduced_din - fb) / 2;

    assign fb = (dout == 1'b1) ? POS_FB : NEG_FB;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integrator1 <= 0;
            integrator2 <= 0;
            dout       <= 1'b0;
        end else begin
            integrator1 <= integrator1_next;
            integrator2 <= integrator2 + (integrator1_next / 2) - fb;

            dout <= (integrator2 >= 0) ? 1'b1 : 1'b0;
        end
    end
endmodule

module linear_interpolation #(
        parameter integer DATA_WIDTH = 16,
        parameter integer OVERSAMPLING_RATIO = 256
    ) (
        input wire clk,
        input wire rst_n,
        input wire signed [DATA_WIDTH-1:0] data_in,
        input wire signed [31:0] interval_cnt,
        output reg signed [DATA_WIDTH-1:0] data_out
    );

    reg signed [DATA_WIDTH + 16 -1:0] data_in_prev;
    reg signed [DATA_WIDTH + 16 -1:0] data_in_current;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 0;
            data_in_prev <= 0;
            data_in_current <= 0;
        end
        else if (interval_cnt == 0) begin
            data_in_prev <= data_in_current;
            data_in_current <= data_in <<< 8; // 256배 곱해서 정밀도 손실 최소화
        end

        // 다시 256으로 나눠서 원래 범위로 복원
        data_out = (data_in_prev + ( (data_in_current - data_in_prev) * interval_cnt ) / OVERSAMPLING_RATIO) >>> 8;
    end
endmodule

module testbench;
    `define USE_3RD_ORDER
    // `define USE_LINEAR_INTERPOLATION
    // `define USE_ZERO_ORDER_HOLD

    `ifdef USE_ZERO_ORDER_HOLD
    `define USE_OVERSAMPLING
    `elsif USE_LINEAR_INTERPOLATION
    `define USE_OVERSAMPLING
    `endif
    `ifdef USE_OVERSAMPLING
    parameter integer OVERSAMPLING_RATIO = 256;
    integer data_interval_cnt;
    `endif
    `ifdef USE_LINEAR_INTERPOLATION
    wire signed [15:0] data_val;
    `else
    reg signed [15:0] data_val;
    `endif

    reg clk;
    reg rst_n;
    wire sdm_out;
    reg signed [15:0] data_in;

    // Logic for modulator sampling frequency
    parameter integer FS_HZ = 1_000_000;

    // Target frequency resolution (Hz)
    parameter integer TARGET_RES = 5;

    // Auto-calculate samples N
    localparam integer N_SAMPLES = 1 << $clog2(FS_HZ / TARGET_RES);
    parameter real TARGET_F0 = 1000.0;
    parameter integer INTEGRATOR_WIDTH = 32;
    real PI = 3.14159265;
    integer i;
    integer f;

    `ifdef USE_3RD_ORDER
    sigma_delta_3rd_order #(.WIDTH(INTEGRATOR_WIDTH)) uut (
                              .clk(clk),
                              .rst_n(rst_n),
                              .din(data_val),
                              .dout(sdm_out)
                          );
    `else
    sigma_delta_2nd_order #(.WIDTH(INTEGRATOR_WIDTH)) uut (
                              .clk(clk),
                              .rst_n(rst_n),
                              .din(data_val),
                              .dout(sdm_out)
                          );

    `endif

    // Simple simulation clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Instability / Overflow Monitor
    // Check if any integrator exceeds 80% of the signed range
    localparam signed [INTEGRATOR_WIDTH-1:0] DANGER_THRESHOLD = ( (64'd1 << (INTEGRATOR_WIDTH-2)) * 8 ) / 5;
    localparam signed I32_MAX = 32'h7FFFFFFF;
    localparam signed I32_MIN = 32'h80000000;
    integer integrator1_min, integrator1_max;
    integer integrator2_min, integrator2_max;
    integer integrator3_min, integrator3_max;
    initial begin
        integrator1_min = I32_MAX;
        integrator2_min = I32_MAX;
        integrator3_min = I32_MAX;
        integrator1_max = I32_MIN;
        integrator2_max = I32_MIN;
        integrator3_max = I32_MIN;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (uut.integrator1 > integrator1_max) integrator1_max  = uut.integrator1;
            if (uut.integrator2 > integrator2_max) integrator2_max  = uut.integrator2;
            if (uut.integrator1 < integrator1_min) integrator1_min  = uut.integrator1;
            if (uut.integrator2 < integrator2_min) integrator2_min  = uut.integrator2;
            `ifdef USE_3RD_ORDER
            if (uut.integrator3 > integrator3_max) integrator3_max  = uut.integrator3;
            if (uut.integrator3 < integrator3_min) integrator3_min  = uut.integrator3;
            `endif

            if (uut.integrator1 > DANGER_THRESHOLD || uut.integrator1 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 1 nearing overflow! Value: %d", uut.integrator1);
            if (uut.integrator2 > DANGER_THRESHOLD || uut.integrator2 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 2 nearing overflow! Value: %d", uut.integrator2);
            `ifdef USE_3RD_ORDER
            if (uut.integrator3 > DANGER_THRESHOLD || uut.integrator3 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 3 nearing overflow! Value: %d", uut.integrator3);
            `endif
        end
    end


    `ifdef USE_LINEAR_INTERPOLATION
    linear_interpolation #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO)) interpolator (
                             .clk(clk),
                             .rst_n(rst_n),
                             .data_in(data_in),
                             .interval_cnt(data_interval_cnt),
                             .data_out(data_val)
                         );
    `endif

    real amplitude = 32767.0;
    initial begin
        $display("--- Testbench Configuration (16-bit Input) ---");
        $display("Modulator Freq : %0d Hz (%0f MHz)", FS_HZ, (FS_HZ * 1.0) / 1000000);
        `ifdef USE_OVERSAMPLING
        $display("Oversampling Ratio : %0d", OVERSAMPLING_RATIO);
        $display("Data input rate : %0f Hz", (FS_HZ * 1.0) / OVERSAMPLING_RATIO);
        `ifdef USE_LINEAR_INTERPOLATION
        $display("Interpolation Method : Linear");
        `elsif USE_ZERO_ORDER_HOLD
        $display("Interpolation Method : Zero-Order Hold");
        `endif
        `endif
        `ifdef USE_3RD_ORDER
        $display("Using 3rd-order Sigma-Delta Modulator");
        `else
        $display("Using 2nd-order Sigma-Delta Modulator");
        `endif
        $display("Target F0      : %0f Hz", TARGET_F0);
        $display("Target Frequency Resolution : %0d Hz", TARGET_RES);
        $display("Actual Res     : %0f Hz", (FS_HZ * 1.0) / N_SAMPLES);
        $display("Auto Samples   : %0d (2^%0d)", N_SAMPLES, $clog2(N_SAMPLES));
        $display("-------------------------------");

        // $dumpfile("wave.vcd"); // 1. VCD 파일 이름 지정
        // $dumpvars(0, uut);     // 2. 덤프할 모듈 및 범위 설정

        f = $fopen("dout.txt", "w");
        rst_n = 0;
        data_in = 0;
        `ifdef USE_OVERSAMPLING
        data_interval_cnt = OVERSAMPLING_RATIO - 1; // 첫 샘플에서 바로 데이터 갱신하도록 초기화
        `endif

        #100 rst_n = 1;

        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            `ifdef USE_LINEAR_INTERPOLATION
            // 선형 보간
            if (data_interval_cnt >= OVERSAMPLING_RATIO - 1) begin
                data_interval_cnt = 0;
                // 16-bit amplitude (max 32767)
                data_in = $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * i / FS_HZ));
            end
            `elsif USE_ZERO_ORDER_HOLD
            // 0차 홀드
            if (data_interval_cnt >= OVERSAMPLING_RATIO - 1) begin
                data_interval_cnt = 0;
                // 16-bit amplitude (max 32767)
                data_in = $rtoi(amplitude* $sin(2.0 * PI * TARGET_F0 * i / FS_HZ));
                data_val = data_in; // ZOH 입력으로 직접 전달
            end
            `else
            // 이상적 sine 입력 (매 샘플마다 갱신)
            // 16-bit amplitude (max 32767)
            data_in = $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * i / FS_HZ));
            data_val = data_in;
            `endif

            @(posedge clk);

            `ifdef USE_OVERSAMPLING
            data_interval_cnt = data_interval_cnt + 1;
            `endif
        end
        $display("int1 min: %d, max: %d", integrator1_min, integrator1_max);
        $display("int2 min: %d, max: %d", integrator2_min, integrator2_max);
        $display("int3 min: %d (%f %%), max: %d (%f %%)", integrator3_min, (integrator3_min * 100.0) / I32_MIN, integrator3_max, (integrator3_max * 100.0) / I32_MAX);
        $display("-------------------------------");
        $fclose(f);
        $display("Simulation Finished: %0d samples saved to dout.txt", N_SAMPLES);
        $finish;
    end

    // 파일 출력 (동기화)
    always @(posedge clk) begin
        if (rst_n) begin
            $fwrite(f, "%b\n", sdm_out);
        end
    end

endmodule
