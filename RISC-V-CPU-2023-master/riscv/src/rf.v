module register_file #(
    parameter ROB_WIDTH = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire clear_signal,  // 1 for prediction error

    // from instr-fetch (issue)
    input wire instr_signal,  //1 for fetching registers
    input wire [31:0] rs_id_1,
    input wire [31:0] rs_id_2,
    output wire [31:0] rs_value_1,
    output wire [31:0] rs_value_2,
    output wire [ROB_WIDTH-1:0] rs_tag_1,
    output wire [ROB_WIDTH-1:0] rs_tag_2,
    output wire rs_valid_1,
    output wire rs_valid_2,
    input wire [31:0] rd_id,
    input wire [ROB_WIDTH-1:0] rd_tag,  // overwrite the tag of rd

    // from rob (commit)
    input wire rob_commit_signal,  //1 for committing
    input wire [31:0] commit_rd_value,
    input wire [ROB_WIDTH-1:0] commit_rd_tag
);

  reg [31:0] values[31:0];  // registers
  reg [ROB_WIDTH-1:0] tags[31:0];  // register tags
  reg valid[31:0];  // validation of get register value, 1 for valid (invalid tag), 0 for invalid(valid tag)

  assign sign_1 = rob_commit_signal & ~valid[rs_id_1] & (tags[rs_id_1] == commit_rd_tag);// 1 when rob commitment update rs1 at the same time
  assign sign_2 = rob_commit_signal & ~valid[rs_id_2] & (tags[rs_id_2] == commit_rd_tag);// 1 when rob commitment update rs2 at the same time
  assign rs_value_1 = ({32{sign_1}} & commit_rd_value) | ({32{~sign_1}} & values[rs_id_1]) ; // fowarding when rob commitment update rs1 at the same time
  assign rs_value_2 = ({32{sign_2}} & commit_rd_value) | ({32{~sign_2}} & values[rs_id_2]) ; // fowarding when rob commitment update rs2 at the same time
  assign rs_tag_1 = tags[rs_id_1];
  assign rs_tag_2 = tags[rs_id_2];
  assign rs_valid_1 = sign_1 | (~sign_1 & valid[rs_id_1]);
  assign rs_valid_2 = sign_2 | (~sign_2 & valid[rs_id_2]);

  integer i_reset;
  always @(posedge clk_in) begin  // reset register file
    if (rst_in | (rdy_in & clear_signal)) begin
      values[0] <= {32{1'b0}};
      tags[0]   <= {ROB_WIDTH{1'b0}};
      valid[0]  <= 1'b1;  // 0th reg is always 0
      for (i_reset = 1; i_reset < 32; i_reset = i_reset + 1) begin
        values[i_reset] <= {32{1'b0}};
        tags[i_reset]   <= {ROB_WIDTH{1'b0}};
        valid[i_reset]  <= 1'b0;
      end
    end
  end

  always @(posedge clk_in) begin  // overwrite the tag of rd (if rd is 0th reg, ignore)
    if (rdy_in & instr_signal & (rd_id != 0)) begin
      tags[rd_id]  <= rd_tag;
      valid[rd_id] <= 1'b0;
    end
  end

  integer i_commit;
  always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
    if (rdy_in & rob_commit_signal) begin  // 0th reg cannot be modified
      for (i_commit = 1; i_commit < 32; i_commit = i_commit + 1) begin
        if (~valid[i_commit] & (commit_rd_tag == tags[i_commit]) & ~(instr_signal & rd_id == i_commit)) begin
          valid[i_commit]  <= 1'b1;
          values[i_commit] <= commit_rd_value;
        end
      end
    end
  end

endmodule
