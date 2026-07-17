module fwft_fifo #(
        parameter integer DATA_WIDTH = 32,
        parameter integer FIFO_DEPTH = 256
    ) (
        input wire clk,
        input wire rstn,
        input wire wr_en,
        input wire rd_en,
        input wire [DATA_WIDTH-1:0] data_in,
        output reg [DATA_WIDTH-1:0] data_out,
        output wire empty,
        output wire valid,
        output wire full,
        output reg [$clog2(FIFO_DEPTH+1)-1:0] data_count
    );

    localparam PTR_W   = $clog2(FIFO_DEPTH);
    localparam COUNT_W = $clog2(FIFO_DEPTH+1);

    // FIFO storage (inferred as block RAM, simple dual-port: sync write + sync read)
    reg [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [DATA_WIDTH-1:0] bram_q;   // BSRAM read-output register
    reg [PTR_W-1:0]      wr_ptr;   // next write slot
    reg [PTR_W-1:0]      rd_ptr;   // next slot to fetch into data_out on a read

    assign full  = (data_count == FIFO_DEPTH);
    assign empty = (data_count == 0);
    assign valid = !empty;

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    wire [PTR_W-1:0] next_wr_ptr = (wr_ptr == FIFO_DEPTH-1) ? {PTR_W{1'b0}} : wr_ptr + 1'b1;
    wire [PTR_W-1:0] next_rd_ptr = (rd_ptr == FIFO_DEPTH-1) ? {PTR_W{1'b0}} : rd_ptr + 1'b1;

    // FWFT bypass: when the FIFO is empty (or has exactly one entry that is
    // being consumed this same cycle by a simultaneous read), the just-written
    // word must appear on data_out *next* cycle without waiting for a BRAM read
    // round-trip. The BRAM hasn't even latched it yet, so source data_out from
    // data_in directly. data_count tracking still treats it as a normal write.
    wire bypass = do_write && (empty || (do_read && data_count == 1));

    // --- BRAM write port (synchronous) ---
    always @(posedge clk) begin
        if (do_write)
            fifo_mem[wr_ptr] <= data_in;
    end

    // --- BRAM read port (synchronous, always reading) ---
    // Unconditional read lets the synthesizer infer BSRAM. Because the BRAM
    // output (bram_q) reflects the read address from *one cycle ago*, the read
    // address must be the entry that will be consumed next cycle (i.e. the
    // entry after the one being consumed right now). When no read is pending
    // the address stays at rd_ptr so bram_q holds the current head of queue.
    wire [PTR_W-1:0] bram_rd_addr = do_read ? next_rd_ptr : rd_ptr;
    always @(posedge clk)
        bram_q <= fifo_mem[bram_rd_addr];

    initial begin
        wr_ptr     = {PTR_W{1'b0}};
        rd_ptr     = {PTR_W{1'b0}};
        data_count = {COUNT_W{1'b0}};
    end

    // --- FWFT output register (selects between bypass data and BRAM output) ---
    always @(posedge clk) begin
        if (bypass)
            data_out <= data_in;
        else if (do_read)
            data_out <= bram_q;
    end

    // --- Pointer / count management ---
    always @(posedge clk) begin
        if (!rstn) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            data_count <= 0;
        end
        else if (do_write && do_read) begin
            wr_ptr <= next_wr_ptr;
            rd_ptr <= bypass ? next_wr_ptr : next_rd_ptr;
            // data_count unchanged
        end
        else if (do_write) begin
            wr_ptr <= next_wr_ptr;
            // On empty->1 transition the written word is shown via bypass,
            // so rd_ptr must skip over it to point at the *following* slot
            // for the subsequent fetch.
            if (empty)
                rd_ptr <= next_wr_ptr;
            data_count <= data_count + 1'b1;
        end
        else if (do_read) begin
            rd_ptr     <= next_rd_ptr;
            data_count <= data_count - 1'b1;
        end
    end
endmodule
