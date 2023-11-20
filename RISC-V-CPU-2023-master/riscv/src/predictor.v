`include "./predictor.v"

module saturation_counter #(
    parameter LOCAL_WIDTH = 10,
    parameter LOCAL_SIZE  = 2 ** LOCAL_WIDTH
) (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire transition_signal,  // 1 for status transition
    input wire correctness,  // 1 for successful prediction, 0 for fail prediction
    output wire prediction,  // 1 for jumping, 0 for continuing
    output wire second_prediction  // the second reg in saturation counter
);

  reg [1:0] status;  // 10,11 for jumping, 00,01 for continuing 

  assign prediction = status[1];

  always @(posedge clk_in) begin
    if (rst_in) begin
      status <= 2'b01;
    end else if (transition_signal) begin
      if (correctness) begin
        status[1] = status[1] | status[0];
        status[0] = status[1] | ~status[0];
      end else begin
        status[1] = status[1] & status[0];
        status[0] = status[1] & ~status[0];
      end
    end
  end

endmodule

module counter_group (
    input  wire       clk_in,             // system clock signal
    input  wire       rst_in,             // reset signal
    input  wire       transition_signal,  // 1 for status transition
    input  wire       correctness,        // 1 for successful prediction, 0 for fail prediction
    input  wire [1:0] selection,          // select from the counter in the group
    output wire       prediction          // 1 for jumping, 0 for continuing
);  // four saturation counter in a group

  wire [3:0] prediction_results;
  wire [3:0] selection_signal;
  assign selection_signal[0] = ~selection[1] & ~selection[0];  // for 00 selection
  assign selection_signal[1] = ~selection[1] & selection[0];  // for 01 selection
  assign selection_signal[2] = selection[1] & ~selection[0];  //for 10 selection
  assign selection_signal[3] = selection[1] & selection[0];  //for 11 selection

  saturation_counter counter_00 (
      .clk_in(clk_in),
      .rst_in(rst_in),
      .transition_signal(transition_signal & selection_signal[0]),
      .correctness(correctness),
      .prediction(prediction_results[0])
  );
  saturation_counter counter_01 (
      .clk_in(clk_in),
      .rst_in(rst_in),
      .transition_signal(transition_signal & selection_signal[1]),
      .correctness(correctness),
      .prediction(prediction_results[1])
  );
  saturation_counter counter_10 (
      .clk_in(clk_in),
      .rst_in(rst_in),
      .transition_signal(transition_signal & selection_signal[2]),
      .correctness(correctness),
      .prediction(prediction_results[2])
  );
  saturation_counter counter_11 (
      .clk_in(clk_in),
      .rst_in(rst_in),
      .transition_signal(transition_signal & selection_signal[3]),
      .correctness(correctness),
      .prediction(prediction_results[3])
  );

  assign prediction = (prediction_results[0] & selection_signal[0] ) | 
                      (prediction_results[1] & selection_signal[1] ) | 
                      (prediction_results[2] & selection_signal[2] ) | 
                      (prediction_results[3] & selection_signal[3] ) ;

endmodule


module predictor (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low
    input wire transition_signal,  // 1 for status transition
    input wire correctness,  // 1 for successful prediction, 0 for fail prediction
    input wire [LOCAL_WIDTH + 1: 2] instr_addr,  // 10 bits in instruction address for selecting counter group
    output wire prediction  // 1 for jumping, 0 for continuing
);

  wire [             1:0] selection;
  reg  [LOCAL_WIDTH -1:0] counter_id;
  wire [  LOCAL_SIZE-1:0] sprediction_group;

  assign prediction = prediction_group[counter_id];

  saturation_counter global_counter (
      .clk_in(clk_in),
      .rst_in(rst_in),
      .transition_signal(transition_signal),
      .correctness(correctness),
      .prediction(selection[1]),
      .second_prediction(selection[0])
  );

  genvar i;
  generate
    for (i = 0; i < LOCAL_SIZE; i = i + 1) begin
      counter_group counter_group (
          .clk_in           (clk_in),
          .rst_in           (rst_in),
          .transition_signal(transition_signal && counter_id == i),
          .correctness      (correctness),
          .selection        (selection[1:0]),
          .prediction       (prediction_group[i])
      );
    end
  endgenerate

  always @(posedge clk_in) begin
    if (rst_in) begin
      counter_id <= {LOCAL_WIDTH{1'b0}};
    end else if (rdy_in) begin
      counter_id <= instr_addr;
    end
  end

endmodule
