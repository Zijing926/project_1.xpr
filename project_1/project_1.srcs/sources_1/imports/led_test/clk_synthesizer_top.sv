`timescale 1ns / 1ps

/**
 * @module clk_synthesizer_top
 * @brief AD9517-3 配置顶层：自动配置 + VIO 手动读写并存
 */
module clk_synthesizer_top (
    // Differential clk innput(VCXO 125MHz)
    input logic  sys_clk_125m,
    input logic  rst,
    // AD9517 SPI interface
    output logic PLL_SCLK,
    output logic PLL_CSB,
    inout wire 	 PLL_SDIO,
    output logic PLL_RESETB,
    // AD9517 other interface
    output logic PLL_REF_SEL,
    output logic PLL_PDB,
    input logic  PLL_STATUS,
    output logic PLL_SYNCB,			    
    // For debug
    output logic auto_cfg_done 
);


  // ---------- VIO signal ----------
    logic [23:0] manual_data_tx;        //probe_out0: 手模式 SPI 数据
    logic        manual_start;          //manual Start button
    logic        vio_reset;
    logic        auto_cfg_boot_pending;
    logic        auto_cfg_boot_active;
        
    // ========== VIO edge detect ==========
    logic manual_start_dly;
        logic manual_start_pulse;
    always_ff @(posedge sys_clk_125m) begin
        manual_start_dly <= manual_start;
    end
    assign manual_start_pulse = manual_start && !manual_start_dly;              // pulse of manual Start button


    // ---------- SPI signal ----------
    logic        spi_start;
    logic [7:0]  spi_data_rx;
    logic        spi_done;
    logic        spi_sdio_oe;
    logic        spi_mosi;
    logic        spi_miso;

    // ---------- 自动配置模块信号 ----------
    logic        auto_spi_start;
    logic [23:0] auto_spi_data_tx;

    always_ff @(posedge sys_clk_125m) begin
        if (rst) begin
            auto_cfg_boot_pending <= 1'b1;
            auto_cfg_boot_active  <= 1'b1;
        end else begin
            auto_cfg_boot_pending <= 1'b0;
            if (auto_cfg_done)
                auto_cfg_boot_active <= 1'b0;
        end
    end
    // ---------- SPI signal after multiplexer(MUX) ----------
    logic        spi_start_mux;
    logic [23:0] spi_data_tx_mux;
    assign spi_start_mux   = auto_cfg_boot_active ? auto_spi_start : manual_start_pulse;
    assign spi_data_tx_mux = auto_cfg_boot_active ? auto_spi_data_tx : manual_data_tx;
	
    // ========== SPI Master ==========
    spi_master u_spi_master (
        .clk        (sys_clk_125m),
        .rst        (rst),
        .start      (spi_start_mux),
        .data_tx    (spi_data_tx_mux),
        .data_rx    (spi_data_rx),
        .sclk       (PLL_SCLK),
        .csb        (PLL_CSB),
        .miso       (spi_miso),
        .mosi       (spi_mosi),
        .sdio_oe    (spi_sdio_oe),
        .done       (spi_done),
        .cpol       (1'b0)
    );

    // ========== 自动配置模块 ==========
    ad9517_config ad9517_config_inst (
        .clk        (sys_clk_125m),
        .rst        (rst),
        .cfg_start  (auto_cfg_boot_pending && !rst),
        .spi_done   (spi_done),
        .spi_start  (auto_spi_start),
        .spi_data_tx(auto_spi_data_tx),
        .cfg_done   (auto_cfg_done)
    );

   
    // ========== physical pin connection ==========
    assign PLL_SDIO   = spi_sdio_oe ? spi_mosi : 1'bz;
    assign spi_miso   = PLL_SDIO;
    assign PLL_RESETB = !vio_reset;
    assign PLL_REF_SEL = 1'b0;
    assign PLL_PDB     = 1'b1;
    assign PLL_SYNCB   = 1'b1; 

endmodule
