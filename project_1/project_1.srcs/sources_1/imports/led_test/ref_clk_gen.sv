`timescale 1ns / 1ps

/**
 * @module ref_clk_gen
 * @brief reference clock 生成模块: VCXO differential transfer to single-end + AD9517 reference clk output
 */
module ref_clk_gen (
    // VCXO differential input
    input  logic vcxo_out_p,
    input  logic vcxo_out_n,
	
    input  logic rst,	//active high
    // 输出时钟
    output logic vcxo_clk_125m,  // system single-end clk
    output logic PLL_REFIN,     // AD9517 REFIN+ (E23)
    output logic PLL_REFINB     // AD9517 REFIN- (F22)
);

// VCXO differential transfer to single-end
IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("TRUE"),
    .IOSTANDARD("LVDS_25")
) IBUFDS_inst (
    .O(vcxo_clk_125m),
    .I(vcxo_out_p),
    .IB(vcxo_out_n)
);

  // ========== clk_wizard generate single-end clk_ref ==========
    logic clk_ref;
    logic clk_wizard_locked;

    clk_wiz_0 u_clk_wizard (
        .clk_in1  (vcxo_clk_125m),
        .clk_out1 (clk_ref),
        .locked   (clk_wizard_locked)
    );

    // LVDS output
	logic ref_clk;
    // ========== 复位同步到 clk_ref 域 ==========
    logic rst_clk_ref_sync;
    
    // 使用 Xilinx 推荐的同步器结构 (ASYNC_REG)
    (* ASYNC_REG = "TRUE" *) logic rst_sync_ff1;
    (* ASYNC_REG = "TRUE" *) logic rst_sync_ff2;
    
    always_ff @(posedge clk_ref or posedge rst) begin
        if (rst) begin
            rst_sync_ff1 <= 1'b1;
            rst_sync_ff2 <= 1'b1;
        end else begin
            rst_sync_ff1 <= 1'b0;
            rst_sync_ff2 <= rst_sync_ff1;
        end
    end
    assign rst_clk_ref_sync = rst_sync_ff2;
    ODDR2 #(
        .DDR_ALIGNMENT("NONE"),
        .INIT(1'b0),
        .SRTYPE("SYNC")
    ) ODDR2_ref_clk (
        .Q (ref_clk),
        .C0(clk_ref),
        .C1(~clk_ref),
        .CE (1'b1),
        .D0 (1'b1),
        .D1 (1'b0),
        .R  (rst_clk_ref_sync),
        .S  (1'b0)
    );

    OBUFDS #(
        .IOSTANDARD("LVDS_25")
    ) OBUFDS_ref_clk (
        .I (ref_clk),
        .O (PLL_REFIN),
        .OB(PLL_REFINB)
    );

endmodule
