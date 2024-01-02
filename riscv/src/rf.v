module register_file #(
    parameter ROB_WIDTH = 4
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire clear_signal,  // 1 for prediction error

    // from instr-fetch (issue)
    input wire instr_signal,  //1 for fetching registers
    input wire [4:0] rs_id_1,
    input wire [4:0] rs_id_2,
    input wire [4:0] rd_id,
    input wire [ROB_WIDTH-1:0] rd_tag,  // overwrite the tag of rd
    output wire [31:0] rs_value_1,
    output wire [31:0] rs_value_2,
    output wire [ROB_WIDTH-1:0] rs_tag_1,
    output wire [ROB_WIDTH-1:0] rs_tag_2,
    output wire rs_valid_1,
    output wire rs_valid_2,
    output wire [31:0] value_x1,  // the value of x1 reg, for predicting JALR


    // from rob (commit)
    input wire rob_commit_signal,  //1 for committing
    input wire [31:0] commit_rd_value,
    input wire [4:0] commit_rd_id,
    input wire [ROB_WIDTH-1:0] commit_rd_tag
);

  reg [31:0] values[31:0];  // registers
  reg [ROB_WIDTH-1:0] tags[31:0];  // register tags
  reg valid[31:0];  // validation of get register value, 1 for valid (invalid tag), 0 for invalid(valid tag)
  reg [32:0] t;

  assign sign_1 = rob_commit_signal & ~valid[rs_id_1] & (tags[rs_id_1] == commit_rd_tag);// 1 when rob commitment update rs1 at the same time
  assign sign_2 = rob_commit_signal & ~valid[rs_id_2] & (tags[rs_id_2] == commit_rd_tag);// 1 when rob commitment update rs2 at the same time
  assign rs_value_1 = ({32{sign_1}} & commit_rd_value) | ({32{~sign_1}} & values[rs_id_1]) ; // fowarding when rob commitment update rs1 at the same time
  assign rs_value_2 = ({32{sign_2}} & commit_rd_value) | ({32{~sign_2}} & values[rs_id_2]) ; // fowarding when rob commitment update rs2 at the same time
  assign rs_tag_1 = tags[rs_id_1];
  assign rs_tag_2 = tags[rs_id_2];
  assign rs_valid_1 = sign_1 | (~sign_1 & valid[rs_id_1]);
  assign rs_valid_2 = sign_2 | (~sign_2 & valid[rs_id_2]);
  assign value_x1 = values[1];

  integer i_reset;
  always @(posedge clk_in) begin  // reset register file
    if (rst_in) begin
      for (i_reset = 0; i_reset < 32; i_reset = i_reset + 1) begin
        values[i_reset] <= {32{1'b0}};
        tags[i_reset]   <= {ROB_WIDTH{1'b0}};
        valid[i_reset]  <= 1'b1;
      end
    end
  end

  integer i_clear;
  always @(posedge clk_in) begin  // clear register file's tags
    if (~rst_in & rdy_in & clear_signal) begin
      for (i_clear = 0; i_clear < 32; i_clear = i_clear + 1) begin
        tags[i_clear]  <= {ROB_WIDTH{1'b0}};
        valid[i_clear] <= 1'b1;
      end
    end
  end

  always @(posedge clk_in) begin  // overwrite the tag of rd (if rd is 0th reg, ignore)
    if (~rst_in & rdy_in & instr_signal & ~clear_signal & ~(rd_id == 0)) begin
      valid[rd_id] <= 1'b0;
      tags[rd_id]  <= rd_tag;
    end
  end

  always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
    if (~rst_in & rdy_in & rob_commit_signal & ~(commit_rd_id == 0)) begin  // 0th reg cannot be modified
      values[commit_rd_id] <= commit_rd_value;
      if (~clear_signal) begin // if clearing, the valid bit is always set to 1
        valid[commit_rd_id]  <= ~valid[commit_rd_id] & (commit_rd_tag == tags[commit_rd_id]) & ~(instr_signal & (rd_id == commit_rd_id));
      end
    end
  end

  // integer f;
  // integer ff;
  // initial begin
  //   f  = $fopen("f");
  //   ff = $fopen("ff");
  //   t  = 0;
  // end

  // integer i;
  // always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
  //   if (~rst_in & rdy_in) begin  // 0th reg cannot be modified
  //     //$fdisplay(f, "signal:%d,commit_tag:%d", rob_commit_signal, commit_rd_tag);
  //     $fdisplay(f,"");
  //     for (i = 1; i < 32; i = i + 1) begin
  //       $fdisplay(f, "%d:%d, tag:%d, valid:%d", i, values[i], tags[i], valid[i]);
  //     end
  //   end
  // end

  // integer i;
  // always @(posedge clk_in) begin  // removing tag and updating value when matching the tag and instr-fetch doesn't put new tag on rd
  //   t <= t + 1;
  //   if (~rst_in & rdy_in & rob_commit_signal) begin  // 0th reg cannot be modified
  //     //$fdisplay(f, "signal:%d,commit_tag:%d", rob_commit_signal, commit_rd_tag);
  //     $fdisplay(f, "");
  //     for (i = 1; i < 32; i = i + 1) begin
  //       $fdisplay(f, "%d:%h", i, values[i]);
  //     end
  //     $fdisplay(ff, "%d", t);
  //     for (i = 1; i < 32; i = i + 1) begin
  //       $fdisplay(ff, "%d:%h", i, values[i]);
  //     end
  //   end
  // end

endmodule
