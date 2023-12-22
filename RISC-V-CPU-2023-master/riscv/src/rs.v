`define REG_WIDTH 32
`define OPCODE_ALU_WIDTH 4

module reservation_station #(
    parameter RS_WIDTH  = 4,
    parameter ROB_WIDTH = 4,
    parameter RS_SIZE   = 2 ** RS_WIDTH
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire clear_signal,  // 1 for prediction error

    //issued instr from instr fetch
    input wire issue,  // 1 for issuing instruction 
    input wire [`OPCODE_ALU_WIDTH-1 : 0] opcode_issue,
    input wire [`REG_WIDTH-1 : 0] rs_issue_value_1,
    input wire [`REG_WIDTH-1 : 0] rs_issue_value_2,
    input wire [ROB_WIDTH-1 : 0] rs_issue_tag_1,
    input wire [ROB_WIDTH-1 : 0] rs_issue_tag_2,
    input wire rs_issue_valid_1,
    input wire rs_issue_valid_2,
    input wire [ROB_WIDTH-1 : 0] rd_issue_tag,

    //output data for ALU calculating, supporting two ALUs
    output reg busy_alu_1,  // 1 for sending calulating task to ALU
    output reg busy_alu_2,  // 1 for sending calulating task to ALU
    output reg [`OPCODE_ALU_WIDTH-1:0] opcode_alu_1,
    output reg [`OPCODE_ALU_WIDTH-1:0] opcode_alu_2,
    output reg [`REG_WIDTH-1 : 0] lhs_alu_1,
    output reg [`REG_WIDTH-1 : 0] lhs_alu_2,
    output reg [`REG_WIDTH-1 : 0] rhs_alu_1,
    output reg [`REG_WIDTH-1 : 0] rhs_alu_2,
    output reg [ROB_WIDTH-1:0] rd_tag_alu_1,
    output reg [ROB_WIDTH-1:0] rd_tag_alu_2,

    // results from ALU, flushing rs
    input wire done_alu_1,  // 1 for ALU done
    input wire done_alu_2,  // 1 for ALU done
    input wire [`REG_WIDTH-1 : 0] value_alu_1,
    input wire [`REG_WIDTH-1 : 0] value_alu_2,
    input wire [ROB_WIDTH-1 : 0] tag_alu_1,
    input wire [ROB_WIDTH-1 : 0] tag_alu_2,

    output wire full  // 1 for RS is full
);

  //RS lines
  reg busy[RS_SIZE-1:0];  // 1 for busy
  reg [`OPCODE_ALU_WIDTH-1 : 0] opcode[RS_SIZE-1:0];  // opcode for ALU calculation categories
  reg [`REG_WIDTH-1 : 0] rs_value_1[RS_SIZE-1:0];
  reg [`REG_WIDTH-1 : 0] rs_value_2[RS_SIZE-1:0];
  reg [ROB_WIDTH-1 : 0] rs_tag_1[RS_SIZE-1:0];
  reg [ROB_WIDTH-1 : 0] rs_tag_2[RS_SIZE-1:0];
  reg rs_valid_1[RS_SIZE-1:0];  // 1 for rs_1 value is valid
  reg rs_valid_2[RS_SIZE-1:0];  // 1 for rs_2 value is valid
  reg [ROB_WIDTH-1 : 0] rd_tag[RS_SIZE-1:0];
  wire [RS_WIDTH-1 : 0] free_pos;  // free position when RS is not full 

  // assign to get the free position in RS
  // if first line is free, select_pos is set to its index; else if second line is free, select_pos is set to its index
  // if both lines are busy, set valid_pos to 0; else set it to 1
  genvar i_select;
  generate
    wire [RS_WIDTH-1:0] select_pos[RS_SIZE-1:1];
    wire valid_pos[RS_SIZE-1:1];  //1 for valid(free)
    for (i_select = RS_SIZE / 2; i_select < RS_SIZE; i_select = i_select + 1) begin
      assign tmp1 = (i_select - 8) << 1;
      assign tmp2 = tmp1 + 1;
      assign select_pos[i_select] = ({RS_WIDTH{~busy[tmp1]}} & tmp1) |
                                    ({RS_WIDTH{busy[tmp1]}} & {RS_WIDTH{~busy[tmp2]}} & tmp2);
      assign valid_pos[i_select] = ~busy[tmp1] | ~busy[tmp2];
    end
    for (i_select = 1; i_select < RS_SIZE / 2; i_select = i_select + 1) begin
      assign tmp1 = i_select << 1;
      assign tmp2 = tmp1 + 1;
      assign select_pos[i_select] = ({RS_WIDTH{~valid_pos[tmp1]}} & select_pos[tmp1]) |
                                    ({RS_WIDTH{valid_pos[tmp1]}} & {RS_WIDTH{~valid_pos[tmp2]}} & select_pos[tmp2]);
      assign valid_pos[i_select] = ~(valid_pos[tmp1] & valid_pos[tmp2]);
    end
    assign full = valid_pos[1];
    assign free_pos = select_pos[1];
  endgenerate

  integer i_reset;
  always @(posedge clk_in) begin  // reset register file
    if (rst_in | (rdy_in & clear_signal)) begin
      for (i_reset = 0; i_reset < RS_SIZE; i_reset = i_reset + 1) begin
        busy[i_reset]       <= 1'b0;
        rs_valid_1[i_reset] <= 1'b0;
        rs_valid_2[i_reset] <= 1'b0;
        busy_alu_1          <= 1'b0;
        busy_alu_2          <= 1'b0;
      end
    end
  end

  always @(posedge clk_in) begin  // issue an instruction, noticting the forwarding of ALU results
    if (rdy_in & issue) begin
      busy[free_pos]   <= 1'b1;
      opcode[free_pos] <= opcode_issue;
      rd_tag[free_pos] <= rd_issue_tag;
      if (done_alu_1 & (tag_alu_1 == rs_tag_1[free_pos])) begin  // forwarding
        rs_value_1[free_pos] <= value_alu_1;
        rs_valid_1[free_pos] <= 1'b1;
      end else if (done_alu_2 & (tag_alu_2 == rs_tag_1[free_pos])) begin  // forwarding
        rs_value_1[free_pos] <= value_alu_2;
        rs_valid_1[free_pos] <= 1'b1;
      end else begin
        rs_value_1[free_pos] <= rs_issue_value_1;
        rs_tag_1[free_pos]   <= rs_issue_tag_1;
        rs_valid_1[free_pos] <= rs_issue_valid_1;
      end
      if (done_alu_1 & (tag_alu_1 == rs_tag_2[free_pos])) begin  // forwarding
        rs_value_2[free_pos] <= value_alu_1;
        rs_valid_2[free_pos] <= 1'b1;
      end else if (done_alu_2 & (tag_alu_2 == rs_tag_2[free_pos])) begin  // forwarding
        rs_value_2[free_pos] <= value_alu_2;
        rs_valid_2[free_pos] <= 1'b1;
      end else begin
        rs_value_2[free_pos] <= rs_issue_value_2;
        rs_tag_2[free_pos]   <= rs_issue_tag_2;
        rs_valid_2[free_pos] <= rs_issue_valid_2;
      end
    end
  end

  integer i_alu_1;
  always @(posedge clk_in) begin  // flush rs values according to the ALU1 result
    if (rdy_in & done_alu_1) begin
      busy_alu_1 <= 1'b0;  // reset alu to free status
      for (i_alu_1 = 0; i_alu_1 < RS_SIZE; i_alu_1 = i_alu_1 + 1) begin
        if (busy[i_alu_1]) begin
          if (~rs_valid_1[i_alu_1] && (rs_tag_1[i_alu_1] == tag_alu_1)) begin
            rs_valid_1[i_alu_1] <= 1'b1;
            rs_value_1[i_alu_1] <= value_alu_1;
          end
          if (~rs_valid_2[i_alu_1] && (rs_tag_2[i_alu_1] == tag_alu_1)) begin
            rs_valid_2[i_alu_1] <= 1'b1;
            rs_value_2[i_alu_1] <= value_alu_1;
          end
        end
      end
    end
  end

  integer i_alu_2;
  always @(posedge clk_in) begin  // flush rs values according to the ALU2 result
    if (rdy_in & done_alu_2) begin
      busy_alu_1 <= 1'b0;  // reset alu to free status
      for (i_alu_2 = 0; i_alu_2 < RS_SIZE; i_alu_2 = i_alu_2 + 1) begin
        if (busy[i_alu_2]) begin
          if (~rs_valid_1[i_alu_2] && (rs_tag_1[i_alu_2] == tag_alu_2)) begin
            rs_valid_1[i_alu_2] <= 1'b1;
            rs_value_1[i_alu_2] <= value_alu_2;
          end
          if (~rs_valid_2[i_alu_2] && (rs_tag_2[i_alu_2] == tag_alu_2)) begin
            rs_valid_2[i_alu_2] <= 1'b1;
            rs_value_2[i_alu_2] <= value_alu_2;
          end
        end
      end
    end
  end

  // as tag&data are updated when ALU send back the result, updating when committing is unnecessary
  integer i_alu;
  always @(posedge clk_in) begin  // send valid instr to ALU when ALU is free, and free the RS line at the same time
    if (rdy_in) begin
      for (i_alu = 0; i_alu < RS_SIZE; i_alu = i_alu + 1) begin
        if (rs_valid_1[i_alu] & rs_valid_2[i_alu]) begin
          if (~busy_alu_1) begin  // calculate in ALU1
            busy_alu_1    = 1'b1; // block assignment, avoiding more than one lines sending data to ALU at the same time
            busy[i_alu]  <= 1'b0;
            opcode_alu_1 <= opcode[i_alu];
            lhs_alu_1    <= rs_value_1[i_alu];
            rhs_alu_1    <= rs_valid_2[i_alu];
            rd_tag_alu_1 <= rd_tag[i_alu];
          end else if (~busy_alu_2) begin  // calculate in ALU2
            busy_alu_2    = 1'b1; // block assignment, avoiding more than one lines sending data to ALU at the same time
            busy[i_alu]  <= 1'b0;
            opcode_alu_2 <= opcode[i_alu];
            lhs_alu_2    <= rs_value_1[i_alu];
            rhs_alu_2    <= rs_valid_2[i_alu];
            rd_tag_alu_2 <= rd_tag[i_alu];
          end
        end
      end
    end
  end

endmodule
