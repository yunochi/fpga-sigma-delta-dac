module mua(input clk, input rstn);
    reg a;
    reg b;
    reg c;
    reg led_reg;
    always @(posedge clk) begin
        if (!rstn) begin
            a <= 0; b <= 0; c <= 0; led_reg <= 0;
        end
        else begin
            a <= 1;
            b <= a;
            c <= b;
            if (c == 1'b1) begin
               led_reg <= 1;
            end
        end
    end

endmodule
