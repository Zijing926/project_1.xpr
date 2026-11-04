`timescale 1ns / 1ps

// Automatically programs the DAC5681Z registers over SPI after reset release.
module dac5681_init (
    input  logic        clk,
    input  logic        rst,
    input  logic        reset_released,
    input  logic        spi_done,
    output logic [15:0] spi_data_tx,
    output logic        spi_start,
    output logic        ready,
    output logic        init_done
);
    // Each entry is one 16-bit SPI frame: {8-bit register address, 8-bit value}.
    // Keep the repeated CONFIG8 writes at the end; they restart and start the DLL.
    localparam logic [4:0] LAST_CONFIG_INDEX = 5'd15;

    // Issue a one-cycle start pulse and wait for SPI completion before advancing.
    typedef enum logic [1:0] {
        WAIT_RESET_RELEASE,
        CONFIG_START,
        CONFIG_WAIT,
        CONFIG_READY
    } startup_state_t;
    startup_state_t startup_state;
    logic [4:0] config_index;

    // DAC5681 power-on register sequence, followed by the DLL restart sequence.
    function automatic logic [15:0] config_word(input logic [4:0] index);
        case (index)
            5'd0:  config_word = 16'h0101;  // CONFIG1 : FIFO_offset : +1
            5'd1:  config_word = 16'h02C0;  // CONFIG2 : Complementary 2 input
            5'd2:  config_word = 16'h0400;  // STATUS4 : Default
            5'd3:  config_word = 16'h0582;  // CONFIG5 : PLL_bypass enable
            5'd4:  config_word = 16'h060E;  // CONFIG6 : PLL_sleep enable
            5'd5:  config_word = 16'h0371;  // CONFIG3 : SW_sync bit :synchronization input.
            5'd6:  config_word = 16'h0101;  // CONFIG1 : FIFO_offset : +1
            5'd7:  config_word = 16'h0900;  // CONFIG9 : Default
            5'd8:  config_word = 16'h0A00;  // CONFIG10 : DLL_delay : 90
            5'd9:  config_word = 16'h0B00;  // CONFIG11 : Default
            5'd10: config_word = 16'h0C00;  // CONFIG12 : Default
            5'd11: config_word = 16'h0D00;  // CONFIG13 : Default
            5'd12: config_word = 16'h0E00;  // CONFIG14 : Default
            5'd13: config_word = 16'h0F00;  // CONFIG15 : Default
            5'd14: config_word = 16'h0804;  // CONFIG8 : Restart DLL
            5'd15: config_word = 16'h0800;  // CONFIG8 : Start DLL
            default: config_word = 16'h8000;
        endcase
    endfunction

    always_comb begin
        // Hold the selected frame stable while the SPI controller is busy.
        spi_data_tx = config_word(config_index);
        spi_start   = (startup_state == CONFIG_START);
        ready       = (startup_state == CONFIG_READY);
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            init_done     <= 1'b0;
            startup_state <= WAIT_RESET_RELEASE;
            config_index  <= 5'd0;
        end else begin
            case (startup_state)
                WAIT_RESET_RELEASE: begin
                    if (reset_released)
                        startup_state <= CONFIG_START;
                end
                // CONFIG_START lasts one clock, then wait for this frame to finish.
                CONFIG_START: startup_state <= CONFIG_WAIT;
                CONFIG_WAIT: begin
                    if (spi_done) begin
                        if (config_index == LAST_CONFIG_INDEX) begin
                            startup_state <= CONFIG_READY;
                            init_done     <= 1'b1;
                        end else begin
                            config_index  <= config_index + 1'b1;
                            startup_state <= CONFIG_START;
                        end
                    end
                end
                CONFIG_READY: startup_state <= CONFIG_READY;
                default: startup_state <= WAIT_RESET_RELEASE;
            endcase
        end
    end
endmodule
