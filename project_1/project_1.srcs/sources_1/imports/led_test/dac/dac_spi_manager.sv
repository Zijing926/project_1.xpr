`timescale 1ns / 1ps

// Manages DAC reset, startup register initialization, and user SPI transfers.
module dac_spi_manager (
    input  logic        clk,
    input  logic        rst,
    input  logic        miso,
    input  logic [15:0] user_data_tx,
    input  logic        user_start,

    output logic [7:0]  data_rx,
    output logic        sclk,
    output logic        csb,
    output logic        mosi,
    output logic        resetb
);
    // Keep RESETB low for at least 25 ns after the system reset is released.
    localparam int RESETB_HOLD_CYCLES = 5;
    logic [2:0] resetb_cnt;
    logic       resetb_released;
    logic       spi_done;
    // Reset the DAC, then release RESETB after the specified hold interval.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            resetb_cnt      <= '0;
            resetb_released <= 1'b0;
        end else if (!resetb_released) begin
            if (resetb_cnt == RESETB_HOLD_CYCLES - 1)
                resetb_released <= 1'b1;
            else
                resetb_cnt <= resetb_cnt + 1'b1;
        end
    end

    assign resetb = resetb_released;

    logic start_prev;
    logic start_pulse;
    logic [15:0] spi_data_tx;
    logic        spi_start;
    logic [15:0] init_data_tx;
    logic        init_start;
    logic        init_ready;
    logic        init_done;
    typedef enum logic [2:0] {
        WAIT_INIT,
        DLL_CHECK_START,
        DLL_CHECK_WAIT,
        DLL_CONFIG_START,
        DLL_CONFIG_WAIT,
        USER_ACCESS
    } manager_state_t;
    manager_state_t manager_state;

    // Start automatic register programming only after the DAC reset is released.
    dac5681_init init_inst (
        .clk            (clk),
        .rst            (rst),
        .reset_released  (resetb_released),
        .spi_done        (spi_done),
        .spi_data_tx     (init_data_tx),
        .spi_start       (init_start),
        .ready           (init_ready),
        .init_done       (init_done)
    );

    // Keep the SPI bus reserved for initialization and the DLL readback check.
    always_comb begin
        spi_data_tx = user_data_tx;
        spi_start   = 1'b0;
        case (manager_state)
            WAIT_INIT: begin
                spi_data_tx = init_data_tx;
                spi_start   = init_start;
            end
            DLL_CHECK_START: begin
                spi_data_tx = 16'h8000;
                spi_start   = 1'b1;
            end
            DLL_CONFIG_START: begin
                spi_data_tx = 16'h0373;
                spi_start   = 1'b1;
            end
            DLL_CONFIG_WAIT: spi_data_tx = 16'h0373;
            USER_ACCESS: spi_start = start_pulse;
            default: ;
        endcase
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            manager_state <= WAIT_INIT;
        end else begin
            case (manager_state)
                WAIT_INIT: begin
                    if (init_done)
                        manager_state <= DLL_CHECK_START;
                end
                DLL_CHECK_START:
                    manager_state <= DLL_CHECK_WAIT;
                DLL_CHECK_WAIT: begin
                    if (spi_done) begin
                        if (data_rx == 8'h4B)
                            manager_state <= DLL_CONFIG_START;
                        else
                            manager_state <= DLL_CHECK_START;
                    end
                end
                DLL_CONFIG_START:
                    manager_state <= DLL_CONFIG_WAIT;
                DLL_CONFIG_WAIT: begin
                    if (spi_done)
                        manager_state <= USER_ACCESS;
                end
                USER_ACCESS:
                    manager_state <= USER_ACCESS;
                default:
                    manager_state <= WAIT_INIT;
            endcase
        end
    end

    // Convert the VIO start rising edge into a one-cycle SPI request.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            start_prev <= 1'b0;
        else
            start_prev <= user_start;
    end

    assign start_pulse = user_start & ~start_prev;

    // Drive the DAC serial interface through the SPI controller.
    spi_dac5681z spi_inst (
        .clk     (clk),
        .rst     (rst),
        .start   (spi_start),
        .data_tx (spi_data_tx),
        .data_rx (data_rx),
        .sclk    (sclk),
        .csb     (csb),
        .miso    (miso),
        .mosi    (mosi),
        .done    (spi_done)
    );
endmodule
