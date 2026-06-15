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
        input wire [15:0] interval_cnt,
        output wire signed [DATA_WIDTH-1:0] data_out
    );

    reg signed [DATA_WIDTH + 16 -1:0] data_in_prev;
    reg signed [DATA_WIDTH + 16 -1:0] data_in_current;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in_prev <= 0;
            data_in_current <= 0;
        end
        else if (interval_cnt == OVERSAMPLING_RATIO - 1) begin
            data_in_prev <= data_in_current;
            data_in_current <= data_in <<< 8; // 256배 곱해서 정밀도 손실 최소화
        end
    end

    // 다시 256으로 나눠서 원래 범위로 복원
    assign data_out = (data_in_prev + ( (data_in_current - data_in_prev) * interval_cnt ) / OVERSAMPLING_RATIO) >>> 8;
endmodule

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

    // 15-tap Half-Band filter (8 non-zero coefficients)
    reg signed [DATA_WIDTH-1:0] x_reg [0:7];
    localparam signed [DATA_WIDTH-1:0] H_0_7 = -241;
    localparam signed [DATA_WIDTH-1:0] H_1_6 = 1064;
    localparam signed [DATA_WIDTH-1:0] H_2_5 = -4501;
    localparam signed [DATA_WIDTH-1:0] H_3_4 = 20062;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < 8; j = j + 1) begin
                x_reg[j] <= 0;
            end
        end
        else if (interval_cnt == 0) begin
            x_reg[0] <= data_in;
            for (j = 1; j < 8; j = j + 1) begin
                x_reg[j] <= x_reg[j-1];
            end
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 1: Symmetric Pre-Adder (DSP48 내장 Pre-Adder 유도)
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH:0] s0, s1, s2, s3; // 17-bit 이면 충분 (16+1)

    // Odd Path용 타이밍 동기화 지연 파이프라인
    reg signed [DATA_WIDTH-1:0] odd_pipe1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0;
            odd_pipe1 <= 0;
        end else begin
            s0 <= $signed(x_reg[0]) + $signed(x_reg[7]);
            s1 <= $signed(x_reg[1]) + $signed(x_reg[6]);
            s2 <= $signed(x_reg[2]) + $signed(x_reg[5]);
            s3 <= $signed(x_reg[3]) + $signed(x_reg[4]);

            odd_pipe1 <= x_reg[3]; // Even 연산 1단계 지연과 매칭
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 2: Multipliers (DSP48 내장 Multiplier 유도)
    // -------------------------------------------------------------
    // 17비트 * 16비트 계수 = 33비트 결과
    reg signed [DATA_WIDTH+16:0] m0, m1, m2, m3;
    reg signed [DATA_WIDTH-1:0]  odd_pipe2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m0 <= 0; m1 <= 0; m2 <= 0; m3 <= 0;
            odd_pipe2 <= 0;
        end else begin
            m0 <= s0 * H_0_7;
            m1 <= s1 * H_1_6;
            m2 <= s2 * H_2_5;
            m3 <= s3 * H_3_4;

            odd_pipe2 <= odd_pipe1; // Even 연산 2단계 지연과 매칭
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 3: Tree Accumulation & Slicing / Saturation
    // -------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] even_out;
    reg signed [DATA_WIDTH-1:0] odd_pipe3;

    wire signed [DATA_WIDTH+18:0] sum_tree; // 35비트 공간
    assign sum_tree = m0 + m1 + m2 + m3;

    wire signed [19:0] sum_shifted = sum_tree >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_out  <= 0;
            odd_pipe3 <= 0;
        end else begin
            // Saturation Logic
            if (sum_shifted > 32767)
                even_out <= 32767;
            else if (sum_shifted < -32768)
                even_out <= -32768;
            else
                even_out <= sum_shifted[15:0];

            odd_pipe3 <= odd_pipe2; // Even 연산 3단계 지연과 매칭
        end
    end

    // -------------------------------------------------------------
    // Pipeline Stage 4: Output MUX (Clean Registered Output)
    // -------------------------------------------------------------
    // 모든 연산 레이턴시(3클럭)가 완벽히 매칭된 정돈된 출력을 내보냅니다.
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

module testbench;
    `define USE_3RD_ORDER
    `define USE_FIR_UP_INTERPOLATION
    // `define USE_LINEAR_INTERPOLATION
    // `define USE_ZERO_ORDER_HOLD

    `ifdef USE_ZERO_ORDER_HOLD
    `define USE_OVERSAMPLING
    `elsif USE_LINEAR_INTERPOLATION
    `define USE_OVERSAMPLING
    `elsif USE_FIR_UP_INTERPOLATION
    `define USE_OVERSAMPLING
    `endif
    `ifdef USE_OVERSAMPLING
    parameter integer OVERSAMPLING_RATIO = 256;
    reg [15:0] data_interval_cnt;
    `endif
    `ifdef USE_FIR_UP_INTERPOLATION
    wire signed [15:0] data_val;
    `elsif USE_LINEAR_INTERPOLATION
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
    integer f_val;
    reg [31:0] cycle_cnt;

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


    `ifdef USE_FIR_UP_INTERPOLATION
    wire signed [15:0] fir_out;
    wire [15:0] interval_cnt_128 = data_interval_cnt[6:0];

    fir_upsampler_2x #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO)) upsampler (
                         .clk(clk),
                         .rst_n(rst_n),
                         .data_in(data_in),
                         .interval_cnt(data_interval_cnt),
                         .data_out(fir_out)
                     );

    linear_interpolation #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO / 2)) interpolator (
                             .clk(clk),
                             .rst_n(rst_n),
                             .data_in(fir_out),
                             .interval_cnt(interval_cnt_128),
                             .data_out(data_val)
                         );
    `elsif USE_LINEAR_INTERPOLATION
    linear_interpolation #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO)) interpolator (
                             .clk(clk),
                             .rst_n(rst_n),
                             .data_in(data_in),
                             .interval_cnt(data_interval_cnt),
                             .data_out(data_val)
                         );
    `endif

    real amplitude = 30000.0;

    // cycle_cnt generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt <= 0;
        end
        else begin
            cycle_cnt <= cycle_cnt + 1;
        end
    end

    // input generation
    `ifdef USE_OVERSAMPLING
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_interval_cnt <= OVERSAMPLING_RATIO - 1;
            data_in <= 0;
            `ifdef USE_ZERO_ORDER_HOLD
            data_val <= 0;
            `endif
        end
        else begin
            if (data_interval_cnt >= OVERSAMPLING_RATIO - 1) begin
                data_interval_cnt <= 0;
                data_in <= $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * cycle_cnt / FS_HZ));
                `ifdef USE_ZERO_ORDER_HOLD
                data_val <= $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * cycle_cnt / FS_HZ));
                `endif
            end
            else begin
                data_interval_cnt <= data_interval_cnt + 1;
            end
        end
    end
    `else
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in <= 0;
            data_val <= 0;
        end
        else begin
            data_in <= $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * cycle_cnt / FS_HZ));
            data_val <= $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * cycle_cnt / FS_HZ));
        end
    end
    `endif

    initial begin
        $display("--- Testbench Configuration (16-bit Input) ---");
        $display("Modulator Freq : %0d Hz (%0f MHz)", FS_HZ, (FS_HZ * 1.0) / 1000000);
        `ifdef USE_OVERSAMPLING
        $display("Oversampling Ratio : %0d", OVERSAMPLING_RATIO);
        $display("Data input rate : %0f Hz", (FS_HZ * 1.0) / OVERSAMPLING_RATIO);
        `ifdef USE_FIR_UP_INTERPOLATION
        $display("Interpolation Method : 2x FIR Upsampler + Linear");
        `elsif USE_LINEAR_INTERPOLATION
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
        #100 rst_n = 1;

        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            @(posedge clk);
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
