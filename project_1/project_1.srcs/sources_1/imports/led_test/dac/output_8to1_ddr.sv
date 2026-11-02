/******************************************************************************
 * Module Name : output_8to1_ddr
 * Description (EN):
 *   8:1 DDR LVDS serializer using Xilinx OSERDESE2 primitive.
 *   Converts 8 parallel samples per bit lane into a DDR serial stream
 *   at 1/4 the parallel clock frequency, output as LVDS differential pairs.
 *
 *   Each bit lane instantiates one OSERDESE2 (DDR, 8:1) + OBUFDS pair.
 *   Total BIT_WIDTH lanes are generated in parallel via a generate loop.
 *
 *   Clock Relationship:
 *     clk_500m  = 500MHz (DDR high-speed shift clock, both edges)
 *     clk_125m  = 125MHz (parallel load clock, clk_500m / 4)
 *     Effective data rate per lane = 125MHz × 8 = 1000 Mbps (DDR)
 *
 * Description (ZH):
 *   基于 Xilinx OSERDESE2 原语的 8:1 DDR LVDS 串行化模块。
 *   将每个 bit lane 的 8 个并行采样点转换为 DDR 串行流，
 *   时钟频率为并行时钟的 1/4，输出为 LVDS 差分对。
 *
 *   每个 bit lane 例化一组 OSERDESE2（DDR, 8:1）+ OBUFDS。
 *   通过 generate 循环并行生成 BIT_WIDTH 个 lane。
 *
 *   时钟关系：
 *     clk_500m  = 500MHz（DDR 高速移位时钟，双边沿）
 *     clk_125m  = 125MHz（并行装载时钟，clk_500m / 4）
 *     每 lane 有效数据率 = 125MHz × 8 = 1000 Mbps（DDR）
 *
 * Parameters:
 *   BIT_WIDTH - Number of parallel bit lanes (default: 16)
 *               Also equals number of LVDS differential output pairs
 *
 * Ports:
 *   clk_500m       - 500MHz DDR high-speed clock (OSERDES CLK pin)
 *   clk_125m       - 125MHz parallel load clock (OSERDES CLKDIV pin)
 *   rst_125m       - Active-high reset synchronized to clk_125m domain
 *   parallel_in    - [7:0] time samples × [BIT_WIDTH-1:0] bit data
 *                    parallel_in[0] is transmitted first (D1 of OSERDES)
 *                    parallel_in[7] is transmitted last  (D8 of OSERDES)
 *   serial_out_p   - LVDS positive outputs, one pair per bit lane
 *   serial_out_n   - LVDS negative outputs, one pair per bit lane
 *
 * OSERDESE2 Configuration:
 *   DATA_RATE_OQ   : DDR (dual-edge output)
 *   DATA_WIDTH     : 8 (8:1 serialization)
 *   SERDES_MODE    : MASTER (no slave cascade needed for 8:1)
 *   OQ latency     : 4 CLKDIV cycles from input to first output bit
 *
 * Timing Notes:
 *   - D1~D8 are shifted out in order on DDR edges of clk_500m
 *   - First CLKDIV cycle after reset: D1 appears on first DDR edge
 *   - OBUFDS uses IOSTANDARD from XDC (typically LVDS_25)
 *   - All BIT_WIDTH lanes share the same clock and reset
 *
 * Constraints Required (XDC):
 *   set_property IOSTANDARD LVDS_25 [get_ports serial_out_p[*]]
 *   set_property IOSTANDARD LVDS_25 [get_ports serial_out_n[*]]
 *   set_property DIFF_TERM FALSE [get_ports serial_out_*]
 *
 * Example Usage:
 *   output_8to1_ddr #(.BIT_WIDTH(16)) u_data_serdes (
 *     .clk_500m(clk_500m), .clk_125m(clk_125m), .rst_125m(rst),
 *     .parallel_in(dds_data), .serial_out_p(dac_dp), .serial_out_n(dac_dn)
 *   );
 *
 *****************************************************************************/
`default_nettype none
`default_nettype none

module output_8to1_ddr
  #(
    parameter int BIT_WIDTH = 16 
  )
  (
   input wire 		       clk_500m,
   input wire 		       clk_125m,
   input wire 		       rst_125m,
   input wire [BIT_WIDTH-1:0]  parallel_in[7:0], 
   output wire [BIT_WIDTH-1:0] serial_out_p,
   output wire [BIT_WIDTH-1:0] serial_out_n
   );

   wire [BIT_WIDTH-1:0] serial_out;

   genvar i;
   generate
      for (i = 0; i < BIT_WIDTH; i = i + 1) begin : gen_serdes_lane
         
         OSERDESE2 
           #(
             .DATA_RATE_OQ   ("DDR"),       
             .DATA_RATE_TQ   ("BUF"),       
             .DATA_WIDTH     (8),           
             .INIT_OQ        (1'b0),        
             .INIT_TQ        (1'b0),
             .SERDES_MODE    ("MASTER"),    
             .SRVAL_OQ       (1'b0),        
             .SRVAL_TQ       (1'b0),
             .TBYTE_CTL      ("FALSE"),
             .TBYTE_SRC      ("FALSE"),
             .TRISTATE_WIDTH (1)
             )
         u_oserdese2 
           (
            .OQ        (serial_out[i]),
            .OFB       (),
            .TQ        (),
            .TFB       (),
            .SHIFTOUT1 (),
            .SHIFTOUT2 (),
            .SHIFTIN1  (1'b0),
            .SHIFTIN2  (1'b0),
            .CLK       (clk_500m),
            .CLKDIV    (clk_125m),
            .OCE       (1'b1),
            .RST       (rst_125m),
            
            // --- パラレルデータ入力 ---
            // parallel_in[時間サンプル(0〜7)][ビット番号(i)] の順で指定する
            //翻译：并行数据输入​ — 按 parallel_in[时间采样点(0~7)][位序号(i)] 的顺序指定。
            .D1        (parallel_in[0][i]), // 先頭データ (dout[0] の bit i)
            .D2        (parallel_in[1][i]), // 2番目      (dout[1] の bit i)
            .D3        (parallel_in[2][i]),
            .D4        (parallel_in[3][i]),
            .D5        (parallel_in[4][i]),
            .D6        (parallel_in[5][i]),
            .D7        (parallel_in[6][i]),
            .D8        (parallel_in[7][i]), // 最後データ (dout[7] の bit i)
            
            .TCE       (1'b0),
            .TBYTEIN   (1'b0),
            .TBYTEOUT  (),
            .T1        (1'b0),
            .T2        (1'b0),
            .T3        (1'b0),
            .T4        (1'b0)
            );
          
         OBUFDS u_obufds 
           (
            .I  (serial_out[i]),
            .O  (serial_out_p[i]),
            .OB (serial_out_n[i])
            );

      end
   endgenerate

endmodule

`default_nettype wire
