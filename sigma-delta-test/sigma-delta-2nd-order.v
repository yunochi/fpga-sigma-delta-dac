
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

