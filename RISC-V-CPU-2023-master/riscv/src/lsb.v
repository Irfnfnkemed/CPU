`ifndef LSB
`define LSB

module load_store_buffer #(
    parameter LSB_WIDTH = 4,
    parameter LSB_SIZE  = 2 ** LSB_WIDTH,
    parameter ROB_WIDTH = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire clear_signal,  // 1 for prediction error

    // issued instruction
    // for data, valid bit isn't necessary: 1 for load, 0 for store(shift to 1 when committing)
    input wire issue_signal,  // 1 for issuing an instruction
    input wire issue_wr,  // 1 for store, 0 for load
    input wire issue_signed,  // 1 for signed load, 0 for unsigned load
    input wire [1:0] issue_len,  // length of load/store instr (00:1 byte, 01:2 bytes, 11:4 bytes)
    input wire [31:0] issue_addr,
    input wire [31:0] issue_value,
    input wire [11:0] issue_offset,
    input wire [ROB_WIDTH-1:0] issue_tag_addr,
    input wire [ROB_WIDTH-1:0] issue_tag_value,
    input wire [ROB_WIDTH-1:0] issue_tag_rd,
    input wire issue_valid_addr,  // 1 for addr valid (tag is invalid)
    input wire issue_valid_value,

    // commited instruction from ROB (only for store)
    input wire commit_signal,  // 1 for committing a **store instruction** 
    input wire [ROB_WIDTH-1:0] commit_tag,

    // send load/store task to memory controller
    output reg mem_signal,  // 1 for sending load/store task
    output reg mem_wr,  // 1 for write
    output reg mem_signed,  // 1 for signed load
    output reg [1:0] mem_len,  // length(byte) of laod/store (1 byte, 2 bytes, 4 bytes)
    output reg [31:0] mem_addr,  // load/store address
    output reg [31:0] mem_dout,  // data for store
    input wire [31:0] mem_din,  // data for load
    input wire mem_done,  // 1 when done

    // remove tag and set value from ALU
    input wire alu1_signal,  // 1 for ALU sending data
    input wire alu2_signal,  // 1 for ALU sending data
    input wire [31:0] alu1_value,
    input wire [31:0] alu2_value,
    input wire [ROB_WIDTH-1:0] alu1_tag,
    input wire [ROB_WIDTH-1:0] alu2_tag,

    // send load result to RS&ROB (fowrarding)
    output reg done_signal,  // 1 for sending load result
    output reg [31:0] done_value,
    output reg [ROB_WIDTH-1:0] done_tag,

    output wire full
);

  // LSB lines
  // tag_value is unnecessary, because it's useless for loading and value will be updated without tag when committing for store 
  reg busy[LSB_SIZE-1:0];  // 1 for line busy
  reg ready[LSB_SIZE-1:0];  // 1 for ready
  reg wr[LSB_SIZE-1:0];  // 1 for store
  reg sign[LSB_SIZE-1:0];  // 1 for signed load
  reg [1:0] len[LSB_SIZE-1:0];
  reg [31:0] address[LSB_SIZE-1:0];
  reg [31:0] value[LSB_SIZE-1:0];
  reg [11:0] offset[LSB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] tag_addr[LSB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] tag_value[LSB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] tag_rd[LSB_SIZE-1:0];
  reg valid_addr[LSB_SIZE-1:0];
  reg valid_value[LSB_SIZE-1:0];


  //LSB status
  reg status;  // 0 for free, 1 for busy
  reg [LSB_WIDTH-1:0] front;
  reg [LSB_WIDTH-1:0] rear;
  reg [LSB_WIDTH-1:0] last_store_commit;  // the index of last committed store task in LSB 

  assign full = ((rear + 1) == front);  // 1 for full

  integer i_reset;
  always @(posedge clk_in) begin
    if (rst_in) begin
      front <= {LSB_WIDTH{1'b0}};
      rear <= {LSB_WIDTH{1'b0}};
      last_store_commit <= {LSB_WIDTH{1'b0}};
      mem_signal <= 1'b0;
      done_signal <= 1'b0;
      status <= 1'b0;
      for (i_reset = 0; i_reset < LSB_SIZE; i_reset = i_reset + 1) begin
        busy[i_reset]  <= 1'b0;
        ready[i_reset] <= 1'b0;
      end
    end
  end

  integer i_clear;
  always @(posedge clk_in) begin
    if (rdy_in & clear_signal) begin
      done_signal <= 1'b0;
      rear <= (busy[front] & wr[front] & ready[front]) ? (last_store_commit + 1) : front; // whether LSB has committed instr or not
      if (~(mem_signal & mem_wr)) begin  // cancel the mem request excect store task 
        mem_signal <= 1'b0;
        status <= 1'b0;
      end
      for (i_clear = 0; i_clear < LSB_SIZE; i_clear = i_clear + 1) begin
        if(~(busy[i_clear] & wr[i_clear] & ready[i_clear]))begin // clear LSB, except ready store task
          busy[i_clear]  <= 1'b0;
          ready[i_clear] <= 1'b0;
        end
      end
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in & issue_signal) begin  // push new instr to rear pos when issuing
      busy[rear] <= 1'b1;
      ready[rear] <= issue_valid_addr & ~issue_wr; // for loading, ready bit is same to valid_addr, for storing, ready bit is 0
      wr[rear] <= issue_wr;
      sign[rear] <= issue_signed;
      len[rear] <= issue_len;
      address[rear] <= issue_addr;
      value[rear] <= issue_value;
      offset[rear] <= issue_offset;
      tag_addr[rear] <= issue_tag_addr;
      tag_value[rear] <= issue_tag_value;
      tag_rd[rear] <= issue_tag_rd;
      valid_addr[rear] <= issue_valid_addr;
      valid_value[rear] <= issue_valid_value;
      rear <= rear + 1;
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in & ~status & busy[front] & ready[front]) begin  // do the load/store task at front pos
      mem_signal <= 1'b1;
      mem_wr <= wr[front];
      mem_signed <= sign[front];
      mem_len <= len[front];
      mem_addr <= address[front] + {{20{sign[front] & offset[front][11]}}, offset[front][11:0]};
      mem_dout <= value[front];
      status <= 1'b1;
    end
  end

  integer i_mem;
  always @(posedge clk_in) begin
    if (rdy_in) begin  // handle the result of load/store
      if (mem_done) begin
        status <= 1'b0;
        mem_signal <= 1'b0;  // end task
        front <= front + 1;  // free line
        busy[front] <= 1'b0;
        ready[front] <= 1'b0;
        if (~wr[front]) begin  // for load task, send data&tag to RS&ROB, flush data&tag in LSB
          for (i_mem = 0; i_mem < LSB_SIZE; i_mem = i_mem + 1) begin
            if (busy[i_mem]) begin  // update LSB
              if (~valid_addr[i_mem] & (tag_addr[i_mem] == tag_rd[front])) begin  // update addr
                valid_addr[i_mem] <= 1'b1;
                ready[i_mem]   <= 1'b1 & ~wr[i_mem]; // if load, set ready status; if store, set not ready status(ready when committing)
                address[i_mem] <= mem_din;
              end
              if (~valid_value[i_mem] & wr[i_mem] & (tag_value[i_mem] == tag_rd[front])) begin // update value (for store task)
                valid_value[i_mem] <= 1'b1;
                value[i_mem] <= mem_din;
              end
            end
          end
          done_signal <= 1'b1;
          done_value <= mem_din;
          done_tag <= tag_rd[front];
        end
      end else begin  // handle done signal, avoiding flush RS/ROB more than one time
        done_signal <= 1'b0;
      end
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in & commit_signal) begin// only set store line to ready, because value&addr should be updated before
      ready[commit_tag] <= 1'b1;
      last_store_commit <= commit_tag;
    end
  end

  integer i_alu1;
  always @(posedge clk_in) begin  // update load line according to the data from ALU 
    if (rdy_in & alu1_signal) begin
      for (i_alu1 = 0; i_alu1 < LSB_SIZE; i_alu1 = i_alu1 + 1) begin
        if (busy[i_alu1]) begin  // update lines
          if (~valid_addr[i_alu1] & (tag_addr[i_alu1] == alu1_tag)) begin
            valid_addr[i_alu1] <= 1'b1;
            ready[i_alu1] <= 1'b1 & ~wr[i_alu1]; // if load, set ready status; if store, set not ready status(ready when committing)
            address[i_alu1] <= alu1_value;
          end
          if (~valid_value[i_alu1] & wr[i_alu1] & (tag_value[i_alu1] == alu1_tag)) begin // update value (for store task)
            valid_value[i_alu1] <= 1'b1;
            value[i_alu1] <= alu1_value;
          end
        end
      end
    end
  end

  integer i_alu2;
  always @(posedge clk_in) begin  // update load line according to the data from ALU 
    if (rdy_in & alu2_signal) begin
      for (i_alu2 = 0; i_alu2 < LSB_SIZE; i_alu2 = i_alu2 + 1) begin
        if (busy[i_alu2]) begin  // update lines
          if (~valid_addr[i_alu2] & (tag_addr[i_alu2] == alu2_tag)) begin
            valid_addr[i_alu2] <= 1'b1;
            ready[i_alu2] <= 1'b1 & ~wr[i_alu2]; // if load, set ready status; if store, set not ready status(ready when committing)
            address[i_alu2] <= alu2_value;
          end
          if (~valid_value[i_alu2] & wr[i_alu2] & (tag_value[i_alu2] == alu2_tag)) begin // update value (for store task)
            valid_value[i_alu2] <= 1'b1;
            value[i_alu2] <= alu2_value;
          end
        end
      end
    end
  end

endmodule
`endif
