`define NOP 4'd0
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

    input wire clear_signal,  // 1 for prediction error

    //calculate data from RS
    input wire cal_signal,  // 1 for calulating
    input wire [3:0] opcode,
    input wire [31:0] lhs,
    input wire [31:0] rhs,
    input wire [ROB_WIDTH-1:0] tag,

    //return result to RS, LSB, ROB and I_FETCH
    output reg done_result,
    output reg [31:0] value_result,
    output reg [ROB_WIDTH-1:0] tag_result
);


  wire [31:0] calculate[15:0];

  assign calculate[`AND]  = lhs & rhs;
  assign calculate[`OR]   = lhs | rhs;
  assign calculate[`XOR]  = lhs ^ rhs;
  assign calculate[`ADD]  = lhs + rhs;
  assign calculate[`SUB]  = lhs - rhs;
  assign calculate[`SRL]  = lhs >> rhs[4:0];
  assign calculate[`SRA]  = lhs >>> rhs[4:0];
  assign calculate[`SLL]  = lhs << rhs[4:0];
  assign calculate[`LT]   = {32{$signed(lhs) < $signed(rhs)}};
  assign calculate[`LTU]  = {32{lhs < rhs}};
  assign calculate[`EQ]   = {32{lhs == rhs}};
  assign calculate[`NE]   = {32{lhs != rhs}};
  assign calculate[`GE]   = {32{$signed(lhs) >= $signed(rhs)}};
  assign calculate[`GEU]  = {32{lhs >= rhs}};
  assign calculate[`JALR] = (lhs + rhs) & {{31{1'b1}}, 1'b0};

  always @(posedge clk_in) begin  // reset alu status to free
    if (rst_in | (rdy_in & clear_signal)) begin
      done_result <= 1'b0;
    end
  end

  always @(posedge clk_in) begin  // send the result
    if (~rst_in & rdy_in) begin
      if (cal_signal & ~done_result) begin // don't calculate one task for more than one time, because it won't do continuous calculation
        done_result  <= 1'b1;
        value_result <= calculate[opcode];
        tag_result   <= tag;
      end else begin
        done_result <= 1'b0;  // handle done signal, avoiding flush RS/LSB/ROB more than one time
      end
    end
  end

endmodule
