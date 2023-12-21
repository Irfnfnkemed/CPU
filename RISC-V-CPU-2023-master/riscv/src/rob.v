`define REG_INSTR 2'b00
`define STORE_INSTR 2'b01
`define BRANCH_INSTR 2'b01
`define JALR_INSTR 2'b11

module reorder_buffer #(
    parameter ROB_WIDTH = 4,
    parameter ROB_SIZE = 2 ** ROB_WIDTH,
    parameter JALR_QUEUE_SIZE = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    output reg clear_signal,  // 1 for error prediction
    output reg [31:0] correct_pc,  // to pc when predicting wrongly

    //issued instr from instr fetch (fetch value/tag from RF and ROB)
    input wire issue_signal,  // 1 for issuing instruction 
    input wire [1:0] issue_opcode,
    input wire issue_value_ready,  // 1 for ready value
    input wire [31:0] issue_value,
    input wire [31:0] issue_pc_prediction,  // for JALR (PC+4 is in issue_value)

    //result from ALU
    input wire alu_done,  // 1 for sending ALU result
    input wire [31:0] alu_value,
    input wire [ROB_WIDTH-1:0] alu_tag,

    // commit to RF (for REG_INSTR and JALR_INSTR)
    output reg reg_done,  // 1 for committing to RF
    output reg [31:0] reg_value,
    output reg [ROB_WIDTH-1:0] reg_tag,

    // commit to LSB (only for STORE_INSTR)
    output reg lsb_done,  // 1 for committing to RF
    output reg [31:0] lsb_value,
    output reg [ROB_WIDTH-1:0] lsb_tag,

    output wire full,  // 1 when ROB is full
    output wire [ROB_WIDTH-1:0] rob_tag  // index of new line in ROB
);

  // ROB line
  // BRANCH_INSTR: [31:2] the PC different from prediction(last two bits are 0, ignored) | [1] predictor-result | [0] br-result
  reg busy[ROB_SIZE-1:0];  // 1 for busy
  reg ready[ROB_SIZE-1:0];  // 1 for ready
  reg [1:0] opcode[ROB_SIZE-1:0];  // the category of instruction
  reg [31:0] value[ROB_SIZE-1:0];
  reg [ROB_WIDTH-1:0] front_rob;
  reg [ROB_WIDTH-1:0] rear_rob;

  // JALR queue
  reg busy_jalr[JALR_QUEUE_SIZE-1:0];  // 1 for busy
  reg [31:0] pc_next_jalr[JALR_QUEUE_SIZE-1:0];  // PC+4
  reg [31:0] pc_prediction_jalr[JALR_QUEUE_SIZE-1:0];  // prediction PC
  reg [ROB_WIDTH-1:0] front_jalr;
  reg [ROB_WIDTH-1:0] rear_jalr;

  assign full = ((rear_rob == front_rob) & busy[rear_rob]) | ((rear_jalr == front_jalr) & busy_jalr[rear_jalr]);
  assign rob_tag = rear_rob;

  integer i_reset;
  always @(posedge clk_in) begin
    if (rst_in) begin
      for (i_reset = 0; i_reset < ROB_SIZE; i_reset = i_reset + 1) begin
        busy[i_reset]  <= 1'b0;
        ready[i_reset] <= 1'b0;
      end
      for (i_reset = 0; i_reset < JALR_QUEUE_SIZE; i_reset = i_reset + 1) begin
        busy_jalr[i_reset] <= 1'b0;
      end
      front_rob  <= {ROB_WIDTH{1'b0}};
      front_jalr <= {ROB_WIDTH{1'b0}};
      rear_rob   <= {ROB_WIDTH{1'b0}};
      rear_jalr  <= {ROB_WIDTH{1'b0}};
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in & issue_signal) begin  // issue instr
      busy[rear_rob] <= 1'b1;
      ready[rear_rob] <= issue_value_ready;
      opcode[rear_rob] <= issue_opcode;
      rear_rob <= rear_rob + 1;
      if (issue_opcode == `JALR_INSTR) begin  // push to JALR queue
        pc_next_jalr[rear_rob] <= issue_value;
        pc_prediction_jalr[rear_rob] <= issue_pc_prediction;
        busy[rear_jalr] <= 1'b1;
        rear_jalr <= rear_jalr + 1;
      end else begin
        value[rear_rob] <= issue_value;
      end
    end
  end

  always @(posedge clk_in) begin  // commit an instr
    if (rdy_in) begin
      if (busy[front_rob] & ready[front_rob]) begin
        busy[front_rob] <= 1'b0;
        front_rob <= front_rob + 1;
        case (opcode[front_rob])
          `REG_INSTR: begin  // commit to RF
            reg_done  <= 1'b1;
            reg_value <= value[front_rob];
            reg_tag   <= front_rob;
          end
          `STORE_INSTR: begin
            lsb_done <= 1'b1;
            lsb_value <= value[front_rob];
            lsb_tag  <= front_rob;
          end
          `BRANCH_INSTR: begin
            if (value[front_rob][1] ^ value[front_rob][0]) begin  // predict wrongly
              clear_signal <= 1'b1;
              correct_pc   <= value[front_rob] & 32'hFFFFFFFC;  // set last two bits to 0
            end
          end
          `JALR_INSTR: begin
            reg_done <= 1'b1;
            reg_value <= pc_next_jalr[front_jalr];  // send PC+4 to rd
            reg_tag <= front_rob;
            busy_jalr[front_jalr] <= 1'b0;
            front_jalr <= front_jalr + 1;
            if (~(value[front_rob] == pc_prediction_jalr[front_jalr])) begin  // predict wrongly
              clear_signal <= 1'b1;
              correct_pc   <= value[front_rob];
            end
          end
        endcase
      end
    end else begin  // reset the signals, avoiding handling the signals for more than one time
      reg_done <= 1'b0;
      lsb_done <= 1'b0;
      clear_signal <= 1'b0;
    end
  end

  always @(posedge clk_in) begin  // update value from ALU
    if (rdy_in & alu_done) begin
      ready[alu_tag] <= 1'b1;
      if (opcode[alu_tag] == `BRANCH_INSTR) begin
        value[alu_tag][0] <= alu_value[0]; // the bool result is place in the highest bit                                                                        
      end else begin
        value[alu_tag] <= alu_value;
      end
    end
  end

endmodule
