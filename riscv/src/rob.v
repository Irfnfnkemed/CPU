`define REG_INSTR 2'b00
`define STORE_INSTR 2'b01
`define BRANCH_INSTR 2'b10
`define JALR_INSTR 2'b11

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
    input wire [31:0] issue_pc_prediction,  // for JALR (PC+4 is in issue_value)

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

  // JALR queue
  reg busy_jalr[JALR_QUEUE_SIZE-1:0];  // 1 for busy
  reg [31:0] pc_next_jalr[JALR_QUEUE_SIZE-1:0];  // PC+4
  reg [31:0] pc_prediction_jalr[JALR_QUEUE_SIZE-1:0];  // prediction PC
  reg [JALR_QUEUE_WIDTH-1:0] front_jalr;
  reg [JALR_QUEUE_WIDTH-1:0] rear_jalr;

  wire [ROB_WIDTH-1:0] rear_rob_next = rear_rob + 1;
  wire [JALR_QUEUE_WIDTH-1:0] rear_jalr_next = rear_jalr + 1;

  assign rob_full = ((rear_rob_next == front_rob) & issue_signal) | ((rear_rob == front_rob) & busy[rear_rob]);
  assign jalr_full =  ((rear_jalr_next == front_jalr) & issue_signal & (issue_opcode == `JALR_INSTR)) | ((rear_jalr == front_jalr) & busy_jalr[rear_jalr]);
  assign full = rob_full | jalr_full;
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
      for (i_reset = 0; i_reset < JALR_QUEUE_SIZE; i_reset = i_reset + 1) begin
        busy_jalr[i_reset] <= 1'b0;
      end
      front_rob <= {ROB_WIDTH{1'b0}};
      front_jalr <= {JALR_QUEUE_WIDTH{1'b0}};
      rear_rob <= {ROB_WIDTH{1'b0}};
      rear_jalr <= {JALR_QUEUE_WIDTH{1'b0}};
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

      if (busy[front_rob] & ready[front_rob]) begin  // commit an instr
        busy[front_rob] <= 1'b0;
        front_rob <= front_rob + 1;
        case (opcode[front_rob])
          `REG_INSTR: begin  // commit to RF, RS
            reg_done <= 1'b1;
            reg_value <= value[front_rob];
            reg_tag <= front_rob;
            reg_id <= rd_id[front_rob];
            lsb_done <= 1'b0;
            clear_signal <= 1'b0;
            predictor_signal <= 1'b0;
          end
          `STORE_INSTR: begin
            reg_done <= 1'b0;
            lsb_done <= 1'b1;
            lsb_tag <= front_rob;
            clear_signal <= 1'b0;
            predictor_signal <= 1'b0;
          end
          `BRANCH_INSTR: begin
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
          end
          `JALR_INSTR: begin
            reg_done <= 1'b1;
            reg_value <= value[front_rob];
            reg_tag <= front_rob;
            reg_id <= rd_id[front_rob];
            lsb_done <= 1'b0;
            clear_signal <= 1'b0;
            predictor_signal <= 1'b0;
            // reg_done <= 1'b1;
            // reg_value <= pc_next_jalr[front_jalr];  // send PC+4 to rd
            // reg_tag <= front_rob;
            // reg_id <= rd_id[front_rob];
            // busy_jalr[front_jalr] <= 1'b0;
            // front_jalr <= front_jalr + 1;
            // if (~(value[front_rob] == pc_prediction_jalr[front_jalr])) begin  // predict wrongly
            //   clear_signal <= 1'b1;
            //   correct_pc   <= value[front_rob];
            // end else begin
            //   clear_signal <= 1'b0;
            // end
            // lsb_done <= 1'b0;
            // predictor_signal <= 1'b0;
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

  // always @(posedge clk_in) begin
  //     // if (issue_opcode == `JALR_INSTR) begin  // push to JALR queue
  //     //   pc_next_jalr[rear_jalr] <= issue_value;
  //     //   pc_prediction_jalr[rear_jalr] <= issue_pc_prediction;
  //     //   busy_jalr[rear_jalr] <= 1'b1;
  //     //   rear_jalr <= rear_jalr + 1;
  //     // end else begin
  //     //   value[rear_rob] <= issue_value;
  //     // end
  // end


  // always @(posedge clk_in) begin  // update value from ALU2
  //   if (~rst_in & rdy_in & alu2_done & ~clear_signal & ~ready[alu2_tag]) begin
  //     ready[alu2_tag] <= 1'b1;
  //     if (opcode[alu2_tag] == `BRANCH_INSTR) begin
  //       value[alu2_tag][0] <= alu2_value[0]; // the bool result is place in the highest bit                                                                        
  //     end else begin
  //       value[alu2_tag] <= alu2_value;
  //     end
  //   end
  // end

  // always @(posedge clk_in) begin  // update value from LSB
  //   if (~rst_in & rdy_in & lsb_load_done & ~clear_signal & ~ready[lsb_load_tag]) begin
  //     ready[lsb_load_tag] <= 1'b1;
  //     if (opcode[lsb_load_tag] == `BRANCH_INSTR) begin
  //       value[lsb_load_tag][0] <= lsb_load_value[0]; // the bool result is place in the highest bit                                                                        
  //     end else begin
  //       value[lsb_load_tag] <= lsb_load_value;
  //     end
  //   end
  // end

  // integer f;
  // initial begin
  //   f = $fopen("f");
  // end

  // integer i;
  // always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
  //   if (~rst_in & rdy_in) begin  // 0th reg cannot be modified
  //     $fdisplay(f, "signal:%d,commit_tag:%d", rob_commit_signal, commit_rd_tag);
  //     for (i = 1; i < 32; i = i + 1) begin
  //       $fdisplay(f, "%d:%h, tag:%d, valid:%d", i, values[i], tags[i], valid[i]);
  //     end
  //   end
  // end
endmodule
