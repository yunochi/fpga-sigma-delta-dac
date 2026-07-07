`timescale 1ns / 1ps
`include "sigma-delta-3rd-order.v"
`include "fir_upsample.v"
`include "linear_upsample.v"

module testbench;
    parameter integer OVERSAMPLING_RATIO = 256;
    parameter integer FS_HZ = 1_000_000;
    parameter integer TARGET_RES = 5;
    parameter real TARGET_F0 = 1000.0;
    parameter integer INTEGRATOR_WIDTH = 32;

    localparam integer N_SAMPLES = 1 << $clog2(FS_HZ / TARGET_RES);

    reg clk;
    reg rst_n;
    wire sdm_out;
    reg signed [15:0] data_in;
    reg [15:0] data_interval_cnt;
    reg [31:0] cycle_cnt;
    wire signed [15:0] data_val;

    real PI = 3.14159265;
    real amplitude = 30000.0;
    integer i;
    integer f;

    // -------------------------------------------------------------------------
    // DUT: 2x FIR + 2x FIR + Linear interpolation -> 3rd-order Sigma-Delta
    // -------------------------------------------------------------------------
    wire signed [15:0] fir_out_2x;
    wire signed [15:0] fir_out_4x;

    fir_upsampler_2x #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO)) upsampler_2x (
                         .clk(clk),
                         .rst_n(rst_n),
                         .data_in(data_in),
                         .interval_cnt(data_interval_cnt),
                         .data_out(fir_out_2x)
                     );
    fir_upsampler_2x #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO / 2)) upsampler_4x (
                         .clk(clk),
                         .rst_n(rst_n),
                         .data_in(fir_out_2x),
                         .interval_cnt(data_interval_cnt),
                         .data_out(fir_out_4x)
                     );
    linear_interpolation #(.DATA_WIDTH(16), .OVERSAMPLING_RATIO(OVERSAMPLING_RATIO / 4)) interpolator (
                              .clk(clk),
                              .rst_n(rst_n),
                              .data_in(fir_out_4x),
                              .interval_cnt(data_interval_cnt),
                              .data_out(data_val)
                          );
    sigma_delta_3rd_order #(.WIDTH(INTEGRATOR_WIDTH)) uut (
                              .clk(clk),
                              .rst_n(rst_n),
                              .din(data_val),
                              .dout(sdm_out)
                          );

    // Simple simulation clock
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Instability / Overflow Monitor
    // Checks if any integrator exceeds 80% of the signed range.
    // -------------------------------------------------------------------------
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
            if (uut.integrator1 > integrator1_max) integrator1_max = uut.integrator1;
            if (uut.integrator2 > integrator2_max) integrator2_max = uut.integrator2;
            if (uut.integrator3 > integrator3_max) integrator3_max = uut.integrator3;
            if (uut.integrator1 < integrator1_min) integrator1_min = uut.integrator1;
            if (uut.integrator2 < integrator2_min) integrator2_min = uut.integrator2;
            if (uut.integrator3 < integrator3_min) integrator3_min = uut.integrator3;

            if (uut.integrator1 > DANGER_THRESHOLD || uut.integrator1 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 1 nearing overflow! Value: %d", uut.integrator1);
            if (uut.integrator2 > DANGER_THRESHOLD || uut.integrator2 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 2 nearing overflow! Value: %d", uut.integrator2);
            if (uut.integrator3 > DANGER_THRESHOLD || uut.integrator3 < -DANGER_THRESHOLD)
                $display("WARNING: Integrator 3 nearing overflow! Value: %d", uut.integrator3);
        end
    end

    // -------------------------------------------------------------------------
    // cycle_cnt generation
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt <= 0;
        end
        else begin
            cycle_cnt <= cycle_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Input generation
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_interval_cnt <= OVERSAMPLING_RATIO - 1;
            data_in <= 0;
        end
        else begin
            if (data_interval_cnt >= OVERSAMPLING_RATIO - 1) begin
                data_interval_cnt <= 0;
                data_in <= $rtoi(amplitude * $sin(2.0 * PI * TARGET_F0 * cycle_cnt / FS_HZ));
            end
            else begin
                data_interval_cnt <= data_interval_cnt + 1;
            end
        end
    end

    initial begin
        $display("--- Testbench Configuration (16-bit Input) ---");
        $display("Modulator Freq : %0d Hz (%0f MHz)", FS_HZ, (FS_HZ * 1.0) / 1000000);
        $display("Oversampling Ratio : %0d", OVERSAMPLING_RATIO);
        $display("Data input rate : %0f Hz", (FS_HZ * 1.0) / OVERSAMPLING_RATIO);
        $display("Interpolation Method : 2x FIR Upsampler + Linear");
        $display("Using 3rd-order Sigma-Delta Modulator");
        $display("Target F0      : %0f Hz", TARGET_F0);
        $display("Target Frequency Resolution : %0d Hz", TARGET_RES);
        $display("Actual Res     : %0f Hz", (FS_HZ * 1.0) / N_SAMPLES);
        $display("Auto Samples   : %0d (2^%0d)", N_SAMPLES, $clog2(N_SAMPLES));
        $display("-------------------------------");

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

    // File output (synchronized)
    always @(posedge clk) begin
        if (rst_n) begin
            $fwrite(f, "%b\n", sdm_out);
        end
    end

endmodule
