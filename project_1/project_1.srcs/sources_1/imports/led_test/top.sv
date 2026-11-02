`default_nettype none

module top
  (
   input wire 	       VCXO_OUT,
   input wire 	       VCXO_OUTB,
   //
   // AD9517 SPI interface
   output logic        PLL_SCLK,
   output logic        PLL_CSB,
   inout wire 	       PLL_SDIO,
   output logic        PLL_RESETB,
   // AD9517 other interface
   output logic        PLL_REF_SEL,
   output logic        PLL_PDB,
   input wire 	       PLL_STATUS,
   output logic        PLL_SYNCB,
   // reference clock
   output logic        PLL_REFIN,
   output logic        PLL_REFINB,
   // PLL clock input (AD9517 OUT6/OUT6B)
   input wire 	       PLL_OUT1,
   input wire 	       PLL_OUT1B,
   // PLL LD input
   input wire 	       PLL_LD,
   // 232C
   input wire 	       RS232C_RXD, 
   output logic        RS232C_TXD,
   // HS DAC
   input wire 	       HDAC_SDO,
   output logic        HDAC_RESETB,
   output logic        HDAC_SCLK,
   output logic        HDAC_SDENB,
   output logic        HDAC_SDIO,
   output logic        HDAC_DCLKP,
   output logic        HDAC_DCLKN,
   output logic [15:0] HDAC_D_P,
   output logic [15:0] HDAC_D_N,
   output logic        HDAC_SYNCP,
   output logic        HDAC_SYNCN,
   // LED
   output logic [7:0]  led
   );
  
   logic 	      vcxo_clk_125m;
   logic 	      por_rst;
   

   // ========== power on reset ==========
   por_reset u_por_reset (
			  .clk (vcxo_clk_125m),
			  .rst (por_rst)
			  );

   // ========== reference clock 62.5MHz ==========
   ref_clk_gen u_ref_clk_gen (
			      .vcxo_out_p   (VCXO_OUT),
			      .vcxo_out_n   (VCXO_OUTB),

			      .rst          (por_rst),
			      .vcxo_clk_125m (vcxo_clk_125m),
			      .PLL_REFIN    (PLL_REFIN),
			      .PLL_REFINB   (PLL_REFINB)
			      );


   // ========== AD9517 config ==========
   logic clk_synthesizer_top_cfg_done;
	
   clk_synthesizer_top u_clk_synthesizer_top 
     (
      .sys_clk_125m(vcxo_clk_125m),
      .rst(por_rst),
      // AD9517 SPI interface
      .PLL_SCLK(PLL_SCLK),
      .PLL_CSB(PLL_CSB),
      .PLL_SDIO(PLL_SDIO),
      .PLL_RESETB(PLL_RESETB),
      // AD9517 other interface
      .PLL_REF_SEL(PLL_REF_SEL),
      .PLL_PDB(PLL_PDB),
      .PLL_STATUS(PLL_STATUS),
      .PLL_SYNCB(PLL_SYNCB),
      // For debug
      .auto_cfg_done_out(clk_synthesizer_top_cfg_done)
      );

   // ========== AD9517 OUT6 differential input ==========
   logic sys_clk_500m;  
   logic sys_clk_125m;  
   logic sys_clk_locked;

   clk_wiz_1 u_clk_wiz_1
     (
      .clk_in1_p(PLL_OUT1),
      .clk_in1_n(PLL_OUT1B),
      .reset(~PLL_LD),
      .locked(sys_clk_locked),
      .clk_out1(sys_clk_500m), // 500 MHz
      .clk_out2(), // 125 MHz 
      .clk_out3(sys_clk_125m)  // 125 MHz
      );

   logic sys_rst_125m;
   logic [3:0] sys_rst_125m_sr;

   always_ff @(posedge sys_clk_125m or negedge sys_clk_locked) begin
      if (!sys_clk_locked)
	      sys_rst_125m_sr <= 4'b1111;
      else
	      sys_rst_125m_sr <= {sys_rst_125m_sr[2:0], 1'b0};
   end

   assign sys_rst_125m = sys_rst_125m_sr[3];

   // ======= Core System ======
   logic signed [15:0] data_to_dac[7:0];
   
   core_system_top
     #(
       .CLK_FREQ(125_000_000),
       .BAUD_RATE(115200),
       .TIMEOUT_MS(50),
       .LUT_FILE("dds_sincos_lut.mem")
       )
   u_core_system_top
     (
      .sys_clk(sys_clk_125m),
      .sys_rst(sys_rst_125m),
      .rs232_rx_in(RS232C_RXD),
      .rs232_tx_out(RS232C_TXD),
      .dds_dout(data_to_dac),
      .debug_out()
      );
   
    // ======== HS DAC ========
    logic dac_spi_manager_done;
    logic [15:0] data_tx;
    logic [7:0]  data_rx;
    logic        vio_start;
    // VIO controls the transmit word and start level, and displays received data.
    vio_0 vio_inst (
        .clk        (vcxo_clk_125m),
        .probe_out0 (data_tx),
        .probe_out1 (vio_start),
        .probe_in0  (data_rx)
    );

    dac_spi_manager dac_spi_manager_inst (
        .clk           (vcxo_clk_125m),
        .rst           (por_rst),
        .miso          (HDAC_SDO),
        .user_data_tx  (data_tx),
        .user_start    (vio_start),
        .data_rx       (data_rx),
        .sclk          (HDAC_SCLK),
        .csb           (HDAC_SDENB),
        .mosi          (HDAC_SDIO),
        .done          (dac_spi_manager_done),
        .resetb        (HDAC_RESETB)
    );

   // ======== BACKEND =======
   backend backend_inst
     (
      .clk_500m(sys_clk_500m),
      .clk_125m(sys_clk_125m),
      .rst_125m(sys_rst_125m),
      .din('{data_to_dac[7], data_to_dac[6], data_to_dac[5], data_to_dac[4],
	     data_to_dac[3], data_to_dac[2], data_to_dac[1], data_to_dac[0]}),
      .HDAC_D_P(HDAC_D_P),
      .HDAC_D_N(HDAC_D_N),
      .HDAC_DCLKP(HDAC_DCLKP),
      .HDAC_DCLKN(HDAC_DCLKN),
      .HDAC_SYNCP(HDAC_SYNCP),
      .HDAC_SYNCN(HDAC_SYNCN)
      );

   
   // ====== Debug ======
   logic [31:0] test_data;
   assign test_data = data_to_dac[0];
   assign led = test_data[15:0];
   ila_0 u_ila_0 (
       .clk(sys_clk_125m),
       .probe0(data_to_dac[7]),
      .probe1(data_to_dac[6])
   );
endmodule
`default_nettype wire
