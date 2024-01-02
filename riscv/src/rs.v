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
    input wire [3:0] opcode_issue,
    input wire [31:0] rs_issue_value_1,
    input wire [31:0] rs_issue_value_2,
    input wire [ROB_WIDTH-1:0] rs_issue_tag_1,
    input wire [ROB_WIDTH-1:0] rs_issue_tag_2,
    input wire rs_issue_valid_1,
    input wire rs_issue_valid_2,
    input wire [ROB_WIDTH-1:0] rd_issue_tag,

    //output data for ALU calculating, supporting two ALUs
    output reg busy_alu_1,  // 1 for sending calulating task to ALU1
    output reg busy_alu_2,  // 1 for sending calulating task to ALU2
    output reg [3:0] opcode_alu_1,
    output reg [3:0] opcode_alu_2,
    output reg [31:0] lhs_alu_1,
    output reg [31:0] lhs_alu_2,
    output reg [31:0] rhs_alu_1,
    output reg [31:0] rhs_alu_2,
    output reg [ROB_WIDTH-1:0] rd_tag_alu_1,
    output reg [ROB_WIDTH-1:0] rd_tag_alu_2,

    // results from ALU, flushing RS
    input wire done_alu_1,  // 1 for ALU done
    input wire done_alu_2,  // 1 for ALU done
    input wire [31:0] value_alu_1,
    input wire [31:0] value_alu_2,
    input wire [ROB_WIDTH-1:0] tag_alu_1,
    input wire [ROB_WIDTH-1:0] tag_alu_2,

    // results from LSB loading, flushing RS
    input wire done_lsb,
    input wire [31:0] value_lsb,
    input wire [ROB_WIDTH-1:0] tag_lsb,

    // results from ROB committing, flushing RS
    input wire done_commit,
    input wire [31:0] value_commit,
    input wire [ROB_WIDTH-1:0] tag_commit,

    output wire full  // 1 for RS is full
);

  //RS lines
  reg busy[RS_SIZE-1:0];  // 1 for busy
  reg [3:0] opcode[RS_SIZE-1:0];  // opcode for ALU calculation categories
  reg [31:0] rs_value_1[RS_SIZE-1:0];
  reg [31:0] rs_value_2[RS_SIZE-1:0];
  reg [ROB_WIDTH-1:0] rs_tag_1[RS_SIZE-1:0];
  reg [ROB_WIDTH-1:0] rs_tag_2[RS_SIZE-1:0];
  reg rs_valid_1[RS_SIZE-1:0];  // 1 for rs_1 value is valid
  reg rs_valid_2[RS_SIZE-1:0];  // 1 for rs_2 value is valid
  reg [ROB_WIDTH-1:0] rd_tag[RS_SIZE-1:0];
  wire [RS_WIDTH-1:0] free_pos;  // free position when RS is not full
  wire [RS_WIDTH-1:0] valid_alu1_pos;  // valid position for ALU1 to calculate
  wire [RS_WIDTH-1:0] valid_alu2_pos;  // valid position for ALU2 to calculate
  wire valid_alu1;  // validity of valid_alu1_pos
  wire valid_alu2;  // validity of valid_alu2_pos

  wire ttt=rs_valid_2[2];

  // assign to get the free position in RS and the position which could be calculated
  // if first line is free, select_pos is set to its index; else if second line is free, select_pos is set to its index
  // if both lines are busy, set valid_pos to 0; else set it to 1
  // if first line is valid for calculating, select_alu_pos is set to its index; else if second line is valid for calculating, select_alu_pos is set to its index
  // if both lines are invalid for calculating, set valid_alu_pos to 0; else set it to 1
  // for ALU1, calculating line index range: [0, RS_SIZE/2-1] ; for ALU2,calculating line index range: [RS_SIZE/2 , RS_SIZE-1]
  `define tmp1 (i_select - 8) << 1
  `define tmp2 1 + ((i_select - 8) << 1)
  `define tmp3 i_select << 1
  `define tmp4 1 + (i_select << 1)
  genvar i_select;
  generate
    wire [RS_WIDTH-1:0] select_pos[RS_SIZE-1:1];
    wire valid_pos[RS_SIZE-1:1];  // 1 for valid(free)
    wire [RS_WIDTH-1:0] select_alu_pos[RS_SIZE-1:1];
    wire valid_alu_pos[RS_SIZE-1:1];  // 1 for valid
    wire valid_cal[RS_SIZE-1:0];  // 1 for valid to calculate
    for (i_select = RS_SIZE / 2; i_select < RS_SIZE; i_select = i_select + 1) begin
      assign select_pos[i_select] = ({RS_WIDTH{~busy[`tmp1]}} & `tmp1) |
                                    ({RS_WIDTH{busy[`tmp1]}} & {RS_WIDTH{~busy[`tmp2]}} & `tmp2);
      assign valid_pos[i_select] = ~busy[`tmp1] | ~busy[`tmp2];
    end
    for (i_select = 1; i_select < RS_SIZE / 2; i_select = i_select + 1) begin
      assign select_pos[i_select] = ({RS_WIDTH{valid_pos[`tmp3]}} & select_pos[`tmp3]) |
                                    ({RS_WIDTH{~valid_pos[`tmp3]}} & {RS_WIDTH{valid_pos[`tmp4]}} & select_pos[`tmp4]);
      assign valid_pos[i_select] = valid_pos[`tmp3] | valid_pos[`tmp4];
    end

    for (i_select = 0; i_select < RS_SIZE; i_select = i_select + 1) begin
      assign valid_cal[i_select] = busy[i_select] & rs_valid_1[i_select] & rs_valid_2[i_select];
    end

    for (i_select = RS_SIZE / 2; i_select < RS_SIZE; i_select = i_select + 1) begin
      assign select_alu_pos[i_select] = ({RS_WIDTH{valid_cal[`tmp1]}} & `tmp1) |
                                    ({RS_WIDTH{~valid_cal[`tmp1]}} & {RS_WIDTH{valid_cal[`tmp2]}} & `tmp2);
      assign valid_alu_pos[i_select] = valid_cal[`tmp1] | valid_cal[`tmp2];
    end
    for (i_select = 2; i_select < RS_SIZE / 2; i_select = i_select + 1) begin
      assign select_alu_pos[i_select] = ({RS_WIDTH{valid_alu_pos[`tmp3]}} & select_alu_pos[`tmp3]) |
                                    ({RS_WIDTH{~valid_alu_pos[`tmp3]}} & {RS_WIDTH{valid_alu_pos[`tmp4]}} & select_alu_pos[`tmp4]);
      assign valid_alu_pos[i_select] = valid_alu_pos[`tmp3] | valid_alu_pos[`tmp4];
    end
    assign full = ~valid_pos[1];
    assign free_pos = select_pos[1];
    assign valid_alu1_pos = select_alu_pos[2];
    assign valid_alu2_pos = select_alu_pos[3];
    assign valid_alu1 = valid_alu_pos[2];
    assign valid_alu2 = valid_alu_pos[3];
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
    if (~rst_in & rdy_in & issue & ~clear_signal) begin
      busy[free_pos]   <= 1'b1;
      opcode[free_pos] <= opcode_issue;
      rd_tag[free_pos] <= rd_issue_tag;
      if (done_alu_1 & ~rs_issue_valid_1 & (tag_alu_1 == rs_issue_tag_1)) begin  // forwarding
        rs_value_1[free_pos] <= value_alu_1;
        rs_valid_1[free_pos] <= 1'b1;
      end else if (done_alu_2 & ~rs_issue_valid_1 & (tag_alu_2 == rs_issue_tag_1)) begin  // forwarding
        rs_value_1[free_pos] <= value_alu_2;
        rs_valid_1[free_pos] <= 1'b1;
      end else if (done_lsb & ~rs_issue_valid_1 & (tag_lsb == rs_issue_tag_1)) begin  // forwarding
        rs_value_1[free_pos] <= value_lsb;
        rs_valid_1[free_pos] <= 1'b1;
      end else begin
        rs_value_1[free_pos] <= rs_issue_value_1;
        rs_tag_1[free_pos]   <= rs_issue_tag_1;
        rs_valid_1[free_pos] <= rs_issue_valid_1;
      end
      if (done_alu_1 & ~rs_issue_valid_2 & (tag_alu_1 == rs_issue_tag_2)) begin  // forwarding
        rs_value_2[free_pos] <= value_alu_1;
        rs_valid_2[free_pos] <= 1'b1;
      end else if (done_alu_2 & ~rs_issue_valid_2 & (tag_alu_2 == rs_issue_tag_2)) begin  // forwarding
        rs_value_2[free_pos] <= value_alu_2;
        rs_valid_2[free_pos] <= 1'b1;
      end else if (done_lsb & ~rs_issue_valid_2 & (tag_lsb == rs_issue_tag_2)) begin  // forwarding
        rs_value_2[free_pos] <= value_lsb;
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
    if (~rst_in & rdy_in & done_alu_1 & ~clear_signal) begin
      busy_alu_1 <= 1'b0;  // reset alu to free status
      for (i_alu_1 = 0; i_alu_1 < RS_SIZE; i_alu_1 = i_alu_1 + 1) begin
        if (busy[i_alu_1]) begin
          if (~rs_valid_1[i_alu_1] & (rs_tag_1[i_alu_1] == tag_alu_1)) begin
            rs_valid_1[i_alu_1] <= 1'b1;
            rs_value_1[i_alu_1] <= value_alu_1;
          end
          if (~rs_valid_2[i_alu_1] & (rs_tag_2[i_alu_1] == tag_alu_1)) begin
            rs_valid_2[i_alu_1] <= 1'b1;
            rs_value_2[i_alu_1] <= value_alu_1;
          end
        end
      end
    end
  end

  integer i_alu_2;
  always @(posedge clk_in) begin  // flush rs values according to the ALU2 result
    if (~rst_in & rdy_in & done_alu_2 & ~clear_signal) begin
      busy_alu_2 <= 1'b0;  // reset alu to free status
      for (i_alu_2 = 0; i_alu_2 < RS_SIZE; i_alu_2 = i_alu_2 + 1) begin
        if (busy[i_alu_2]) begin
          if (~rs_valid_1[i_alu_2] & (rs_tag_1[i_alu_2] == tag_alu_2)) begin
            rs_valid_1[i_alu_2] <= 1'b1;
            rs_value_1[i_alu_2] <= value_alu_2;
          end
          if (~rs_valid_2[i_alu_2] & (rs_tag_2[i_alu_2] == tag_alu_2)) begin
            rs_valid_2[i_alu_2] <= 1'b1;
            rs_value_2[i_alu_2] <= value_alu_2;
          end
        end
      end
    end
  end

  integer i_lsb;
  always @(posedge clk_in) begin  // flush rs values according to the LSB result
    if (~rst_in & rdy_in & done_lsb & ~clear_signal) begin
      for (i_lsb = 0; i_lsb < RS_SIZE; i_lsb = i_lsb + 1) begin
        if (busy[i_lsb]) begin
          if (~rs_valid_1[i_lsb] & (rs_tag_1[i_lsb] == tag_lsb)) begin
            rs_valid_1[i_lsb] <= 1'b1;
            rs_value_1[i_lsb] <= value_lsb;
          end
          if (~rs_valid_2[i_lsb] & (rs_tag_2[i_lsb] == tag_lsb)) begin
            rs_valid_2[i_lsb] <= 1'b1;
            rs_value_2[i_lsb] <= value_lsb;
          end
        end
      end
    end
  end

  integer i_commit;
  always @(posedge clk_in) begin  // flush rs values according to the ROB result
    if (~rst_in & rdy_in & done_commit & ~clear_signal) begin
      for (i_commit = 0; i_commit < RS_SIZE; i_commit = i_commit + 1) begin
        if (busy[i_commit]) begin
          if (~rs_valid_1[i_commit] & (rs_tag_1[i_commit] == tag_commit)) begin
            rs_valid_1[i_commit] <= 1'b1;
            rs_value_1[i_commit] <= value_commit;
          end
          if (~rs_valid_2[i_commit] & (rs_tag_2[i_commit] == tag_commit)) begin
            rs_valid_2[i_commit] <= 1'b1;
            rs_value_2[i_commit] <= value_commit;
          end
        end
      end
    end
  end

  // as tag&data are updated when ALU send back the result, updating when committing is unnecessary
  always @(posedge clk_in) begin  // send valid instr to ALU when ALU is free, and free the RS line at the same time
    if (~rst_in & rdy_in & ~clear_signal) begin
      if (valid_alu1 & ~busy_alu_1) begin
        busy_alu_1           <= 1'b1;
        busy[valid_alu1_pos] <= 1'b0;
        opcode_alu_1         <= opcode[valid_alu1_pos];
        lhs_alu_1            <= rs_value_1[valid_alu1_pos];
        rhs_alu_1            <= rs_value_2[valid_alu1_pos];
        rd_tag_alu_1         <= rd_tag[valid_alu1_pos];
      end
      if (valid_alu2 & ~busy_alu_2) begin
        busy_alu_2           <= 1'b1;
        busy[valid_alu2_pos] <= 1'b0;
        opcode_alu_2         <= opcode[valid_alu2_pos];
        lhs_alu_2            <= rs_value_1[valid_alu2_pos];
        rhs_alu_2            <= rs_value_2[valid_alu2_pos];
        rd_tag_alu_2         <= rd_tag[valid_alu2_pos];
      end
    end
  end

endmodule
