/******************************************************************************
 * Module Name : backend
 * Description (EN):
 *   LVDS DDR output backend for DAC5681 dual-channel 16-bit DAC.
 *   Converts parallel DDS data (125MHz, 8 samples deep) into
 *   8:1 DDR LVDS serial streams (500MHz DDR clock, 1Gbps per lane).
 *
 *   Uses three instances of output_8to1_ddr (wrapping OSERDESE2):
 *     - 16-lane data channel  : 16-bit parallel-to-serial DDR output
 *     - 1-lane data clock     : 250MHz LVDS clock (DDR 101010 pattern)
 *     - 1-lane frame sync     : Continuous high LVDS sync indicator
 *
 *   Data rate per lane : 125MHz × 8 = 1000 Mbps (DDR @ 500MHz)
 *   Total data width   : 16 lanes → 16 Gbps aggregate
 *
 * Description (ZH):
 *   DAC5681 双通道 16 位 DAC 的 LVDS DDR 输出后端模块。
 *   将 DDS 并行数据（125MHz，深度 8 采样）转换为
 *   8:1 DDR LVDS 串行流（500MHz DDR 时钟，每 lane 1Gbps）。
 *
 *   使用三个 output_8to1_ddr 例化（内部封装 OSERDESE2）：
 *     - 16 路数据通道 ：16 位并串转换 DDR 输出
 *     - 1 路数据时钟  ：250MHz LVDS 随路时钟（DDR 交替 1010 模式）
 *     - 1 路帧同步    ：持续高电平 LVDS 同步指示
 *
 *   每 lane 数据率 ：125MHz × 8 = 1000 Mbps（DDR @ 500MHz）
 *   总数据宽度     ：16 lanes → 16 Gbps 总带宽
 *
 * Clock Domains:
 *   clk_500m  - 500MHz DDR serial clock (OSERDES high-speed clock)
 *   clk_125m  - 125MHz parallel load clock (CLKDIV = clk_500m / 4)
 *   rst_125m  - Reset synchronized to clk_125m domain
 *
 * Ports:
 *   clk_500m      - 500MHz DDR high-speed clock input
 *   clk_125m      - 125MHz parallel data clock input
 *   rst_125m      - Active-high reset in 125MHz domain
 *   din[7:0][15:0]- 8-lane × 16-bit parallel input data from DDS
 *   HDAC_D_P/N    - 16 pairs LVDS DDR data output to DAC
 *   HDAC_DCLKP/N  - LVDS data clock output (250MHz DDR)
 *   HDAC_SYNCP/N  - LVDS frame sync output (high = data valid)
 *
 * Interface Timing (DAC5681 Source-Synchronous DDR):
 *   - Data launched on both edges of clk_500m
 *   - DCLK is center-aligned with data (DDR 101010 pattern)
 *   - SYNC held high during normal data transmission
 *
 * Dependencies:
 *   output_8to1_ddr  - 8:1 DDR OSERDES wrapper (uses OSERDESE2 + OBUFDS)
 *
 * Note:
 *   - BIT_WIDTH=16 instantiates 16 parallel OSERDESE2 primitives
 *   - DCLK pattern {1,0,1,0,1,0,1,0} produces 250MHz square wave at DDR
 *   - SYNC pattern {1,1,1,1,1,1,1,1} produces continuous high (data valid)
 *   - Ensure HDAC_D_*, HDAC_DCLK_*, HDAC_SYNC_* pins are in same LVDS bank
 *   - Match IOSTANDARD (typically LVDS_25) in XDC constraints
 *
 *****************************************************************************/
`default_nettype none
module backend
  (
   input wire 	       clk_500m,
   input wire 	       clk_125m,
   input wire 	       rst_125m,
   input wire [15:0]   din[7:0],
   output logic [15:0] HDAC_D_P,
   output logic [15:0] HDAC_D_N,
   output logic        HDAC_DCLKP,
   output logic        HDAC_DCLKN,
   output logic        HDAC_SYNCP,
   output logic        HDAC_SYNCN   
   );

   output_8to1_ddr
     #(
       .BIT_WIDTH(16)
       )
   output_8to1_ddr_data_inst
     (
      .clk_500m(clk_500m),
      .clk_125m(clk_125m),
      .rst_125m(rst_125m),
      .parallel_in(din),
      .serial_out_p(HDAC_D_P),
      .serial_out_n(HDAC_D_N)
      );

   output_8to1_ddr
     #(
       .BIT_WIDTH(1)
       )
   output_8to1_ddr_dclk_inst
     (
      .clk_500m(clk_500m),
      .clk_125m(clk_125m),
      .rst_125m(rst_125m),
      .parallel_in('{1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0}),
      .serial_out_p(HDAC_DCLKP),
      .serial_out_n(HDAC_DCLKN)
      );

   output_8to1_ddr
     #(
       .BIT_WIDTH(1)
       )
   output_8to1_ddr_sync_inst
     (
      .clk_500m(clk_500m),
      .clk_125m(clk_125m),
      .rst_125m(rst_125m),
      .parallel_in('{1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1}),
      .serial_out_p(HDAC_SYNCP),
      .serial_out_n(HDAC_SYNCN)
      );

   
endmodule
`default_nettype wire
