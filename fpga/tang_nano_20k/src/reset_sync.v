module reset_sync (
        input wire clk,
        input wire i_nrst_async,
        output wire o_rst_sync,
        output wire o_nrst_sync
    );

    (* keep = "true" *) (* dont_touch = "true" *)
    reg [3:0] reset_sync_ff;
    assign o_rst_sync = !reset_sync_ff[3];
    assign o_nrst_sync = reset_sync_ff[3];

    always @(posedge clk or negedge i_nrst_async) begin
        if (!i_nrst_async) begin
            reset_sync_ff <= 4'b0000;
        end
        else begin
            reset_sync_ff <= {reset_sync_ff[2:0], 1'b1};
        end
    end
endmodule
