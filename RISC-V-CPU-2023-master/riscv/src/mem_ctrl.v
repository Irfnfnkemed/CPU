`ifndef MEMCRTL
`define MEMCRTL

`define FREE_STATUS 2'b00
`define INSTR_FETCH_STATUS 2'b01
`define LSB_LOAD_STATUS 2'b10
`define LSB_STORE_STATUS 2'b11

module memory_controller (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    // with memory
    input  wire [ 7:0] mem_din,        // data input bus
    output reg  [ 7:0] mem_dout,       // data output bus
    output reg  [31:0] mem_a,          // address bus (only 17:0 is used)
    output reg         mem_wr,         // write/read signal (1 for write)
    input  wire        io_buffer_full, // 1 if uart buffer is full

    input wire clear_signal,  // 1 for prediction error

    // with instruction-fetch (or i-cache)
    input  wire        instr_signal,  // 1 for instruction fetch
    input  wire [31:0] instr_a,       // instruction address
    output reg  [63:0] instr_d,       // instruction content (fetch 2 instr)
    output reg         instr_done,    // 1 when done

    // with LSB
    input wire lsb_signal,  // 1 for load/store task
    input wire lsb_wr,  // 1 for write
    input wire lsb_signed,  // 1 for signed load
    input wire [1:0] lsb_len,  // length(byte) of laod/store (00:1 byte, 01:2 bytes, 11:4 bytes)
    input wire [31:0] lsb_a,  // load/store address
    input wire [31:0] lsb_din,  // data for store
    output reg [31:0] lsb_dout,  // data for load
    output reg lsb_done  // 1 when done
);

  reg [1:0] status;
  reg [4:0] stage;  // memory read/write stages

  always @(posedge clk_in) begin  // reset memory controller
    if (rst_in) begin
      status <= `FREE_STATUS;
      mem_a <= 32'b0;
      mem_wr <= 1'b0;
      instr_done <= 1'b0;
      lsb_done <= 1'b0;
    end
  end

  always @(posedge clk_in) begin  // pause CPU, set mem_wr to READ to avoid writing wrongly
    if (~rdy_in) begin
      mem_a <= 32'h00000000;
      mem_wr <= 1'b0;
      instr_done <= 1'b0;
      lsb_done <= 1'b0;
    end
  end

  always @(posedge clk_in) begin
    if (rdy_in) begin
      case (status)
        `FREE_STATUS: begin
          instr_done <= 1'b0;
          lsb_done   <= 1'b0;
          if (instr_signal & ~clear_signal) begin  // if clearing, do not need to load 
            status <= `INSTR_FETCH_STATUS;
            stage  <= 4'b0000;
            mem_a  <= instr_a;
            mem_wr <= 1'b0;
          end else if (lsb_signal) begin
            if (lsb_wr) begin
              status <= (~(lsb_a[17] & lsb_a[16] & io_buffer_full) && lsb_len == 0) ? `FREE_STATUS : `LSB_STORE_STATUS;// if only need to store one byte, set to LSB_STORE_STATUS is not necessary
              if (~(lsb_a[17] & lsb_a[16] & io_buffer_full)) begin
                stage <= 4'b0001;  // store first byte in this cycle
              end else begin
                stage <= 4'b0000;  // do not store in this cycle
              end
              mem_dout <= lsb_din[7:0];
              mem_a <= lsb_a;
              mem_wr <= 1'b1;
            end else if (~clear_signal) begin  // if clearing, do not need to load
              status <= `LSB_LOAD_STATUS;
              stage  <= 4'b0000;
              mem_a  <= lsb_a;
              mem_wr <= 1'b0;
            end
          end
        end
        `INSTR_FETCH_STATUS: begin
          mem_wr <= 1'b0;
          if (clear_signal) begin  // don't need to load
            status <= `FREE_STATUS;
            instr_done <= 1'd0;
          end else begin
            case (stage)  // begin at 1, for loading nead one cycle
              1: instr_d[7:0] <= mem_din;
              2: instr_d[15:8] <= mem_din;
              3: instr_d[23:16] <= mem_din;
              4: instr_d[31:24] <= mem_din;
              5: instr_d[39:32] <= mem_din;
              6: instr_d[47:40] <= mem_din;
              7: instr_d[55:48] <= mem_din;
              8: instr_d[63:56] <= mem_din;
            endcase
            if (stage == 8) begin  // finish fetch
              status <= `FREE_STATUS;
              instr_done <= 1'd1;
            end else begin
              mem_a <= mem_a + 1;
              stage <= stage + 1;
            end
          end
        end
        `LSB_LOAD_STATUS: begin
          mem_wr <= 1'b0;
          if (clear_signal) begin  // don't need to load
            status   <= `FREE_STATUS;
            lsb_done <= 1'd0;
          end else begin
            case (stage)  // begin at 1, for loading nead one cycle
              1: lsb_dout[7:0] <= mem_din;
              2: lsb_dout[15:8] <= mem_din;
              3: lsb_dout[23:16] <= mem_din;
              4: lsb_dout[31:24] <= mem_din;
            endcase
            if (stage == lsb_len + 1) begin  // finish
              status   <= `FREE_STATUS;
              lsb_done <= 1'd1;
              case (lsb_len)  // signed load
                2'b00: begin
                  lsb_dout[31:8] <= lsb_signed ? {24{mem_din[7]}} : {24{1'b0}};
                end
                2'b01: begin
                  lsb_dout[31:16] <= lsb_signed ? {16{mem_din[7]}} : {24{1'b0}};
                end
              endcase
            end else begin
              mem_a <= mem_a + 1;
              stage <= stage + 1;
            end
          end
        end
        `LSB_STORE_STATUS: begin
          mem_wr <= 1'b1;
          if (~(lsb_a[17] & lsb_a[16] & io_buffer_full)) begin
            case (stage)
              0: mem_dout <= lsb_din[7:0];
              1: mem_dout <= lsb_din[15:8];
              2: mem_dout <= lsb_din[23:16];
              3: mem_dout <= lsb_din[31:24];
            endcase
            mem_a <= lsb_a + stage;
            if (stage == lsb_len) begin  // finish
              status   <= `FREE_STATUS;
              lsb_done <= 1'd1;
            end else begin
              stage <= stage + 1;
            end
          end
        end
      endcase
    end
  end

endmodule
`endif
