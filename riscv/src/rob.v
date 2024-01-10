`define REG_INSTR 2'b00
`define STORE_INSTR 2'b01
`define BRANCH_INSTR 2'b10
`define LOAD_INSTR 2'b11

module reorder_buffer #(
    parameter ROB_WIDTH = 4,
    parameter ROB_SIZE = 2 ** ROB_WIDTH,
    parameter JALR_QUEUE_WIDTH = 2,
    parameter JALR_QUEUE_SIZE = 2 ** JALR_QUEUE_WIDTH,
    parameter LOCAL_WIDTH = 6
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
    input wire [4:0] issue_rd_id,

    // result from ALU
    input wire alu1_done,  // 1 for sending ALU result
    input wire alu2_done,  // 1 for sending ALU result
    input wire [31:0] alu1_value,
    input wire [31:0] alu2_value,
    input wire [ROB_WIDTH-1:0] alu1_tag,
    input wire [ROB_WIDTH-1:0] alu2_tag,

    // result from LSB(load)
    input wire lsb_load_done,  // 1 for sending LSB load result
    input wire [31:0] lsb_load_value,
    input wire [ROB_WIDTH-1:0] lsb_load_tag,

    // commit to RF (for REG_INSTR and JALR_INSTR)
    output reg reg_done,  // 1 for committing to RF
    output reg [31:0] reg_value,
    output reg [4:0] reg_id,
    output reg [ROB_WIDTH-1:0] reg_tag,

    // commit to LSB (only for STORE_INSTR)
    output reg lsb_done,  // 1 for committing to RF
    output reg [ROB_WIDTH-1:0] lsb_tag,

    // send jump status to predictor when committing br-instr
    output reg predictor_signal,  // 1 for committing br-instr
    output reg predictor_branch,  // 1 for jumping, 0 for continuing
    output reg [LOCAL_WIDTH-1:0] predictor_addr,  // predictor addr

    // with instr-fetch issue, send the information of rs-reg in combinational logic
    output wire [ROB_WIDTH-1:0] rob_tag,  // index of new line in ROB
    output wire [31:0] rob_value_rs1,
    output wire [31:0] rob_value_rs2,
    output wire rob_ready_rs1,
    output wire rob_ready_rs2,
    input wire [ROB_WIDTH-1:0] rob_tag_rs1,
    input wire [ROB_WIDTH-1:0] rob_tag_rs2,

    output wire full  // 1 when ROB is full
);

  // ROB line
  // BRANCH_INSTR: [31:26] the predictor index | [25:2] the PC different from prediction(hight bits are ignored; last two bits are 0, ignored) | [1] predictor-result | [0] br-result
  reg busy[ROB_SIZE-1:0];  // 1 for busy
  reg ready[ROB_SIZE-1:0];  // 1 for ready
  reg [1:0] opcode[ROB_SIZE-1:0];  // the category of instruction
  reg [31:0] value[ROB_SIZE-1:0];
  reg [4:0] rd_id[ROB_SIZE-1:0];  // the rd-reg id of instruction
  reg [ROB_WIDTH-1:0] front_rob;
  reg [ROB_WIDTH-1:0] rear_rob;
  wire [ROB_WIDTH-1:0] rear_rob_next = rear_rob + 1;

  assign rob_full = ((rear_rob_next == front_rob) & issue_signal) | ((rear_rob == front_rob) & busy[rear_rob]);
  assign full = rob_full;
  assign rob_tag = rear_rob;
  assign rob_value_rs1 = value[rob_tag_rs1];
  assign rob_value_rs2 = value[rob_tag_rs2];
  assign rob_ready_rs1 = busy[rob_tag_rs1] & ready[rob_tag_rs1];
  assign rob_ready_rs2 = busy[rob_tag_rs2] & ready[rob_tag_rs2];

  integer i_reset;
  integer i_alu1;
  integer i_alu2;
  integer i_lsb_load;
  always @(posedge clk_in) begin
    if (rst_in | (rdy_in & clear_signal)) begin
      clear_signal <= 1'b0;
      for (i_reset = 0; i_reset < ROB_SIZE; i_reset = i_reset + 1) begin
        busy[i_reset]  <= 1'b0;
        ready[i_reset] <= 1'b0;
      end
      front_rob <= {ROB_WIDTH{1'b0}};
      rear_rob <= {ROB_WIDTH{1'b0}};
      reg_done <= 1'b0;
      lsb_done <= 1'b0;
      predictor_signal <= 1'b0;
    end else if (rdy_in) begin
      if (issue_signal) begin  // issue instr
        busy[rear_rob] <= 1'b1;
        ready[rear_rob] <= issue_value_ready;
        opcode[rear_rob] <= issue_opcode;
        rd_id[rear_rob] <= issue_rd_id;
        rear_rob <= rear_rob + 1;
        value[rear_rob] <= issue_value;
      end

      if (busy[front_rob]) begin  // commit an instr
        case (opcode[front_rob])
          `REG_INSTR: begin  // commit to RF, RS
            if (ready[front_rob]) begin
              busy[front_rob] <= 1'b0;
              front_rob <= front_rob + 1;
              reg_done <= 1'b1;
              reg_value <= value[front_rob];
              reg_tag <= front_rob;
              reg_id <= rd_id[front_rob];
              lsb_done <= 1'b0;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end  else begin  // reset the signals, avoiding handling the signals for more than one time
              reg_done <= 1'b0;
              lsb_done <= 1'b0;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end
          end
          `STORE_INSTR: begin
            if (ready[front_rob]) begin
              busy[front_rob] <= 1'b0;
              front_rob <= front_rob + 1;
              reg_done <= 1'b0;
              lsb_done <= 1'b1;
              lsb_tag <= front_rob;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end  else begin  // reset the signals, avoiding handling the signals for more than one time
              reg_done <= 1'b0;
              lsb_done <= 1'b0;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end
          end
          `BRANCH_INSTR: begin
            if (ready[front_rob]) begin
              busy[front_rob] <= 1'b0;
              front_rob <= front_rob + 1;
              reg_done <= 1'b0;
              lsb_done <= 1'b0;
              if (value[front_rob][1] ^ value[front_rob][0]) begin  // predict wrongly
                clear_signal <= 1'b1;
                correct_pc   <= value[front_rob] & 32'h0003FFFC;  // set high bits and last two bits to 0
              end else begin
                clear_signal <= 1'b0;
              end
              predictor_signal <= 1'b1;
              predictor_branch <= value[front_rob][0];
              predictor_addr   <= value[front_rob][31:32-LOCAL_WIDTH];
            end  else begin  // reset the signals, avoiding handling the signals for more than one time
              reg_done <= 1'b0;
              lsb_done <= 1'b0;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end
          end
          `LOAD_INSTR: begin
            if (ready[front_rob]) begin
              busy[front_rob] <= 1'b0;
              front_rob <= front_rob + 1;
              reg_done <= 1'b1;
              reg_value <= value[front_rob];
              reg_tag <= front_rob;
              reg_id <= rd_id[front_rob];
              lsb_done <= 1'b0;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end else begin  // send to IO input
              reg_done <= 1'b0;
              lsb_done <= 1'b1;
              lsb_tag <= front_rob;
              clear_signal <= 1'b0;
              predictor_signal <= 1'b0;
            end
          end
        endcase
      end else begin  // reset the signals, avoiding handling the signals for more than one time
        reg_done <= 1'b0;
        lsb_done <= 1'b0;
        clear_signal <= 1'b0;
        predictor_signal <= 1'b0;
      end

      if (alu1_done) begin  // update value from ALU1
        for (i_alu1 = 0; i_alu1 < ROB_SIZE; i_alu1 = i_alu1 + 1) begin
          if (~ready[i_alu1] & (alu1_tag == i_alu1)) begin
            ready[i_alu1] <= 1'b1;
            if (opcode[i_alu1] == `BRANCH_INSTR) begin
              value[i_alu1][0] <= alu1_value[0]; // the bool result is place in the highest bit                                                                        
            end else begin
              value[i_alu1] <= alu1_value;
            end
          end
        end
      end

      if (alu2_done) begin  // update value from ALU2
        for (i_alu2 = 0; i_alu2 < ROB_SIZE; i_alu2 = i_alu2 + 1) begin
          if (~ready[i_alu2] & (alu2_tag == i_alu2)) begin
            ready[i_alu2] <= 1'b1;
            if (opcode[i_alu2] == `BRANCH_INSTR) begin
              value[i_alu2][0] <= alu2_value[0]; // the bool result is place in the highest bit                                                                        
            end else begin
              value[i_alu2] <= alu2_value;
            end
          end
        end
      end

      if (lsb_load_done) begin  // update value from LSB
        for (i_lsb_load = 0; i_lsb_load < ROB_SIZE; i_lsb_load = i_lsb_load + 1) begin
          if (~ready[i_lsb_load] & (lsb_load_tag == i_lsb_load)) begin
            ready[i_lsb_load] <= 1'b1;
            if (opcode[i_lsb_load] == `BRANCH_INSTR) begin
              value[i_lsb_load][0] <= lsb_load_value[0]; // the bool result is place in the highest bit                                                                        
            end else begin
              value[i_lsb_load] <= lsb_load_value;
            end
          end
        end
      end
    end
  end

endmodule
