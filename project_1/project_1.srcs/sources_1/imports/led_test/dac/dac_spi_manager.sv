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
    output logic        done,
    output logic        resetb
);
    // Keep RESETB low for at least 25 ns after the system reset is released.
    localparam int RESETB_HOLD_CYCLES = 5;
    logic [2:0] resetb_cnt;
    logic       resetb_released;

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

    // Start automatic register programming only after the DAC reset is released.
    dac5681_init init_inst (
        .clk            (clk),
        .rst            (rst),
        .reset_released  (resetb_released),
        .spi_done        (done),
        .spi_data_tx     (init_data_tx),
        .spi_start       (init_start),
        .ready           (init_ready)
    );

    // Give the startup sequence exclusive access until all DAC registers are set.
    always_comb begin
        spi_data_tx = user_data_tx;
        spi_start   = 1'b0;
        if (!init_ready) begin
            spi_data_tx = init_data_tx;
            spi_start   = init_start;
        end else begin
            spi_start = start_pulse;
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
        .done    (done)
    );
endmodule
