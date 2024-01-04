`define ROB_REG_INSTR 2'b00
`define ROB_STORE_INSTR 2'b01
`define ROB_BRANCH_INSTR 2'b10
`define ROB_JALR_INSTR 2'b11
`define ALU_NOP 4'd0
`define ALU_AND 4'd1
`define ALU_OR 4'd2
`define ALU_XOR 4'd3
`define ALU_ADD 4'd4
`define ALU_SUB 4'd5
`define ALU_SRL 4'd6
`define ALU_SRA 4'd7
`define ALU_SLL 4'd8
`define ALU_LT 4'd9
`define ALU_LTU 4'd10
`define ALU_EQ 4'd11
`define ALU_NE 4'd12
`define ALU_GE 4'd13
`define ALU_GEU 4'd14
`define ALU_JALR 4'd15

module instr_fetch #(
    parameter ROB_WIDTH   = 4,
    parameter LOCAL_WIDTH = 6
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    // with i-cache (or mem-controller)
    output wire fetch_signal,  // 1 for instruction fetch
    output wire [31:0] fetch_addr,
    input wire fetch_done,  // 1 when the task of load instruction is done (hit the cache)
    input wire [31:0] fetch_instr,

    // issue control signals
    input wire rs_full,   // 1 for RS is full
    input wire rob_full,  // 1 for ROB is full
    input wire lsb_full,  // 1 for LSB is full

    // with RF, fetch issue information and set rd tag in combinational logic
    output wire rf_signal,  //1 for fetching registers
    output wire [4:0] rf_id_rs1,
    output wire [4:0] rf_id_rs2,
    output wire [4:0] rf_id_rd,
    output wire [ROB_WIDTH-1:0] rf_tag_rd,  // overwrite the tag of rd
    input wire [31:0] rf_value_rs1,
    input wire [31:0] rf_value_rs2,
    input wire [ROB_WIDTH-1:0] rf_tag_rs1,
    input wire [ROB_WIDTH-1:0] rf_tag_rs2,
    input wire rf_valid_rs1,
    input wire rf_valid_rs2,
    input wire [31:0] value_x1,  // the value of x1 reg, for predicting JALR

    // with ROB, fetch issue information in combinational logic
    input wire [ROB_WIDTH-1:0] rob_index,  // next pos in ROB
    input wire [31:0] rob_value_rs1,
    input wire [31:0] rob_value_rs2,
    input wire rob_ready_rs1,
    input wire rob_ready_rs2,
    output wire [ROB_WIDTH-1:0] rob_tag_rs1,
    output wire [ROB_WIDTH-1:0] rob_tag_rs2,

    // with ALU, fetch issue issue information through ALU result
    input wire alu1_done_signal,
    input wire alu2_done_signal,
    input wire [ROB_WIDTH-1:0] alu1_done_tag,
    input wire [ROB_WIDTH-1:0] alu2_done_tag,
    input wire [31:0] alu1_done_value,
    input wire [31:0] alu2_done_value,

    // with LSB, fetch issue issue information through LSB load result
    input wire lsb_done_signal,
    input wire [ROB_WIDTH-1:0] lsb_done_tag,
    input wire [31:0] lsb_done_value,

    // with predictor
    output wire [LOCAL_WIDTH-1: 0] predict_addr,  // LOCAL_WIDTH bits in instruction address for selecting counter group
    input wire predict_jump,  // 1 for jumping, 0 for continuing

    // issue an instr to RS
    output reg rs_issue_signal,  // 1 for issuing
    output reg [3:0] rs_opcode,
    output reg [31:0] rs_value_rs1,
    output reg [31:0] rs_value_rs2,
    output reg [ROB_WIDTH-1:0] rs_tag_rs1,
    output reg [ROB_WIDTH-1:0] rs_tag_rs2,
    output reg rs_valid_rs1,
    output reg rs_valid_rs2,
    output reg [ROB_WIDTH-1:0] rs_tag_rd,

    // issue an instr to ROB
    output reg rob_issue_signal,  // 1 for issuing
    output reg rob_value_ready,  // 1 for ready value
    output reg [1:0] rob_opcode,
    output reg [31:0] rob_value,
    output reg [4:0] rob_rd_id,
    output reg [31:0] rob_pc_prediction,  // for JALR (PC+4 is in issue_value)

    // issue an instr to LSB
    output reg lsb_issue_signal,  // 1 for issuing
    output reg lsb_wr,  // 1 for store, 0 for load
    output reg lsb_signed,  // 1 for signed load, 0 for unsigned load
    output reg [1:0] lsb_len,
    output reg [31:0] lsb_addr,
    output reg [31:0] lsb_value,
    output reg [11:0] lsb_offset,
    output reg [ROB_WIDTH-1:0] lsb_tag_addr,
    output reg [ROB_WIDTH-1:0] lsb_tag_value,
    output reg [ROB_WIDTH-1:0] lsb_tag_rd,
    output reg lsb_valid_addr,  // 1 for addr valid (tag is invalid)
    output reg lsb_valid_value,

    input wire clear_signal,  // 1 for error prediction
    input wire [31:0] correct_pc
);
  reg [31:0] pc;

  assign fetch_signal = ~rob_full & ~rs_full & ~lsb_full;  // stop fetching when rob/rs/lsb is full
  assign fetch_addr = pc;

  assign rf_signal = fetch_done & ~rob_full & ~rs_full & ~lsb_full & ~(fetch_instr[5:0] == 6'b100011);  // 1 when issuing to RF in this cycle
  assign rf_id_rs1 = fetch_instr[19:15];
  assign rf_id_rs2 = fetch_instr[24:20];
  assign rf_id_rd = fetch_instr[11:7];
  assign rf_tag_rd = rob_issue_signal ? rob_index + 1 : rob_index;

  assign rob_tag_rs1 = rf_tag_rs1;
  assign rob_tag_rs2 = rf_tag_rs2;

  assign predict_addr = pc[LOCAL_WIDTH+1:2];

  wire [31:0] pc_next_without_jump;
  wire [31:0] pc_next_with_jump;

  assign pc_next_without_jump = pc + 4;
  assign pc_next_with_jump = pc + {{20{fetch_instr[31]}}, fetch_instr[7], fetch_instr[30:25], fetch_instr[11:8], 1'b0}; // for BR's pc jumping address

  // the value and validation of rs-reg according to RF and ROB
  wire [31:0] value_rs1;
  wire [31:0] value_rs2;
  wire hit_rob_last_issue_rs1; // if value is in the issuing last cycle (write into ROB this cycle, so it cannot be found if not forwarding)
  wire hit_rob_last_issue_rs2;
  assign hit_rob_last_issue_rs1 = rob_issue_signal & ~rf_valid_rs1 & rob_value_ready & (rob_index == rf_tag_rs1);
  assign hit_rob_last_issue_rs2 = rob_issue_signal & ~rf_valid_rs2 & rob_value_ready & (rob_index == rf_tag_rs2);
  assign value_rs1 = {32{rf_id_rs1 != 5'b00000}} & (({32{rf_valid_rs1}} & rf_value_rs1) | ({32{~rf_valid_rs1 & rob_ready_rs1}} & rob_value_rs1) | ({32{hit_rob_last_issue_rs1}} & rob_value));
  assign value_rs2 = {32{rf_id_rs2 != 5'b00000}} & (({32{rf_valid_rs2}} & rf_value_rs2) | ({32{~rf_valid_rs2 & rob_ready_rs2}} & rob_value_rs2) | ({32{hit_rob_last_issue_rs2}} & rob_value));
  assign valid_rs1 = (rf_id_rs1 == 5'b00000) | rf_valid_rs1 | rob_ready_rs1 | hit_rob_last_issue_rs1;
  assign valid_rs2 = (rf_id_rs2 == 5'b00000) | rf_valid_rs2 | rob_ready_rs2 | hit_rob_last_issue_rs2;

  always @(posedge clk_in) begin
    if (rst_in) begin
      pc <= 32'h00000000;
      rs_issue_signal <= 1'b0;
      rob_issue_signal <= 1'b0;
      lsb_issue_signal <= 1'b0;
      rob_value_ready <= 1'b0;
      rob_value <= 32'h00000000;
    end
  end

  always @(posedge clk_in) begin
    if (~rst_in & rdy_in & clear_signal) begin
      pc <= correct_pc;  // change next pc to correct pos
      rs_issue_signal <= 1'b0;  // stop issuing
      rob_issue_signal <= 1'b0;
      lsb_issue_signal <= 1'b0;
    end
  end

  always @(posedge clk_in) begin
    if (~rst_in & rdy_in & ~clear_signal) begin
      if (fetch_done & ~rob_full & ~rs_full & ~lsb_full) begin
        case (fetch_instr[6:0])
          7'b0110111: begin  // LUI
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_value_ready <= 1'b1;
            rob_value <= {fetch_instr[31:12], {12{1'b0}}};
            rob_rd_id <= rf_id_rd;
            rs_issue_signal <= 1'b0;
            lsb_issue_signal <= 1'b0;
          end
          7'b0010111: begin  // AUIPC
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_value_ready <= 1'b1;
            rob_value <= pc + {fetch_instr[31:12], {12{1'b0}}};
            rob_rd_id <= rf_id_rd;
            rs_issue_signal <= 1'b0;
            lsb_issue_signal <= 1'b0;
          end
          7'b1101111: begin  // JAL
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_value_ready <= 1'b1;
            rob_value <= pc + 4;
            rob_rd_id <= rf_id_rd;
            pc <= pc + {{12{fetch_instr[31]}}, fetch_instr[19:12], fetch_instr[20], fetch_instr[30:21], 1'b0};
            rs_issue_signal <= 1'b0;
            lsb_issue_signal <= 1'b0;
          end
          7'b1100111: begin  // JALR
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_JALR_INSTR;
            rob_value_ready <= 1'b0;
            rob_value <= pc + 4;
            rob_rd_id <= rf_id_rd;
            rob_pc_prediction <= (value_x1 + {{20{fetch_instr[31]}}, fetch_instr[31:20]}) & 32'hFFFCFFFE;
            pc <= (value_x1 + {{20{fetch_instr[31]}}, fetch_instr[31:20]}) & 32'hFFFCFFFE;
            rs_issue_signal <= 1'b1;
            rs_opcode <= `ALU_JALR;
            rs_value_rs2 <= {{20{fetch_instr[31]}}, fetch_instr[31:20]};
            rs_tag_rs1 <= rf_tag_rs1;
            rs_valid_rs2 <= 1'b1;
            rs_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                rs_value_rs1 <= alu1_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                rs_value_rs1 <= alu2_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                rs_value_rs1 <= lsb_done_value;
                rs_valid_rs1 <= 1'b1;
              end else begin
                rs_valid_rs1 <= 1'b0;
              end
            end else begin
              rs_value_rs1 <= value_rs1;
              rs_valid_rs1 <= 1'b1;
            end
            lsb_issue_signal <= 1'b0;
          end
          7'b1100011: begin  // BRANCH
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_BRANCH_INSTR;
            rob_value_ready <= 1'b0;
            rob_value[31:32-LOCAL_WIDTH] <= predict_addr;
            if (predict_jump) begin
              pc <= pc_next_with_jump;
              rob_value[31-LOCAL_WIDTH:2] <= pc_next_without_jump[31-LOCAL_WIDTH:2];
              rob_value[1:0] <= 2'b10;  // set rob_value[1] = 1 (predict-result)
            end else begin
              pc <= pc_next_without_jump;
              rob_value[31-LOCAL_WIDTH:2] <= pc_next_with_jump[31-LOCAL_WIDTH:2];
              rob_value[1:0] <= 2'b00;  // set rob_value[1] = 0 (predict-result)
            end
            rs_issue_signal <= 1'b1;
            rs_tag_rs1 <= rf_tag_rs1;
            rs_tag_rs2 <= rf_tag_rs2;
            rs_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                rs_value_rs1 <= alu1_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                rs_value_rs1 <= alu2_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                rs_value_rs1 <= lsb_done_value;
                rs_valid_rs1 <= 1'b1;
              end else begin
                rs_valid_rs1 <= 1'b0;
              end
            end else begin
              rs_value_rs1 <= value_rs1;
              rs_valid_rs1 <= 1'b1;
            end
            if (~valid_rs2) begin
              if (alu1_done_signal & (rf_tag_rs2 == alu1_done_tag)) begin
                rs_value_rs2 <= alu1_done_value;
                rs_valid_rs2 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs2 == alu2_done_tag)) begin
                rs_value_rs2 <= alu2_done_value;
                rs_valid_rs2 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs2 == lsb_done_tag)) begin
                rs_value_rs2 <= lsb_done_value;
                rs_valid_rs2 <= 1'b1;
              end else begin
                rs_valid_rs2 <= 1'b0;
              end
            end else begin
              rs_value_rs2 <= value_rs2;
              rs_valid_rs2 <= 1'b1;
            end
            case (fetch_instr[14:12])
              3'b000: begin
                rs_opcode <= `ALU_EQ;
              end
              3'b001: begin
                rs_opcode <= `ALU_NE;
              end
              3'b100: begin
                rs_opcode <= `ALU_LT;
              end
              3'b101: begin
                rs_opcode <= `ALU_GE;
              end
              3'b110: begin
                rs_opcode <= `ALU_LTU;
              end
              3'b111: begin
                rs_opcode <= `ALU_GEU;
              end
            endcase
            lsb_issue_signal <= 1'b0;
          end
          7'b0000011: begin  // LOAD
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_rd_id <= rf_id_rd;
            rob_value_ready <= 1'b0;
            rs_issue_signal <= 1'b0;
            lsb_issue_signal <= 1'b1;
            lsb_wr <= 1'b0;
            lsb_signed <= ~fetch_instr[14];
            lsb_offset <= fetch_instr[31:20];
            lsb_tag_addr <= rf_tag_rs1;
            lsb_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                lsb_addr <= alu1_done_value;
                lsb_valid_addr <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                lsb_addr <= alu2_done_value;
                lsb_valid_addr <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                lsb_addr <= lsb_done_value;
                lsb_valid_addr <= 1'b1;
              end else begin
                lsb_valid_addr <= 1'b0;
              end
            end else begin
              lsb_addr <= value_rs1;
              lsb_valid_addr <= 1'b1;
            end
            case (fetch_instr[13:12])
              3'b00: begin
                lsb_len <= 2'b00;
              end
              3'b01: begin
                lsb_len <= 2'b01;
              end
              3'b10: begin
                lsb_len <= 2'b11;
              end
            endcase
          end
          7'b0100011: begin  // STORE
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_STORE_INSTR;
            rob_value_ready <= 1'b1;
            rs_issue_signal <= 1'b0;
            lsb_issue_signal <= 1'b1;
            lsb_wr <= 1'b1;
            lsb_offset <= {fetch_instr[31:25], fetch_instr[11:7]};
            lsb_tag_addr <= rf_tag_rs1;
            lsb_tag_value <= rf_tag_rs2;
            lsb_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                lsb_addr <= alu1_done_value;
                lsb_valid_addr <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                lsb_addr <= alu2_done_value;
                lsb_valid_addr <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                lsb_addr <= lsb_done_value;
                lsb_valid_addr <= 1'b1;
              end else begin
                lsb_valid_addr <= 1'b0;
              end
            end else begin
              lsb_addr <= value_rs1;
              lsb_valid_addr <= 1'b1;
            end
            if (~valid_rs2) begin
              if (alu1_done_signal & (rf_tag_rs2 == alu1_done_tag)) begin
                lsb_value <= alu1_done_value;
                lsb_valid_value <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs2 == alu2_done_tag)) begin
                lsb_value <= alu2_done_value;
                lsb_valid_value <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs2 == lsb_done_tag)) begin
                lsb_value <= lsb_done_value;
                lsb_valid_value <= 1'b1;
              end else begin
                lsb_valid_value <= 1'b0;
              end
            end else begin
              lsb_value <= value_rs2;
              lsb_valid_value <= 1'b1;
            end
            case (fetch_instr[13:12])
              3'b00: begin
                lsb_len <= 2'b00;
              end
              3'b01: begin
                lsb_len <= 2'b01;
              end
              3'b10: begin
                lsb_len <= 2'b11;
              end
            endcase
          end
          7'b0010011: begin
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_rd_id <= rf_id_rd;
            rob_value_ready <= 1'b0;
            rs_issue_signal <= 1'b1;
            rs_value_rs2 <= {{20{fetch_instr[31]}}, fetch_instr[31:20]};
            rs_tag_rs1 <= rf_tag_rs1;
            rs_valid_rs2 <= 1'b1;
            rs_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                rs_value_rs1 <= alu1_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                rs_value_rs1 <= alu2_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                rs_value_rs1 <= lsb_done_value;
                rs_valid_rs1 <= 1'b1;
              end else begin
                rs_valid_rs1 <= 1'b0;
              end
            end else begin
              rs_value_rs1 <= value_rs1;
              rs_valid_rs1 <= 1'b1;
            end
            case (fetch_instr[14:12])
              3'b000: begin
                rs_opcode <= `ALU_ADD;
              end
              3'b001: begin
                rs_opcode <= `ALU_SLL;
              end
              3'b010: begin
                rs_opcode <= `ALU_LT;
              end
              3'b011: begin
                rs_opcode <= `ALU_LTU;
              end
              3'b100: begin
                rs_opcode <= `ALU_XOR;
              end
              3'b101: begin
                rs_opcode <= fetch_instr[30] ? `ALU_SRA : `ALU_SRL;
              end
              3'b110: begin
                rs_opcode <= `ALU_OR;
              end
              3'b111: begin
                rs_opcode <= `ALU_AND;
              end
            endcase
            lsb_issue_signal <= 1'b0;
          end
          7'b0110011: begin
            pc <= pc + 4;
            rob_issue_signal <= 1'b1;
            rob_opcode <= `ROB_REG_INSTR;
            rob_rd_id <= rf_id_rd;
            rob_value_ready <= 1'b0;
            rs_issue_signal <= 1'b1;
            rs_tag_rs1 <= rf_tag_rs1;
            rs_tag_rs2 <= rf_tag_rs2;
            rs_tag_rd <= rf_tag_rd;
            if (~valid_rs1) begin
              if (alu1_done_signal & (rf_tag_rs1 == alu1_done_tag)) begin
                rs_value_rs1 <= alu1_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs1 == alu2_done_tag)) begin
                rs_value_rs1 <= alu2_done_value;
                rs_valid_rs1 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs1 == lsb_done_tag)) begin
                rs_value_rs1 <= lsb_done_value;
                rs_valid_rs1 <= 1'b1;
              end else begin
                rs_valid_rs1 <= 1'b0;
              end
            end else begin
              rs_value_rs1 <= value_rs1;
              rs_valid_rs1 <= 1'b1;
            end
            if (~valid_rs2) begin
              if (alu1_done_signal & (rf_tag_rs2 == alu1_done_tag)) begin
                rs_value_rs2 <= alu1_done_value;
                rs_valid_rs2 <= 1'b1;
              end else if (alu2_done_signal & (rf_tag_rs2 == alu2_done_tag)) begin
                rs_value_rs2 <= alu2_done_value;
                rs_valid_rs2 <= 1'b1;
              end else if (lsb_done_signal & (rf_tag_rs2 == lsb_done_tag)) begin
                rs_value_rs2 <= lsb_done_value;
                rs_valid_rs2 <= 1'b1;
              end else begin
                rs_valid_rs2 <= 1'b0;
              end
            end else begin
              rs_value_rs2 <= value_rs2;
              rs_valid_rs2 <= 1'b1;
            end
            case (fetch_instr[14:12])
              3'b000: begin
                rs_opcode <= fetch_instr[30] ? `ALU_SUB : `ALU_ADD;
              end
              3'b010: begin
                rs_opcode <= `ALU_LT;
              end
              3'b011: begin
                rs_opcode <= `ALU_LTU;
              end
              3'b100: begin
                rs_opcode <= `ALU_XOR;
              end
              3'b110: begin
                rs_opcode <= `ALU_OR;
              end
              3'b111: begin
                rs_opcode <= `ALU_AND;
              end
              3'b001: begin
                rs_opcode <= `ALU_SLL;
              end
              3'b101: begin
                rs_opcode <= fetch_instr[30] ? `ALU_SRA : `ALU_SRL;
              end
            endcase
            lsb_issue_signal <= 1'b0;
          end
        endcase
      end else begin
        rob_issue_signal <= 1'b0;
        rs_issue_signal  <= 1'b0;
        lsb_issue_signal <= 1'b0;
      end
    end
  end

  // integer f;
  //   initial begin
  //    f= $fopen("f");
  //   end

  //     integer i;
  //   always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
  //     if (~rst_in & rdy_in) begin  // 0th reg cannot be modified
  //      $fdisplay(f,"%h",pc);
  //     end
  //   end
endmodule
