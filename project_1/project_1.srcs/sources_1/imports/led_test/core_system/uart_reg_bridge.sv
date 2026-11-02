/******************************************************************************
 * Module Name : uart_reg_bridge
 * Description (EN):
 *   UART-to-Register Bridge for PC-FPGA communication.
 *   Implements a lightweight custom protocol over UART to perform
 *   single/burst read and single write operations on internal registers.
 *
 *   Protocol Frame Format (PC → FPGA):
 *     Single Write : CMD(0x77) | ADDR(1B) | DATA(4B, MSB first)
 *     Single Read  : CMD(0x72) | ADDR(1B)
 *     Burst Read   : CMD(0x52) | ADDR(1B) | LEN(1B, num of 32-bit words)
 *
 *   Response Format (FPGA → PC):
 *     Single Read  : DATA(4B, MSB first)
 *     Burst Read   : DATA(LEN × 4B, MSB first, addr auto-increment)
 *
 *   Features:
 *     - Timeout watchdog (default 50ms) resets FSM to IDLE on incomplete frames
 *     - Supports up to 256 registers (8-bit address space)
 *     - Burst read auto-increments address
 *
 * Description (ZH):
 *   UART 转寄存器桥接模块，用于 PC 与 FPGA 之间的通信。
 *   在 UART 上实现了一套轻量级自定义协议，支持对内部寄存器进行
 *   单字读写和突发连续读取操作。
 *
 *   协议帧格式（PC → FPGA）：
 *     单写 : CMD(0x77) | ADDR(1B) | DATA(4B, 高位先发)
 *     单读 : CMD(0x72) | ADDR(1B)
 *     突发读: CMD(0x52) | ADDR(1B) | LEN(1B, 32位字数)
 *
 *   响应格式（FPGA → PC）：
 *     单读 : DATA(4B, 高位先发)
 *     突发读: DATA(LEN × 4B, 高位先发, 地址自动递增)
 *
 *   特性：
 *     - 超时看门狗（默认 50ms），帧不完整时强制回到 IDLE 状态
 *     - 支持最多 256 个寄存器（8 位地址空间）
 *     - 突发读自动递增地址
 *
 * Parameters:
 *   CLK_FREQ   - System clock frequency in Hz (default: 125 MHz)
 *   BAUD_RATE  - UART baud rate in bps (default: 115200)
 *   TIMEOUT_MS - Receive timeout threshold in ms (default: 50)
 *
 * Ports:
 *   sys_clk         - System clock input
 *   sys_rst         - Active-high reset
 *   uart_rx_in      - UART RX from PC
 *   uart_tx_out     - UART TX to PC
 *   reg_addr        - Register address output (to internal logic)
 *   reg_we          - Register write enable pulse
 *   reg_wdata       - Register write data (32-bit)
 *   reg_re          - Register read enable pulse
 *   reg_rdata       - Register read data input (from internal logic)
 *   timeout_err_pulse - Timeout error pulse (1 clock wide)
 *   state_out       - FSM state indicator for debug (bitmap)
 *   rx_state_out    - UART RX sub-state for debug
 *
 * FSM States:
 *   S_IDLE          - Waiting for command byte
 *   S_RX_ADDR       - Receiving register address
 *   S_RX_LEN        - Receiving burst length
 *   S_RX_WDATA      - Receiving 4-byte write data
 *   S_WRITE_EXEC    - Asserting write enable
 *   S_READ_CAPTURE  - Capturing read data from register
 *   S_READ_TX_REQ   - Requesting UART TX byte
 *   S_READ_TX_WAIT  - Waiting for UART TX completion
 *
 * Note:
 *   - Data is transmitted MSB-first (big-endian over the wire)
 *   - Timeout counter resets on each valid received byte
 *   - Burst read wraps address at 8'hFF → 8'h00
 *   - Connect reg_* bus to core_system_top or similar register file
 *
 *****************************************************************************/
`default_nettype none

module uart_reg_bridge #(
    parameter int CLK_FREQ   = 125_000_000, // System clock frequency (Hz)
    parameter int BAUD_RATE  = 115200,      // UART baud rate (bps)
    parameter int TIMEOUT_MS = 50           // Timeout duration (ms)
)(
    input  wire         sys_clk,
    input  wire         sys_rst,   // Active high

    // UART physical interface
    input  wire         uart_rx_in,
    output logic        uart_tx_out,

    // Local buses for internal register access
    output logic [7:0]  reg_addr,
    output logic        reg_we,
    output logic [31:0] reg_wdata,
    output logic        reg_re,
    input  wire  [31:0] reg_rdata,

    // For debug
    output logic        timeout_err_pulse, // Goes high for 1 clock when a timeout happens
    output logic [7:0]  state_out,
    output logic [3:0]  rx_state_out
);

    // ========================================================================
    // 1. Command definition & constant calculation
    // ========================================================================
    localparam logic [7:0] CMD_SINGLE_WRITE = 8'h77; // 'w'
    localparam logic [7:0] CMD_SINGLE_READ  = 8'h72; // 'r'
    localparam logic [7:0] CMD_BURST_READ   = 8'h52; // 'R'

    // Number of clock cycles needed for timeout (e.g.125MHz * 50ms = 6,250,000)
    localparam int TIMEOUT_CYCLES = (CLK_FREQ / 1000) * TIMEOUT_MS;
    localparam int TIMER_WIDTH    = $clog2(TIMEOUT_CYCLES + 1);

    // ========================================================================
    // 2. Instantiating the UART transmit/receive modules
    // ========================================================================
    logic [7:0] rx_data;
    logic       rx_valid;

    logic [7:0] tx_data;
    logic       tx_we;
    logic       tx_busy;

    uart_byte_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_rx (
        .sys_clk        (sys_clk),
        .sys_rst        (sys_rst),
        .rx             (uart_rx_in),
        .output_data    (rx_data),
        .effective_flag (rx_valid),
        .debug_out      (rx_state_out)
    );

    uart_byte_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_tx (
        .sys_clk   (sys_clk),
        .sys_rst   (sys_rst),
        .data_in   (tx_data),
        .we        (tx_we),
        .data_out  (uart_tx_out),
        .busy      (tx_busy)
    );

    // ========================================================================
    // 3. State register and internal regsiters
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE,
        S_RX_ADDR,
        S_RX_LEN,
        S_RX_WDATA,
        S_WRITE_EXEC,
        S_READ_CAPTURE,
        S_READ_TX_REQ,
        S_READ_TX_WAIT
    } state_t;

    state_t                   state;
    logic [7:0]               curr_cmd;
    logic [1:0]               byte_cnt;
    logic [7:0]               burst_cnt;
    logic [31:0]              shift_buf;

    // Counter for timeout
    logic [TIMER_WIDTH-1:0]   timeout_cnt;
    logic                     is_rx_wait_state;

    // Flag for checking if waiting to receive
    assign is_rx_wait_state = (state == S_RX_ADDR) || 
                              (state == S_RX_LEN)  || 
                              (state == S_RX_WDATA);

    // ========================================================================
    // 4. Timeout counter logic
    // ========================================================================
    always_ff @(posedge sys_clk) begin
        if (sys_rst) begin
            timeout_cnt       <= '0;
            timeout_err_pulse <= 1'b0;
        end else begin
            timeout_err_pulse <= 1'b0;

            // Reset the timer when not in the waiting-for-receive state, or one byte is received
            if (!is_rx_wait_state || rx_valid) begin
                timeout_cnt <= '0;
            end else if (timeout_cnt == TIMER_WIDTH'(TIMEOUT_CYCLES - 1)) begin
                timeout_cnt       <= '0;
                timeout_err_pulse <= 1'b1; // Timeout notification pulse
            end else begin
                timeout_cnt <= timeout_cnt + 1'b1;
            end
        end
    end

    // ========================================================================
    // 5. Main state machine logic
    // ========================================================================
    always_ff @(posedge sys_clk) begin
        if (sys_rst) begin
            state     <= S_IDLE;
            curr_cmd  <= 8'h00;
            reg_addr  <= 8'h00;
            reg_we    <= 1'b0;
            reg_wdata <= 32'h0;
            reg_re    <= 1'b0;
            byte_cnt  <= 2'd0;
            burst_cnt <= 8'd0;
            shift_buf <= 32'h0;
            tx_data   <= 8'h00;
            tx_we     <= 1'b0;
        end else begin
            reg_we <= 1'b0;
            reg_re <= 1'b0;
            tx_we  <= 1'b0;

            // When a timeout occurs, forcibly returns to S_IDLE (no writing will be done at all)
            if (timeout_err_pulse) begin
                state <= S_IDLE;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (rx_valid) begin
                            curr_cmd <= rx_data;
                            if (rx_data == CMD_SINGLE_WRITE || 
                                rx_data == CMD_SINGLE_READ  || 
                                rx_data == CMD_BURST_READ) begin
                                state <= S_RX_ADDR;
                            end
                        end
                    end

                    S_RX_ADDR: begin
                        if (rx_valid) begin
                            reg_addr <= rx_data;
                            byte_cnt <= 2'd0;

                            case (curr_cmd)
                                CMD_SINGLE_WRITE: state <= S_RX_WDATA;
                                CMD_SINGLE_READ: begin
                                    burst_cnt <= 8'd1;
                                    state     <= S_READ_CAPTURE;
                                end
                                CMD_BURST_READ:   state <= S_RX_LEN;
                                default:          state <= S_IDLE;
                            endcase
                        end
                    end

                    S_RX_LEN: begin
                        if (rx_valid) begin
                            burst_cnt <= rx_data;
                            if (rx_data == 8'd0) begin
                                state <= S_IDLE;
                            end else begin
                                state <= S_READ_CAPTURE;
                            end
                        end
                    end

                    S_RX_WDATA: begin
                        if (rx_valid) begin
                            shift_buf <= {shift_buf[23:0], rx_data};
                            if (byte_cnt == 2'd3) begin
                                state <= S_WRITE_EXEC;
                            end else begin
                                byte_cnt <= byte_cnt + 2'd1;
                            end
                        end
                    end

                    S_WRITE_EXEC: begin
                        reg_wdata <= shift_buf;
                        reg_we    <= 1'b1;
                        state     <= S_IDLE;
                    end

                    S_READ_CAPTURE: begin
                        shift_buf <= reg_rdata;
                        reg_re    <= 1'b1;
                        byte_cnt  <= 2'd0;
                        state     <= S_READ_TX_REQ;
                    end

                    S_READ_TX_REQ: begin
                        if (!tx_busy) begin
                            tx_data   <= shift_buf[31:24];
                            tx_we     <= 1'b1;
                            shift_buf <= {shift_buf[23:0], 8'h00};
                            state     <= S_READ_TX_WAIT;
                        end
                    end

                    S_READ_TX_WAIT: begin
                        if (!tx_we && !tx_busy) begin
                            if (byte_cnt == 2'd3) begin
                                if (burst_cnt == 8'd1) begin
                                    state <= S_IDLE;
                                end else begin
                                    burst_cnt <= burst_cnt - 8'd1;
                                    reg_addr  <= reg_addr + 8'd1;
                                    state     <= S_READ_CAPTURE;
                                end
                            end else begin
                                byte_cnt <= byte_cnt + 2'd1;
                                state    <= S_READ_TX_REQ;
                            end
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end 

   always_comb begin
      case (state)
	     S_IDLE:         state_out = 8'h01;
         S_RX_ADDR:      state_out = 8'h02;
         S_RX_LEN:       state_out = 8'h04;
         S_RX_WDATA:     state_out = 8'h08;
         S_WRITE_EXEC:   state_out = 8'h10;
         S_READ_CAPTURE: state_out = 8'h20;
         S_READ_TX_REQ:  state_out = 8'h40;
         S_READ_TX_WAIT: state_out = 8'h80;
	     default:        state_out = 8'hff;
      endcase
   end
endmodule

`default_nettype wire
