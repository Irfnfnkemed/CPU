module memory_controller (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input  wire [ 7:0] mem_din,   // data input bus
    output wire [ 7:0] mem_dout,  // data output bus
    output wire [31:0] mem_a,     // address bus (only 17:0 is used)
    output wire        mem_wr,    // write/read signal (1 for write)

    input wire io_buffer_full,  // 1 if uart buffer is full

    input wire [1:0] status_signal, // 11 for fetching instruction, 10 for load, 01 for store, 00 for doing nothing

    input  wire [31:0] instr_a,
    output wire [31:0] instr_d,
    output wire        instr_done, // 1 when done

    input  wire [31:0] lsb_addr,
    input  wire [31:0] lsb_din,   // data for store
    output wire [31:0] lsb_dout,  // data for load
    output wire        lsb_done   // 1 when done
);

endmodule
