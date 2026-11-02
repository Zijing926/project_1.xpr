/******************************************************************************
 * Module Name: core_system_top
 * Description (EN):
 *   Top-level core system module integrating UART register bridge,
 *   control registers, and an 8-lane DDS generator.
 *   - UART Reg Bridge: Translates PC UART commands into internal
 *     register read/write operations.
 *   - Register Map: Controls DDS parameters (frequency, amplitude, enable).
 *   - DDS Core: Generates 8-channel parallel waveform data.
 *   - Debug Logic: Provides test counter and state observation.
 *
 * Description (ZH):
 *   核心系统顶层模块，集成UART寄存器桥、控制寄存器与8路DDS波形发生器。
 *   - UART寄存器桥：将PC端串口指令翻译为内部寄存器的读写操作。
 *   - 寄存器映射：用于配置DDS参数（频率、幅度、使能开关）。
 *   - DDS核心：生成8通道并行波形数据。
 *   - 调试逻辑：提供测试计数器与状态观测输出。
 *
 * Parameters:
 *   CLK_FREQ  - System clock frequency (Default: 125MHz)
 *   BAUD_RATE - UART baud rate (Default: 115200)
 *   TIMEOUT_MS- UART receive timeout threshold (Default: 50ms)
 *   LUT_FILE  - DDS lookup table memory file path
 *
 * Ports:
 *   sys_clk       - System clock input
 *   sys_rst       - System active-high reset input
 *   rs232_rx_in   - UART RX from PC
 *   rs232_tx_out  - UART TX to PC
 *   dds_dout      - 8-lane DDS parallel output data (signed 16-bit)
 *   debug_out     - Debug observation output
 *
 * Register Map:
 *   Addr 0x00 - CTRL Register (Bit 0: DDS enable)
 *   Addr 0x01 - DDS Amplitude control
 *   Addr 0x02 - DDS Frequency control word
 *   Addr 0x03 - Test free-running counter (Read-only)
 *   Addr 0x04~0x0B - DDS Channel 0~7 output data (Read-only)
 *
 * Note:
 *   - The DDS update_en is currently hardcoded to 1'b1.
 *   - Connect dds_dout to the DAC interface module in the next stage.
 *****************************************************************************/
`default_nettype none

module core_system_top
  #(
    parameter int CLK_FREQ  = 125_000_000,
    parameter int BAUD_RATE = 115200,
    parameter int TIMEOUT_MS = 50, // 50ms
    parameter string LUT_FILE = "dds_sincos_lut.mem"
    )
   (
    input wire 		sys_clk,
    input wire 		sys_rst,

    input wire 		rs232_rx_in, // receive from PC
    output logic 	rs232_tx_out, // send to PC
    output logic signed [15:0] dds_dout [7:0],
    output logic [15:0] debug_out
    );

    logic [7:0]  reg_addr;
    logic        reg_we;
    logic [31:0] reg_wdata;
    logic        reg_re;
    logic [31:0] reg_rdata;
    logic        timeout_err_pulse;
    logic [7:0]  bridge_state;
    logic [3:0]  rx_state;
   
    uart_reg_bridge #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE),
        .TIMEOUT_MS (TIMEOUT_MS)
    ) uart_reg_bridge_inst  (
        .sys_clk           (sys_clk),
        .sys_rst           (sys_rst),
        .uart_rx_in        (rs232_rx_in),
        .uart_tx_out       (rs232_tx_out),
        .reg_addr          (reg_addr),
        .reg_we            (reg_we),
        .reg_wdata         (reg_wdata),
        .reg_re            (reg_re),
        .reg_rdata         (reg_rdata),
        .timeout_err_pulse (timeout_err_pulse),
        .state_out         (bridge_state),
        .rx_state_out      (rx_state)
    );

   // Regsiters
   logic [31:0] 	user_reg_ctrl;     // reg 0
   logic [31:0] 	user_reg_dds_amp;  // reg 1
   logic [31:0] 	user_reg_dds_freq; // reg 2

   always_ff @(posedge sys_clk) begin
      if (sys_rst) begin
         user_reg_ctrl <= '0;
         user_reg_dds_amp <= '0;
         user_reg_dds_freq <= '0;
      end else if (reg_we) begin
         case (reg_addr)
            8'h00: user_reg_ctrl <= reg_wdata;
            8'h01: user_reg_dds_amp <= reg_wdata;
            8'h02: user_reg_dds_freq <= reg_wdata;
         endcase
      end
   end

   logic [28:0] test_cnt;
   logic dds_dout_valid, dds_osc_en, dds_update_en;
   
   always_comb begin
      case (reg_addr)
         8'h00: reg_rdata = user_reg_ctrl;
         8'h01: reg_rdata = user_reg_dds_amp;
         8'h02: reg_rdata = user_reg_dds_freq;
         8'h03: reg_rdata = test_cnt;
         8'h04: reg_rdata = dds_dout[0];
         8'h05: reg_rdata = dds_dout[1];
         8'h06: reg_rdata = dds_dout[2];
         8'h07: reg_rdata = dds_dout[3];
         8'h08: reg_rdata = dds_dout[4];
         8'h09: reg_rdata = dds_dout[5];
         8'h0a: reg_rdata = dds_dout[6];
         8'h0b: reg_rdata = dds_dout[7];
         default: reg_rdata = 32'hdeadbeef;
      endcase
   end

   always_ff @(posedge sys_clk) begin
      if (sys_rst)
	      test_cnt <= '0;
      else
      	test_cnt <= test_cnt + 1'b1;
   end

   assign dds_osc_en = user_reg_ctrl[0];
   assign dds_update_en = (reg_we && (reg_addr == 8'h01 || reg_addr == 8'h02))? 1'b1: 1'b0;
   
    dds_8lane_top #(
        .INIT_FILE(LUT_FILE)
    ) dds_8lane_top_inst (
        .clk       (sys_clk),
        .rst       (sys_rst), // active high reset
        .osc_en    (dds_osc_en),
        .update_en (1'b1),
        .phase_inc (user_reg_dds_freq),
        .amp_in    (user_reg_dds_amp[15:0]),
        .dout      (dds_dout),
        .dout_valid(dds_dout_valid)
    );

   assign debug_out = {dds_dout_valid, dds_osc_en, rx_state, bridge_state};
endmodule
   
		
`default_nettype wire
