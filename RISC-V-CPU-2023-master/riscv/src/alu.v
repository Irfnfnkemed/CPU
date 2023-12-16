`define REG_WIDTH 32
`define OPCODE_ALU_WIDTH 4
`define OPCODE_ALU_SIZE 16
`define AND 4'd1
`define OR 4'd2
`define XOR 4'd3
`define ADD 4'd4
`define SUB 4'd5
`define SRL 4'd6
`define SRA 4'd7
`define SLL 4'd8
`define LT 4'd9
`define LTU 4'd10
`define EQ 4'd11
`define NE 4'd12
`define GE 4'd13
`define GEU 4'd14
`define JALR 4'd15

module alu #(
    parameter ROB_WIDTH = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    //calculate data from RS
    input wire cal_signal,  // 1 for calulating
    input wire [`OPCODE_ALU_WIDTH-1:0] opcode,
    input wire [`REG_WIDTH-1 : 0] lhs,
    input wire [`REG_WIDTH-1 : 0] rhs,
    input wire [ROB_WIDTH-1:0] tag,

    //return result to RS
    output reg done_rs,
    output reg [`REG_WIDTH-1 : 0] result_rs,
    output reg [ROB_WIDTH-1:0] tag_rs,

    //send result to LSB
    output reg done_lsb,
    output reg [`REG_WIDTH-1 : 0] result_lsb,
    output reg [ROB_WIDTH-1:0] tag_lsb,

    //send result to ROB
    output reg done_rob,
    output reg [`REG_WIDTH-1 : 0] result_rob,
    output reg [ROB_WIDTH-1:0] tag_rob
);


  wire [`REG_WIDTH-1 : 0] caculate[`OPCODE_ALU_SIZE-1:0];

  assign caculate[`AND]  = lhs & rhs;
  assign caculate[`OR]   = lhs | rhs;
  assign caculate[`XOR]  = lhs ^ rhs;
  assign caculate[`ADD]  = lhs + rhs;
  assign caculate[`SUB]  = lhs - rhs;
  assign caculate[`SRL]  = lhs >> rhs[4:0];
  assign caculate[`SRA]  = lhs >>> rhs[4:0];
  assign caculate[`SLL]  = lhs << rhs[4:0];
  assign caculate[`LT]   = {`REG_WIDTH{$signed(lhs) < $signed(rhs)}};
  assign caculate[`LTU]  = {`REG_WIDTH{lhs < rhs}};
  assign caculate[`EQ]   = {`REG_WIDTH{lhs == rhs}};
  assign caculate[`NE]   = {`REG_WIDTH{lhs != rhs}};
  assign caculate[`GE]   = {`REG_WIDTH{$signed(lhs) >= $signed(rhs)}};
  assign caculate[`GEU]  = {`REG_WIDTH{lhs >= rhs}};
  assign caculate[`JALR] = (lhs + rhs) & {{`REG_WIDTH - 1{1'b1}}, 1'b0};

  always @(posedge clk_in) begin  // reset alu status to free
    if (rst_in) begin
      done_rs  <= 1'b0;
      done_rob <= 1'b0;
      done_lsb <= 1'b0;
    end
  end

  always @(posedge clk_in) begin  // send the result
    if (rdy_in) begin
      if (cal_signal) begin
        done_rs <= 1'b1;
        done_rob <= 1'b1;
        done_lsb <= 1'b1;
        result_rs <= caculate[opcode];
        result_rob <= caculate[opcode];
        result_lsb <= caculate[opcode];
        tag_rs <= tag;
        tag_rob <= tag;
        tag_lsb <= tag;
      end
    end
  end

  always @(posedge clk_in) begin  // handle done signal, avoiding flush RS/ROB more than one time
    if (rdy_in) begin
      if (done_rs) begin
        done_rs <= 1'b0;
      end
      if (done_rob) begin
        done_rob <= 1'b0;
      end
      if (done_lsb) begin
        done_lsb <= 1'b0;
      end
    end
  end


endmodule
