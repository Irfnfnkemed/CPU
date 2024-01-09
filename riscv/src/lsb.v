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

    // commited instruction from ROB (only for store and IO input)
    input wire commit_signal,  // 1 for committing a store instruction or IO input
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

    // send load result to RS&ROB&I_FETCH (fowrarding)
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

  wire [LSB_WIDTH-1:0] rear_next;
  assign rear_next = rear + 1;
  assign full = ((rear_next == front) & issue_signal) | ((rear == front) & busy[rear]);  // 1 for full

  wire hit_addr;
  assign hit_addr = (mem_done & ~wr[front] & (tag_rd[front] == issue_tag_addr)) | (done_signal & (done_tag == issue_tag_addr)) |
                    (alu1_signal & (alu1_tag == issue_tag_addr)) | (alu2_signal & (alu2_tag == issue_tag_addr));

  integer i_reset;
  integer i_clear;
  integer i_mem;
  integer i_commit;
  integer i_alu1;
  integer i_alu2;
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
    end else if (rdy_in) begin
      if (clear_signal) begin
        done_signal <= 1'b0;
        rear <= (busy[front] & wr[front] & ready[front]) ? (last_store_commit + 1) : front; // whether LSB has committed instr or not
        if (~(mem_signal & mem_wr)) begin  // cancel the mem request except store task 
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

      if (issue_signal & ~clear_signal) begin  // push new instr to rear pos when issuing
        busy[rear] <= 1'b1;
        wr[rear] <= issue_wr;
        sign[rear] <= issue_signed;
        len[rear] <= issue_len;
        offset[rear] <= issue_offset;
        tag_addr[rear] <= issue_tag_addr;
        tag_value[rear] <= issue_tag_value;
        tag_rd[rear] <= issue_tag_rd;
        rear <= rear + 1;
        if (~issue_valid_addr) begin
          if (mem_done & ~wr[front] & (tag_rd[front] == issue_tag_addr)) begin
            address[rear] <= mem_din;
            valid_addr[rear] <= 1'b1;
            ready[rear] <= ~issue_wr & ~(mem_din == 32'h30000);
          end else if (done_signal & (done_tag == issue_tag_addr)) begin
            address[rear] <= done_value;
            valid_addr[rear] <= 1'b1;
            ready[rear] <= ~issue_wr & ~(done_value == 32'h30000);
          end else if (alu1_signal & (alu1_tag == issue_tag_addr)) begin
            address[rear] <= alu1_value;
            valid_addr[rear] <= 1'b1;
            ready[rear] <= ~issue_wr & ~(alu1_value == 32'h30000);
          end else if (alu2_signal & (alu2_tag == issue_tag_addr)) begin
            address[rear] <= alu2_value;
            valid_addr[rear] <= 1'b1;
            ready[rear] <= ~issue_wr & ~(alu2_value == 32'h30000);
          end else begin
            valid_addr[rear] <= 1'b0;
            ready[rear] <= 1'b0;
          end
        end else begin
          address[rear] <= issue_addr;
          valid_addr[rear] <= 1'b1;
          ready[rear] <= ~issue_wr & ~(issue_addr == 32'h30000);  // for loading, ready bit is same to valid_addr(considering updation through ALU/MEM result); for storing, ready bit is 0
        end
        if (issue_wr & ~issue_valid_value) begin
          if (mem_done & ~wr[front] & (tag_rd[front] == issue_tag_value)) begin
            value[rear] <= mem_din;
            valid_value[rear] <= 1'b1;
          end else if (done_signal & (done_tag == issue_tag_value)) begin
            value[rear] <= done_value;
            valid_value[rear] <= 1'b1;
          end else if (alu1_signal & (alu1_tag == issue_tag_value)) begin
            value[rear] <= alu1_value;
            valid_value[rear] <= 1'b1;
          end else if (alu2_signal & (alu2_tag == issue_tag_value)) begin
            value[rear] <= alu2_value;
            valid_value[rear] <= 1'b1;
          end else begin
            valid_value[rear] <= 1'b0;
          end
        end else begin
          value[rear] <= issue_value;
          valid_value[rear] <= 1'b1;
        end
      end

      if (~status & busy[front] & ready[front] & (~clear_signal | wr[front])) begin  // do the load/store task at front pos
        mem_signal <= 1'b1;
        mem_wr <= wr[front];
        mem_signed <= sign[front];
        mem_len <= len[front];
        mem_addr <= address[front] + {{20{offset[front][11]}}, offset[front][11:0]};
        mem_dout <= value[front];
        status <= 1'b1;
      end

      if (mem_done & (~clear_signal | wr[front])) begin  // handle the result of load/store
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
                ready[i_mem] <= 1'b1 & ~wr[i_mem]; // if load, set ready status; if store, set not ready status(ready when committing)
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

      if (commit_signal & ~clear_signal) begin // only set store line or IO input to ready, because value&addr should be updated before
        for (i_commit = 0; i_commit < LSB_SIZE; i_commit = i_commit + 1) begin
          if (busy[i_commit] & ~ready[i_commit] & (tag_rd[i_commit] == commit_tag)) begin
            if (wr[i_commit]) begin
              ready[i_commit]   <= 1'b1;
              last_store_commit <= i_commit;  // only one line(infact,store) can be modified
            end else if (valid_addr[i_commit] & (address[i_commit] == 32'h30000)) begin
              ready[i_commit] <= 1'b1;
            end
          end
        end
      end

      if (alu1_signal & ~clear_signal) begin  // update load line according to the data from ALU1
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

      if (alu2_signal & ~clear_signal) begin  // update load line according to the data from ALU 
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
  end
endmodule
