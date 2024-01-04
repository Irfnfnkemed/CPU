module saturation_counter (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire transition_signal,  // 1 for status transition
    input wire branch,  // 1 for jumping, 0 for continuing
    output wire prediction,  // 1 for jumping, 0 for continuing
    output wire second_prediction  // the second reg in saturation counter
);

  reg [1:0] status;  // 10,11 for jumping, 00,01 for continuing 

  assign prediction = status[1];
  assign second_prediction = status[0];

  always @(posedge clk_in) begin
    if (rst_in) begin
      status <= 2'b10;
    end else if (transition_signal) begin
      if (branch) begin
        status[1] <= status[1] | status[0];
        status[0] <= status[1] | ~status[0];
      end else begin
        status[1] <= status[1] & status[0];
        status[0] <= status[1] & ~status[0];
      end
    end
  end

endmodule

module predictor #(
    parameter LOCAL_WIDTH = 6,
    parameter LOCAL_SIZE  = 2 ** LOCAL_WIDTH
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low
    input wire transition_signal,  // 1 for status transition
    input wire [LOCAL_WIDTH-1: 0] transition_addr, // LOCAL_WIDTH(6) bits in instruction address for transition
    input wire [1:0] transition_selection,
    input wire branch,  // 1 for jumping, 0 for continuing
    input wire [LOCAL_WIDTH-1: 0] instr_addr,  // LOCAL_WIDTH(6) bits in instruction address for selecting counter group
    output wire prediction,  // 1 for jumping, 0 for continuing
    output wire [1:0] selection // select the counter among 4 counters according to last two branches
);

  wire [3:0] prediction_group[LOCAL_SIZE-1:0];

  saturation_counter history_counter (
      .clk_in           (clk_in),
      .rst_in           (rst_in),
      .transition_signal(transition_signal),
      .branch           (branch),
      .prediction       (selection[1]),
      .second_prediction(selection[0])
  );

  genvar i, j;
  generate
    for (i = 0; i < LOCAL_SIZE; i = i + 1) begin
      for (j = 0; j < 4; j = j + 1) begin
        saturation_counter unit_counter (
            .clk_in(clk_in),
            .rst_in(rst_in),
            .transition_signal(transition_signal & (transition_addr == i) & (0 == j)),
            .branch(branch),
            .prediction(prediction_group[i][j])
        );
      end
    end
  endgenerate

  assign prediction = prediction_group[instr_addr][0];

endmodule
