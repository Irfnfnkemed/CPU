`define REG_WIDTH 32

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
    input wire [1:0] issue_len,
    input wire [`REG_WIDTH-1:0] issue_addr,
    input wire [`REG_WIDTH-1:0] issue_value,
    input wire [ROB_WIDTH-1:0] issue_tag_addr,
    input wire [ROB_WIDTH-1:0] issue_tag_rd,
    input wire issue_valid_addr,  // 1 for addr valid (tag is invalid)

    // commited instruction from ROB (only for store)
    input wire commit_signal,  // 1 for committing a **store instruction** 
    input wire [`REG_WIDTH-1:0] commit_addr,
    input wire [`REG_WIDTH-1:0] commit_value,
    input wire [ROB_WIDTH-1:0] commit_tag,

    // send load/store task to memory controller
    output reg mem_signal,  // 1 for sending load/store task
    output reg mem_wr,  // 1 for write
    output reg [1:0] mem_len,  // length(byte) of laod/store (1 byte, 2 bytes, 4 bytes)
    output reg [`REG_WIDTH-1:0] mem_addr,  // load/store address
    output reg [`REG_WIDTH-1:0] mem_dout,  // data for store
    input wire [`REG_WIDTH-1:0] mem_din,  // data for load
    input wire mem_done,  // 1 when done

    // remove tag and set value from ALU
    input wire alu_signal,  // 1 for ALU sending data
    input wire [`REG_WIDTH-1:0] alu_value,
    input wire [ROB_WIDTH-1:0] alu_tag,

    // send load result to RS (fowrarding)
    output reg rs_signal,  // 1 for sending load result
    output reg [`REG_WIDTH-1:0] rs_value,
    output reg [ROB_WIDTH-1:0] rs_tag,

    // send load result to ROB
    output reg rob_signal,  // 1 for sending load result
    output reg [`REG_WIDTH-1:0] rob_value,
    output reg [ROB_WIDTH-1:0] rob_tag,

    output wire full
);

  //LSB lines
  // tag_value is unnecessary, because it's useless for loading and value will be updated without tag when committing for store 
  reg busy[LSB_SIZE-1:0];  // 1 for line busy
  reg ready[LSB_SIZE-1:0];  // 1 for ready
  reg wr[LSB_SIZE-1:0];
  reg [1:0] len[LSB_SIZE-1:0];
  reg [`REG_WIDTH-1:0] address[LSB_SIZE-1:0];
  reg [`REG_WIDTH-1:0] value[LSB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] tag_addr[LSB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] tag_rd[LSB_SIZE-1:0];

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
      rs_signal <= 1'b0;
      rob_signal <= 1'b0;
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
      rs_signal <= 1'b0;
      rob_signal <= 1'b0;
      rear <= (busy[front] & wr[front] & ready[front]) ?(last_store_commit + 1):front; // whether LSB has committed instr or not
      if (~(mem_signal & mem_wr)) begin // cancel the mem request excect store task 
        mem_signal <= 1'b0;
        status <= 1'b0;
      end
      for (i_clear = 0; i_clear < LSB_SIZE; i_clear = i_clear + 1) begin
        if(~(busy[i_clear] & wr[i_clear] & ready[i_clear]))begin // clear LSB, expect reafy store task
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
      len[rear] <= issue_len;
      address[rear] <= issue_addr;
      value[rear] <= issue_value;
      tag_addr[rear] <= issue_tag_addr;
      tag_rd[rear] <= issue_tag_rd;
      rear <= rear + 1;
    end
  end

  integer i_commit;
  always @(posedge clk_in) begin  // update load line according to the data from ALU 
    if (rdy_in & commit_signal) begin
      for (i_commit = 0; i_commit < LSB_SIZE; i_commit = i_commit + 1) begin
        if (busy[i_commit]) begin  // in fact, only update store line, because load line should be updated before
          if (~ready[i_alu] & (tag_addr[i_commit] == commit_tag)) begin
            ready[i_alu] <= 1'b1;
            address[i_alu] <= commit_addr;
            value[i_alu] <= commit_value;
            last_store_commit <= i_alu;
          end
        end
      end
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in & ~status & busy[front] & ready[front]) begin  // do the load/store task at front pos
      mem_signal <= 1'b1;
      mem_wr <= wr[front];
      mem_len <= len[front];
      mem_addr <= address[front];
      mem_dout <= value[front];
      status <= 1'b1;
    end
  end

  integer i_mem;
  always @(posedge clk_in) begin
    if (rdy_in & mem_done) begin  // handle the result of load/store
      status <= 1'b0;
      mem_signal <= 1'b0;  // end task
      front <= front + 1;  // free line
      busy[front] <= 1'b0;
      ready[front] <= 1'b0;
      if (wr[front]) begin  // send data&tag to RS&ROB, flush data&tag in LSB
        for (i_mem = 0; i_mem < LSB_SIZE; i_mem = i_mem + 1) begin
          if (busy[i_mem]) begin  // only update load line, for store line, update when ROB commit
            if (~ready[i_mem] & ~wr[i_mem] & (tag_addr[i_mem] == tag_rd[front])) begin
              ready[i_mem]   <= 1'b1;
              address[i_mem] <= mem_din;
            end
          end
        end
        rs_signal <= 1'b1;
        rob_signal <= 1'b1;
        rs_value <= mem_din;
        rob_value <= mem_din;
        rs_tag <= tag_rd[front];
        rob_tag <= tag_rd[front];
      end
    end
  end

  integer i_alu;
  always @(posedge clk_in) begin  // update load line according to the data from ALU 
    if (rdy_in & alu_signal) begin
      for (i_alu = 0; i_alu < LSB_SIZE; i_alu = i_alu + 1) begin
        if (busy[i_alu]) begin  // only update load line
          if (~ready[i_alu] & ~wr[i_alu] & (tag_addr[i_alu] == alu_tag)) begin
            ready[i_alu]   <= 1'b1;
            address[i_alu] <= alu_value;
          end
        end
      end
    end
  end

  always @(posedge clk_in) begin  // handle done signal, avoiding flush RS/ROB more than one time
    if (rdy_in) begin
      if (rs_signal) begin
        rs_signal <= 1'b0;
      end
      if (rob_signal) begin
        rob_signal <= 1'b0;
      end
    end
  end


endmodule
