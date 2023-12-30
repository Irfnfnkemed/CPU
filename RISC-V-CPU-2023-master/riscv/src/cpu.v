// RISCV32I CPU top module
// port modification allowed for debugging purposes

// `include "alu.v"
// `include "i_cache.v"
// `include "i_fetch.v"
// `include "lsb.v"
// `include "mem_ctrl.v"
// `include "predictor.v"
// `include "rf.v"
// `include "rob.v"
// `include "rs.v"

module cpu (
    input wire clk_in,  // system clock signal
    input wire rst_in,  // reset signal
    input wire rdy_in,  // ready signal, pause cpu when low

    input  wire [ 7:0] mem_din,   // data input bus
    output wire [ 7:0] mem_dout,  // data output bus
    output wire [31:0] mem_a,     // address bus (only 17:0 is used)
    output wire        mem_wr,    // write/read signal (1 for write)

    input wire io_buffer_full,  // 1 if uart buffer is full

    output wire [31:0] dbgreg_dout  // cpu register output (debugging demo)
);

  // implementation goes here

  // Specifications:
  // - Pause cpu(freeze pc, registers, etc.) when rdy_in is low
  // - Memory read result will be returned in the next cycle. Write takes 1 cycle(no need to wait)
  // - Memory is of size 128KB, with valid address ranging from 0x0 to 0x20000
  // - I/O port is mapped to address higher than 0x30000 (mem_a[17:16]==2'b11)
  // - 0x30000 read: read a byte from input
  // - 0x30000 write: write a byte to output (write 0x00 is ignored)
  // - 0x30004 read: read clocks passed since cpu starts (in dword, 4 bytes)
  // - 0x30004 write: indicates program stop (will output '\0' through uart tx)

  parameter ROB_WIDTH = 4;
  parameter LOCAL_WIDTH = 10;
  parameter CACHE_DATA_WIDTH = 64;
  parameter CACHE_WIDTH = 8;
  parameter CACHE_TAG_WIDTH = 6;
  parameter LSB_WIDTH = 4;
  parameter JALR_QUEUE_SIZE = 4;
  parameter RS_WIDTH = 4;

  // instr_fetch <--> i_cache
  wire                   if_icache_signal;
  wire [           31:0] if_icache_addr;
  wire                   if_icache_done;
  wire [           31:0] if_icache_instr;

  // instr_fetch <--> register_file
  wire                   if_rf_signal;
  wire [            4:0] if_rf_id_rs1;
  wire [            4:0] if_rf_id_rs2;
  wire [            4:0] if_rf_id_rd;
  wire [  ROB_WIDTH-1:0] if_rf_tag_rd;
  wire [           31:0] if_rf_value_rs1;
  wire [           31:0] if_rf_value_rs2;
  wire [  ROB_WIDTH-1:0] if_rf_tag_rs1;
  wire [  ROB_WIDTH-1:0] if_rf_tag_rs2;
  wire                   if_rf_valid_rs1;
  wire                   if_rf_valid_rs2;
  wire [           31:0] if_rf_value_x1;

  // instr_fetch <--> reorder_buffer
  wire [  ROB_WIDTH-1:0] if_rob_tag;
  wire [           31:0] if_rob_value_rs1;
  wire [           31:0] if_rob_value_rs2;
  wire                   if_rob_ready_rs1;
  wire                   if_rob_ready_rs2;
  wire [  ROB_WIDTH-1:0] if_rob_tag_rs1;
  wire [  ROB_WIDTH-1:0] if_rob_tag_rs2;
  wire                   if_rob_issue_signal;
  wire                   if_rob_value_ready;
  wire [            1:0] if_rob_opcode;
  wire [           31:0] if_rob_value;
  wire [            4:0] if_rob_rd_id;
  wire [           31:0] if_rob_pc_prediction;
  wire                   if_rob_full;

  // instr_fetch <--> predictor
  wire [LOCAL_WIDTH-1:0] if_pred_addr;
  wire                   if_pred_jump;

  // instr_fetch <--> reservation_station
  wire                   if_rs_issue_signal;
  wire [            3:0] if_rs_opcode;
  wire [           31:0] if_rs_value_rs1;
  wire [           31:0] if_rs_value_rs2;
  wire [  ROB_WIDTH-1:0] if_rs_tag_rs1;
  wire [  ROB_WIDTH-1:0] if_rs_tag_rs2;
  wire                   if_rs_valid_rs1;
  wire                   if_rs_valid_rs2;
  wire [  ROB_WIDTH-1:0] if_rs_tag_rd;
  wire                   if_rs_full;

  // instr_fetch <--> load_store_buffer
  wire                   if_lsb_issue_signal;
  wire                   if_lsb_wr;
  wire                   if_lsb_signed;
  wire [            1:0] if_lsb_len;
  wire [           31:0] if_lsb_addr;
  wire [           31:0] if_lsb_value;
  wire [           11:0] if_lsb_offset;
  wire [  ROB_WIDTH-1:0] if_lsb_tag_addr;
  wire [  ROB_WIDTH-1:0] if_lsb_tag_value;
  wire [  ROB_WIDTH-1:0] if_lsb_tag_rd;
  wire                   if_lsb_valid_addr;
  wire                   if_lsb_valid_value;
  wire                   if_lsb_full;
  wire [           31:0] if_rob_correct_pc;

  // reorder_buffer --> all the modules
  wire                   rob_clear_signal;

  // reservation_station <--> alu1 
  wire                   rs_alu1_busy;
  wire [            3:0] rs_alu1_opcode;
  wire [           31:0] rs_alu1_lhs;
  wire [           31:0] rs_alu1_rhs;
  wire [  ROB_WIDTH-1:0] rs_alu1_tag_rd;

  // alu1 --> reservation_station & load_store_buffer & reorder_buffer
  wire                   alu1_done_result;
  wire [           31:0] alu1_value_result;
  wire [  ROB_WIDTH-1:0] alu1_tag_result;

  // reservation_station <--> alu2 
  wire                   rs_alu2_busy;
  wire [            3:0] rs_alu2_opcode;
  wire [           31:0] rs_alu2_lhs;
  wire [           31:0] rs_alu2_rhs;
  wire [  ROB_WIDTH-1:0] rs_alu2_tag_rd;

  // alu2 --> reservation_station & load_store_buffer & reorder_buffer
  wire                   alu2_done_result;
  wire [           31:0] alu2_value_result;
  wire [  ROB_WIDTH-1:0] alu2_tag_result;

  // load_store_buffer --> reservation_station & reorder_buffer
  wire                   lsb_done_signal;
  wire [           31:0] lsb_done_value;
  wire [  ROB_WIDTH-1:0] lsb_done_tag;

  // reorder_buffer <--> load_store_buffer
  wire                   rob_lsb_done;
  wire [  ROB_WIDTH-1:0] rob_lsb_tag;

  // reorder_buffer <--> reservation_station
  wire                   rs_done;
  wire [           31:0] rs_value;
  wire [  ROB_WIDTH-1:0] rs_tag;

  // mem_ctrl <--> i_cache
  wire                   memctrl_icache_signal;
  wire [           31:0] memctrl_icache_addr;
  wire [           63:0] memctrl_icache_data;
  wire                   memctrl_icache_done;

  // mem_ctrl <--> load_store_buffer
  wire                   memctrl_lsb_signal;
  wire                   memctrl_lsb_wr;
  wire                   memctrl_lsb_signed;
  wire [            1:0] memctrl_lsb_len;
  wire [           31:0] memctrl_lsb_addr;
  wire [           31:0] memctrl_lsb_din;
  wire [           31:0] memctrl_lsb_dout;
  wire                   memctrl_lsb_done;

  // reorder_buffer <--> register_file
  wire                   rob_rf_done;
  wire [           31:0] rob_rf_value;
  wire [            4:0] rob_rf_id;
  wire [  ROB_WIDTH-1:0] rob_rf_tag;


  // reorder_buffer <--> predictor
  wire                   rob_pred_signal;
  wire                   rob_pred_branch;

  instr_fetch #(
      .ROB_WIDTH  (ROB_WIDTH),
      .LOCAL_WIDTH(LOCAL_WIDTH)
  ) u_instr_fetch (
      .clk_in           (clk_in),
      .rst_in           (rst_in),
      .rdy_in           (rdy_in),
      .fetch_signal     (if_icache_signal),
      .fetch_addr       (if_icache_addr),
      .fetch_done       (if_icache_done),
      .fetch_instr      (if_icache_instr),
      .rs_full          (if_rs_full),
      .rob_full         (if_rob_full),
      .lsb_full         (if_lsb_full),
      .rf_signal        (if_rf_signal),
      .rf_id_rs1        (if_rf_id_rs1),
      .rf_id_rs2        (if_rf_id_rs2),
      .rf_id_rd         (if_rf_id_rd),
      .rf_tag_rd        (if_rf_tag_rd),
      .rf_value_rs1     (if_rf_value_rs1),
      .rf_value_rs2     (if_rf_value_rs2),
      .rf_tag_rs1       (if_rf_tag_rs1),
      .rf_tag_rs2       (if_rf_tag_rs2),
      .rf_valid_rs1     (if_rf_valid_rs1),
      .rf_valid_rs2     (if_rf_valid_rs2),
      .value_x1         (if_rf_value_x1),
      .rob_index        (if_rob_tag),
      .rob_value_rs1    (if_rob_value_rs1),
      .rob_value_rs2    (if_rob_value_rs2),
      .rob_ready_rs1    (if_rob_ready_rs1),
      .rob_ready_rs2    (if_rob_ready_rs2),
      .rob_tag_rs1      (if_rob_tag_rs1),
      .rob_tag_rs2      (if_rob_tag_rs2),
      .predict_addr     (if_pred_addr),
      .predict_jump     (if_pred_jump),
      .rs_issue_signal  (if_rs_issue_signal),
      .rs_opcode        (if_rs_opcode),
      .rs_value_rs1     (if_rs_value_rs1),
      .rs_value_rs2     (if_rs_value_rs2),
      .rs_tag_rs1       (if_rs_tag_rs1),
      .rs_tag_rs2       (if_rs_tag_rs2),
      .rs_valid_rs1     (if_rs_valid_rs1),
      .rs_valid_rs2     (if_rs_valid_rs2),
      .rs_tag_rd        (if_rs_tag_rd),
      .rob_issue_signal (if_rob_issue_signal),
      .rob_value_ready  (if_rob_value_ready),
      .rob_opcode       (if_rob_opcode),
      .rob_value        (if_rob_value),
      .rob_rd_id        (if_rob_rd_id),
      .rob_pc_prediction(if_rob_pc_prediction),
      .lsb_issue_signal (if_lsb_issue_signal),
      .lsb_wr           (if_lsb_wr),
      .lsb_signed       (if_lsb_signed),
      .lsb_len          (if_lsb_len),
      .lsb_addr         (if_lsb_addr),
      .lsb_value        (if_lsb_value),
      .lsb_offset       (if_lsb_offset),
      .lsb_tag_addr     (if_lsb_tag_addr),
      .lsb_tag_value    (if_lsb_tag_value),
      .lsb_tag_rd       (if_lsb_tag_rd),
      .lsb_valid_addr   (if_lsb_valid_addr),
      .lsb_valid_value  (if_lsb_valid_value),
      .clear_signal     (rob_clear_signal),
      .correct_pc       (if_rob_correct_pc)
  );

  alu #(
      .ROB_WIDTH(ROB_WIDTH)
  ) u_alu1 (
      .clk_in      (clk_in),
      .rst_in      (rst_in),
      .rdy_in      (rdy_in),
      .clear_signal(rob_clear_signal),
      .cal_signal  (rs_alu1_busy),
      .opcode      (rs_alu1_opcode),
      .lhs         (rs_alu1_lhs),
      .rhs         (rs_alu1_rhs),
      .tag         (rs_alu1_tag_rd),
      .done_result (alu1_done_result),
      .value_result(alu1_value_result),
      .tag_result  (alu1_tag_result)
  );

  alu #(
      .ROB_WIDTH(ROB_WIDTH)
  ) u_alu2 (
      .clk_in      (clk_in),
      .rst_in      (rst_in),
      .rdy_in      (rdy_in),
      .clear_signal(rob_clear_signal),
      .cal_signal  (rs_alu2_busy),
      .opcode      (rs_alu2_opcode),
      .lhs         (rs_alu2_lhs),
      .rhs         (rs_alu2_rhs),
      .tag         (rs_alu2_tag_rd),
      .done_result (alu2_done_result),
      .value_result(alu2_value_result),
      .tag_result  (alu2_tag_result)
  );

  instr_cache #(
      .DATA_WIDTH (CACHE_DATA_WIDTH),
      .CACHE_WIDTH(CACHE_WIDTH),
      .CACHE_SIZE (2 ** CACHE_WIDTH),
      .TAG_WIDTH  (CACHE_TAG_WIDTH)
  ) u_instr_cache (
      .clk_in      (clk_in),
      .rst_in      (rst_in),
      .rdy_in      (rdy_in),
      .clear_signal(rob_clear_signal),
      .fetch_signal(if_icache_signal),
      .fetch_addr  (if_icache_addr),
      .fetch_done  (if_icache_done),
      .fetch_instr (if_icache_instr),
      .mem_signal  (memctrl_icache_signal),
      .mem_addr    (memctrl_icache_addr),
      .mem_done    (memctrl_icache_done),
      .mem_data    (memctrl_icache_data)
  );

  load_store_buffer #(
      .LSB_WIDTH(LSB_WIDTH),
      .LSB_SIZE (2 ** LSB_WIDTH),
      .ROB_WIDTH(ROB_WIDTH)
  ) u_load_store_buffer (
      .clk_in           (clk_in),
      .rst_in           (rst_in),
      .rdy_in           (rdy_in),
      .clear_signal     (rob_clear_signal),
      .issue_signal     (if_lsb_issue_signal),
      .issue_wr         (if_lsb_wr),
      .issue_signed     (if_lsb_signed),
      .issue_len        (if_lsb_len),
      .issue_addr       (if_lsb_addr),
      .issue_value      (if_lsb_value),
      .issue_offset     (if_lsb_offset),
      .issue_tag_addr   (if_lsb_tag_addr),
      .issue_tag_value  (if_lsb_tag_value),
      .issue_tag_rd     (if_lsb_tag_rd),
      .issue_valid_addr (if_lsb_valid_addr),
      .issue_valid_value(if_lsb_valid_value),
      .commit_signal    (rob_lsb_done),
      .commit_tag       (rob_lsb_tag),
      .mem_signal       (memctrl_lsb_signal),
      .mem_wr           (memctrl_lsb_wr),
      .mem_signed       (memctrl_lsb_signed),
      .mem_len          (memctrl_lsb_len),
      .mem_addr         (memctrl_lsb_addr),
      .mem_dout         (memctrl_lsb_din),
      .mem_din          (memctrl_lsb_dout),
      .mem_done         (memctrl_lsb_done),
      .alu1_signal      (alu1_done_result),
      .alu2_signal      (alu2_done_result),
      .alu1_value       (alu1_value_result),
      .alu2_value       (alu2_value_result),
      .alu1_tag         (alu1_tag_result),
      .alu2_tag         (alu2_tag_result),
      .done_signal      (lsb_done_signal),
      .done_value       (lsb_done_value),
      .done_tag         (lsb_done_tag),
      .full             (if_lsb_full)
  );

  memory_controller u_memory_controller (
      .clk_in        (clk_in),
      .rst_in        (rst_in),
      .rdy_in        (rdy_in),
      .mem_din       (mem_din),
      .mem_dout      (mem_dout),
      .mem_a         (mem_a),
      .mem_wr        (mem_wr),
      .io_buffer_full(io_buffer_full),
      .clear_signal  (rob_clear_signal),
      .instr_signal  (memctrl_icache_signal),
      .instr_a       (memctrl_icache_addr),
      .instr_d       (memctrl_icache_data),
      .instr_done    (memctrl_icache_done),
      .lsb_signal    (memctrl_lsb_signal),
      .lsb_wr        (memctrl_lsb_wr),
      .lsb_signed    (memctrl_lsb_signed),
      .lsb_len       (memctrl_lsb_len),
      .lsb_a         (memctrl_lsb_addr),
      .lsb_din       (memctrl_lsb_din),
      .lsb_dout      (memctrl_lsb_dout),
      .lsb_done      (memctrl_lsb_done)
  );


  predictor #(
      .LOCAL_WIDTH(LOCAL_WIDTH),
      .LOCAL_SIZE (2 ** LOCAL_WIDTH)
  ) u_predictor (
      .clk_in           (clk_in),
      .rst_in           (rst_in),
      .rdy_in           (rdy_in),
      .transition_signal(rob_pred_signal),
      .branch           (rob_pred_branch),
      .instr_addr       (if_pred_addr),
      .prediction       (if_pred_jump)
  );


  register_file #(
      .ROB_WIDTH(ROB_WIDTH)
  ) u_register_file (
      .clk_in           (clk_in),
      .rst_in           (rst_in),
      .rdy_in           (rdy_in),
      .clear_signal     (rob_clear_signal),
      .instr_signal     (if_rf_signal),
      .rs_id_1          (if_rf_id_rs1),
      .rs_id_2          (if_rf_id_rs2),
      .rd_id            (if_rf_id_rd),
      .rd_tag           (if_rf_tag_rd),
      .rs_value_1       (if_rf_value_rs1),
      .rs_value_2       (if_rf_value_rs2),
      .rs_tag_1         (if_rf_tag_rs1),
      .rs_tag_2         (if_rf_tag_rs2),
      .rs_valid_1       (if_rf_valid_rs1),
      .rs_valid_2       (if_rf_valid_rs2),
      .value_x1         (if_rf_value_x1),
      .rob_commit_signal(rob_rf_done),
      .commit_rd_value  (rob_rf_value),
      .commit_rd_id     (rob_rf_id),
      .commit_rd_tag    (rob_rf_tag)
  );

  reorder_buffer #(
      .ROB_WIDTH      (ROB_WIDTH),
      .ROB_SIZE       (2 ** ROB_WIDTH),
      .JALR_QUEUE_SIZE(JALR_QUEUE_SIZE)
  ) u_reorder_buffer (
      .clk_in             (clk_in),
      .rst_in             (rst_in),
      .rdy_in             (rdy_in),
      .clear_signal       (rob_clear_signal),
      .correct_pc         (if_rob_correct_pc),
      .issue_signal       (if_rob_issue_signal),
      .issue_opcode       (if_rob_opcode),
      .issue_value_ready  (if_rob_value_ready),
      .issue_value        (if_rob_value),
      .issue_rd_id        (if_rob_rd_id),
      .issue_pc_prediction(if_rob_pc_prediction),
      .alu1_done          (alu1_done_result),
      .alu2_done          (alu2_done_result),
      .alu1_value         (alu1_value_result),
      .alu2_value         (alu2_value_result),
      .alu1_tag           (alu1_tag_result),
      .alu2_tag           (alu2_tag_result),
      .lsb_load_done      (lsb_done_signal),
      .lsb_load_value     (lsb_done_value),
      .lsb_load_tag       (lsb_done_tag),
      .reg_done           (rob_rf_done),
      .reg_value          (rob_rf_value),
      .reg_id             (rob_rf_id),
      .reg_tag            (rob_rf_tag),
      .lsb_done           (rob_lsb_done),
      .lsb_tag            (rob_lsb_tag),
      .rs_done            (rs_done),
      .rs_value           (rs_value),
      .rs_tag             (rs_tag),
      .predictor_signal   (rob_pred_signal),
      .predictor_branch   (rob_pred_branch),
      .rob_tag            (if_rob_tag),
      .rob_value_rs1      (if_rob_value_rs1),
      .rob_value_rs2      (if_rob_value_rs2),
      .rob_ready_rs1      (if_rob_ready_rs1),
      .rob_ready_rs2      (if_rob_ready_rs2),
      .rob_tag_rs1        (if_rob_tag_rs1),
      .rob_tag_rs2        (if_rob_tag_rs2),
      .full               (if_rob_full)
  );


  reservation_station #(
      .RS_WIDTH (RS_WIDTH),
      .ROB_WIDTH(ROB_WIDTH),
      .RS_SIZE  (2 ** RS_WIDTH)
  ) u_reservation_station (
      .clk_in          (clk_in),
      .rst_in          (rst_in),
      .rdy_in          (rdy_in),
      .clear_signal    (rob_clear_signal),
      .issue           (if_rs_issue_signal),
      .opcode_issue    (if_rs_opcode),
      .rs_issue_value_1(if_rs_value_rs1),
      .rs_issue_value_2(if_rs_value_rs2),
      .rs_issue_tag_1  (if_rs_tag_rs1),
      .rs_issue_tag_2  (if_rs_tag_rs2),
      .rs_issue_valid_1(if_rs_valid_rs1),
      .rs_issue_valid_2(if_rs_valid_rs2),
      .rd_issue_tag    (if_rs_tag_rd),
      .busy_alu_1      (rs_alu1_busy),
      .busy_alu_2      (rs_alu2_busy),
      .opcode_alu_1    (rs_alu1_opcode),
      .opcode_alu_2    (rs_alu2_opcode),
      .lhs_alu_1       (rs_alu1_lhs),
      .lhs_alu_2       (rs_alu2_lhs),
      .rhs_alu_1       (rs_alu1_rhs),
      .rhs_alu_2       (rs_alu2_rhs),
      .rd_tag_alu_1    (rs_alu1_tag_rd),
      .rd_tag_alu_2    (rs_alu2_tag_rd),
      .done_alu_1      (alu1_done_result),
      .done_alu_2      (alu2_done_result),
      .value_alu_1     (alu1_value_result),
      .value_alu_2     (alu2_value_result),
      .tag_alu_1       (alu1_tag_result),
      .tag_alu_2       (alu2_tag_result),
      .done_lsb        (lsb_done_signal),
      .value_lsb       (lsb_done_value),
      .tag_lsb         (lsb_done_tag),
      .done_commit     (rs_done),
      .value_commit    (rs_value),
      .tag_commit      (rs_tag),
      .full            (if_rs_full)
  );

endmodule



