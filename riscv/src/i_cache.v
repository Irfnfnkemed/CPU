`define FREE_STATUS 1'b0
`define MEM_FETCH_STATUS 1'b1

module instr_cache #(
    parameter DATA_WIDTH = 64,  // the width of data in a line
    parameter CACHE_WIDTH = 8,
    parameter CACHE_SIZE = 2 ** CACHE_WIDTH,
    parameter TAG_WIDTH = 6
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire clear_signal,  // 1 for prediction error

    // with instruction-fetch, using combinational logic so that cache can return the instr in a cycle
    input wire fetch_signal,  // 1 for instruction fetch
    input wire [31:0] fetch_addr,
    output wire fetch_done,  // 1 when the task of load instruction is done (hit the cache)
    output wire [31:0] fetch_instr,

    // with memory controller
    output reg mem_signal,  // 1 for load instruction
    output reg [31:0] mem_addr,  // instruction address
    input wire mem_done,  // 1 when done 
    input wire [DATA_WIDTH-1:0] mem_data  // instruction content (fetch 2 instr)
);
  // cache line
  // instr-addr: [31-17] ignore | [16-11] tag | [10-3] index | [2] byte selector | [1-0] ignre (00)
  reg valid[CACHE_SIZE-1:0];  // 1 for valid
  reg [TAG_WIDTH-1:0] tag[CACHE_SIZE-1:0];
  reg [DATA_WIDTH-1:0] data[CACHE_SIZE-1:0];

  reg status;
  wire [TAG_WIDTH-1:0] fetch_tag;
  wire [CACHE_WIDTH-1:0] fetch_index;
  wire fetch_bs;

  assign fetch_tag = fetch_addr[16:17-TAG_WIDTH];
  assign fetch_index = fetch_addr[16-TAG_WIDTH:3];
  assign fetch_bs = fetch_addr[2];

  assign fetch_done = valid[fetch_index] & (fetch_tag == tag[fetch_index]);
  assign fetch_instr = fetch_bs ? data[fetch_index][63:32] : data[fetch_index][31:0];

  integer i_reset;
  always @(posedge clk_in) begin
    if (rst_in) begin
      status <= `FREE_STATUS;
      mem_signal <= 1'b0;
      for (i_reset = 0; i_reset < CACHE_SIZE; i_reset = i_reset + 1) begin
        valid[i_reset] <= 1'b0;
        tag[i_reset]   <= {TAG_WIDTH{1'b0}};
      end
    end else if (rdy_in) begin
      if (clear_signal) begin  // end the request of instruction fetch
        status <= `FREE_STATUS;
        mem_signal <= 1'b0;
      end else begin
        case (status)
          `FREE_STATUS: begin
            if (fetch_signal & ~fetch_done) begin  // not hit in cache, send to mem-controller
              status <= `MEM_FETCH_STATUS;
              mem_signal <= 1'b1;
              mem_addr <= fetch_addr & 32'hFFFFFFFB; // set instr address to the low pos in a line (whose bs is 0)
            end
          end
          `MEM_FETCH_STATUS: begin
            if (mem_done) begin
              status <= `FREE_STATUS;
              mem_signal <= 1'b0;
              valid[fetch_index] <= 1'b1;
              tag[fetch_index] <= fetch_tag;
              data[fetch_index] <= mem_data;
            end
          end
        endcase
      end
    end
  end

endmodule
