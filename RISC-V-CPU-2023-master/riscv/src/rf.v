module register_file (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input wire read_signal,  //1 for reading register
    input wire [4:0] read_id,
    output wire [4:0] read_data,

    input wire write_signal,  //1 for writing register
    input wire [4:0] write_id,
    input wire [4:0] write_data
);

  reg [31:0] regs;

endmodule
