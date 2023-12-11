`define REG_SIZE 32
`define REG_WIDTH 5

module register_file #(
    parameter ROB_WIDTH = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    // from instr latch (issue)
    input wire instr_signal,  //1 for fetching registers
    input wire [REG_WIDTH-1:0] rs_id_1,
    input wire [REG_WIDTH-1:0] rs_id_2,
    output wire [REG_WIDTH-1:0] rs_data_1,
    output wire [REG_WIDTH-1:0] rs_data_2,
    output wire [ROB_WIDTH-1:0] rs_tag_1,
    output wire [ROB_WIDTH-1:0] rs_tag_2,
    output wire rs_valid_1,
    output wire rs_valid_2,
    input wire [REG_WIDTH-1:0] rd_id,
    input wire [ROB_WIDTH-1:0] rd_tag,  // overwrite the tag of rd

    // from rob (commit)
    input wire rob_commit_signal,  //1 for committing
    input wire [REG_WIDTH-1:0] commit_rd_data,
    input wire [ROB_WIDTH-1:0] commit_rd_tag
);

  reg [REG_WIDTH-1:0] regs[REG_SIZE-1:0];  // registers
  reg [ROB_WIDTH-1:0] tags[REG_SIZE-1:0];  // register tags
  reg valid[REG_SIZE-1:0];  // validation of get register data, 1 for valid (invalid tag), 0 for invalid(valid tag)

  assign sign_1 = rob_commit_signal & ~valid[rs_id_1] & (tags[rs_id_1] == commit_rd_tag);// 1 when rob commitment update rs1 at the same time
  assign sign_2 = rob_commit_signal & ~valid[rs_id_2] & (tags[rs_id_2] == commit_rd_tag);// 1 when rob commitment update rs2 at the same time
  assign rs_data_1 = ({REG_WIDTH{sign_1}} & commit_rd_data) | ({REG_WIDTH{~sign_1}} & regs[rs_id_1]) ; // fowarding when rob commitment update rs1 at the same time
  assign rs_data_2 = ({REG_WIDTH{sign_2}} & commit_rd_data) | ({REG_WIDTH{~sign_2}} & regs[rs_id_2]) ; // fowarding when rob commitment update rs2 at the same time
  assign rs_tag_1 = tags[rs_id_1];
  assign rs_tag_2 = tags[rs_id_2];
  assign rs_valid_1 = sign_1 | (~sign_1 & valid[rs_id_1]);
  assign rs_valid_2 = sign_2 | (~sign_2 & valid[rs_id_2]);

  integer i;
  always @(posedge clk_in) begin  // reset register file
    if (rst_in) begin
      for (i = 0; i < REG_SIZE; i = i + 1) begin
        regs[i]  <= {REG_WIDTH{1'b0}};
        tags[i]  <= {ROB_WIDTH{1'b1}};
        valid[i] <= 1'b0;
      end
    end
  end

  always @(posedge clk_in) begin  // overwrite the tag of rd
    if (rdy_in & instr_signal) begin
      tags[rd_id]  <= rd_tag;
      valid[rd_id] <= 1'b0;
    end
  end

  always @(posedge clk_in) begin  // remove tag and updating data when matching the tag and instr latching doesn't put new tag on rd
    if (rdy_in & rob_commit_signal) begin
      for (i = 0; i < REG_SIZE; i = i + 1) begin
        if (~valid[i] & commit_rd_tag == tags[i] & ~(instr_signal & rd_id == i)) begin
          valid[i] <= 1'b1;
          regs[i]  <= commit_rd_data;
        end
      end
    end
  end

endmodule
