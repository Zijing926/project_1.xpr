`timescale 1ns / 1ps

// ============================================================================
// 1. Top-Level Module: 8並列ポリフェーズDDS (osc_en ゼロクロス発振制御付き)
// ============================================================================
module dds_8lane_top #(
    parameter string INIT_FILE = "dds_sincos_lut.mem" // BRAM初期化ファイル名
)(
    input  logic               clk,        // 125MHz システムクロック
    input  logic               rst,        // 同期リセット (Active High)
    
    // 発振制御 & 動的パラメータ制御インターフェース (clkドメイン同期)
    input  logic               osc_en,     // 1: 発振開始/継続, 0: ゼロクロス同期停止
    input  logic               update_en,  // パラメータ更新トリガ (1クロックパルス)
    input  logic        [31:0] phase_inc,  // 1Gsps基準の位相増分 (例: 10MHz = 32'd42949673)
    input  logic        [15:0] amp_in,     // 振幅設定値 (Unsigned: 0 ~ 65535)
    
    // SerDes / DAC 出力インターフェース
    output logic signed [15:0] dout [7:0], // 8サンプル並列出力 (Stage 10出力, 2の補数)
    output logic               dout_valid  // パイプライン有効フラグ (Stage 10同期)
);

    // ------------------------------------------------------------------------
    // Stage 0: 周波数設定値 (phase_inc) の入力ラッチ
    // ------------------------------------------------------------------------
    logic [31:0] pinc_s0;

    always_ff @(posedge clk) begin
        if (rst) begin
            pinc_s0 <= 32'd0;
        end else if (update_en) begin
            pinc_s0 <= phase_inc;
        end
    end

    // ------------------------------------------------------------------------
    // Stage 1: レーン別位相オフセット (k * dtheta, k=0..8) の事前計算
    // ------------------------------------------------------------------------
    logic [31:0] step_s1 [8:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k <= 8; k++) step_s1[k] <= 32'd0;
        end else begin
            step_s1[0] <= 32'd0;
            step_s1[1] <= pinc_s0;
            step_s1[2] <= pinc_s0 << 1;
            step_s1[3] <= (pinc_s0 << 1) + pinc_s0;
            step_s1[4] <= pinc_s0 << 2;
            step_s1[5] <= (pinc_s0 << 2) + pinc_s0;
            step_s1[6] <= (pinc_s0 << 2) + (pinc_s0 << 1);
            step_s1[7] <= (pinc_s0 << 3) - pinc_s0;
            step_s1[8] <= pinc_s0 << 3; // ベース位相更新用 (8 * dtheta)
        end
    end

    // ------------------------------------------------------------------------
    // Stage 2: 発振制御ステートマシン & ゼロクロス同期・位相/振幅割り当て
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE,    // 停止状態 (位相=0, 振幅=0)
        ST_RUN,     // 通常発振中
        ST_WAIT_ZC  // 停止要求後のゼロクロス待ち (一旦必ずST_IDLEへ止める)
    } osc_state_t;

    osc_state_t  osc_state_s2;
    logic [31:0] theta_base_s2;
    logic [31:0] theta_next_comb [7:0];
    logic [31:0] theta_s2        [7:0];

    // ゼロクロス・振幅制御用レジスタ (Stage 2)
    logic [15:0] amp_curr_s2;       // 現在適用中の設定振幅
    logic [15:0] amp_next_s2;       // ゼロクロス待機中の次期設定振幅
    logic        amp_pending_s2;    // 振幅変更のゼロクロス待機フラグ
    logic        prev_lane7_msb_s2; // 前クロックのLane 7の位相MSB (符号ビット)
    logic        zc_detected_comb;  // 現クロック内でゼロクロスが発生したか
    logic [15:0] amp_s2 [7:0];      // 各レーンに割り当てられた出力振幅値 (Stage 2出力)

    // 次クロックの各レーン位相とゼロクロス有無を組み合わせ回路で算出
    always_comb begin
        for (int k = 0; k < 8; k++) begin
            theta_next_comb[k] = theta_base_s2 + step_s1[k];
        end
        // 前クロックのLane 7と現クロックのLane 7のMSBが異なれば、この8サンプル内でゼロクロス発生
        zc_detected_comb = (theta_next_comb[7][31] != prev_lane7_msb_s2);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            osc_state_s2      <= ST_IDLE;
            theta_base_s2     <= 32'd0;
            prev_lane7_msb_s2 <= 1'b0;
            amp_curr_s2       <= 16'd0;
            amp_next_s2       <= 16'd0;
            amp_pending_s2    <= 1'b0;
            for (int k = 0; k < 8; k++) begin
                theta_s2[k] <= 32'd0;
                amp_s2[k]   <= 16'd0;
            end
        end else begin
            case (osc_state_s2)
                // ============================================================
                // 1. 停止状態 (ST_IDLE): 位相は常に0にリセット
                // ============================================================
                ST_IDLE: begin
                    // 停止中の振幅更新はゼロクロス待ち不要のため即座に反映
                    if (update_en) begin
                        amp_curr_s2    <= amp_in;
                        amp_next_s2    <= amp_in;
                        amp_pending_s2 <= 1'b0;
                    end else if (amp_pending_s2) begin
                        amp_curr_s2    <= amp_next_s2;
                        amp_pending_s2 <= 1'b0;
                    end

                    if (osc_en) begin
                        // 発振開始！ 位相0 (step_s1[0]=0) からスタート
                        osc_state_s2      <= ST_RUN;
                        theta_base_s2     <= step_s1[8];
                        prev_lane7_msb_s2 <= step_s1[7][31];
                        for (int k = 0; k < 8; k++) begin
                            theta_s2[k] <= step_s1[k];
                            amp_s2[k]   <= update_en ? amp_in : (amp_pending_s2 ? amp_next_s2 : amp_curr_s2);
                        end
                    end else begin
                        // 停止継続: 位相も振幅も0を維持
                        osc_state_s2      <= ST_IDLE;
                        theta_base_s2     <= 32'd0;
                        prev_lane7_msb_s2 <= 1'b0;
                        for (int k = 0; k < 8; k++) begin
                            theta_s2[k] <= 32'd0;
                            amp_s2[k]   <= 16'd0;
                        end
                    end
                end

                // ============================================================
                // 2. 通常発振状態 (ST_RUN)
                // ============================================================
                ST_RUN: begin
                    if (!osc_en) begin
                        // 停止要求 (osc_en == 0) 発生！
                        // 新しい振幅設定が同時に来ていたら次期振幅として記憶しておく
                        if (update_en) begin
                            amp_next_s2    <= amp_in;
                            amp_pending_s2 <= 1'b1;
                        end

                        // 周波数0または無音時、あるいはちょうど今ゼロクロスした場合は即 ST_IDLE へ
                        if (amp_curr_s2 == 16'd0 || step_s1[1] == 32'd0 || zc_detected_comb) begin
                            osc_state_s2      <= ST_IDLE;
                            theta_base_s2     <= 32'd0;
                            prev_lane7_msb_s2 <= 1'b0;
                            if (amp_pending_s2) begin
                                amp_curr_s2    <= amp_next_s2;
                                amp_pending_s2 <= 1'b0;
                            end
                            for (int k = 0; k < 8; k++) begin
                                // ゼロクロス前のレーンだけ波形を出し切り、ゼロクロス後は振幅0で停止
                                if (amp_curr_s2 == 16'd0 || step_s1[1] == 32'd0 || (theta_next_comb[k][31] != prev_lane7_msb_s2)) begin
                                    theta_s2[k] <= 32'd0;
                                    amp_s2[k]   <= 16'd0;
                                end else begin
                                    theta_s2[k] <= theta_next_comb[k];
                                    amp_s2[k]   <= amp_curr_s2;
                                end
                            end
                        end else begin
                            // 現クロックではまだゼロクロスしていない -> ST_WAIT_ZC へ遷移して発振継続
                            osc_state_s2      <= ST_WAIT_ZC;
                            theta_base_s2     <= theta_base_s2 + step_s1[8];
                            prev_lane7_msb_s2 <= theta_next_comb[7][31];
                            for (int k = 0; k < 8; k++) begin
                                theta_s2[k] <= theta_next_comb[k];
                                amp_s2[k]   <= amp_curr_s2;
                            end
                        end
                    end else begin
                        // osc_en == 1: 通常発振を継続
                        osc_state_s2      <= ST_RUN;
                        theta_base_s2     <= theta_base_s2 + step_s1[8];
                        prev_lane7_msb_s2 <= theta_next_comb[7][31];
                        for (int k = 0; k < 8; k++) begin
                            theta_s2[k] <= theta_next_comb[k];
                        end

                        // 動的振幅変更のゼロクロス同期処理
                        if (update_en) begin
                            if (amp_curr_s2 == 16'd0 || step_s1[1] == 32'd0) begin
                                amp_curr_s2    <= amp_in;
                                amp_next_s2    <= amp_in;
                                amp_pending_s2 <= 1'b0;
                                for (int k = 0; k < 8; k++) amp_s2[k] <= amp_in;
                            end else if (zc_detected_comb) begin
                                amp_curr_s2    <= amp_in;
                                amp_next_s2    <= amp_in;
                                amp_pending_s2 <= 1'b0;
                                for (int k = 0; k < 8; k++) begin
                                    if (theta_next_comb[k][31] != prev_lane7_msb_s2)
                                        amp_s2[k] <= amp_in;
                                    else
                                        amp_s2[k] <= amp_curr_s2;
                                end
                            end else begin
                                amp_next_s2    <= amp_in;
                                amp_pending_s2 <= 1'b1;
                                for (int k = 0; k < 8; k++) amp_s2[k] <= amp_curr_s2;
                            end
                        end else if (amp_pending_s2) begin
                            if (zc_detected_comb) begin
                                amp_curr_s2    <= amp_next_s2;
                                amp_pending_s2 <= 1'b0;
                                for (int k = 0; k < 8; k++) begin
                                    if (theta_next_comb[k][31] != prev_lane7_msb_s2)
                                        amp_s2[k] <= amp_next_s2;
                                    else
                                        amp_s2[k] <= amp_curr_s2;
                                end
                            end else begin
                                for (int k = 0; k < 8; k++) amp_s2[k] <= amp_curr_s2;
                            end
                        end else begin
                            for (int k = 0; k < 8; k++) amp_s2[k] <= amp_curr_s2;
                        end
                    end
                end

                // ============================================================
                // 3. 停止用ゼロクロス待ち状態 (ST_WAIT_ZC)
                //    ※ 途中で osc_en == 1 になっても、必ず一旦 ST_IDLE へ止める
                // ============================================================
                ST_WAIT_ZC: begin
                    // 待機中に update_en が来たら次期振幅として保持
                    if (update_en) begin
                        amp_next_s2    <= amp_in;
                        amp_pending_s2 <= 1'b1;
                    end

                    if (zc_detected_comb || step_s1[1] == 32'd0) begin
                        // ゼロクロス検出！ ゼロクロス後のレーンを振幅0にして ST_IDLE へ遷移
                        osc_state_s2      <= ST_IDLE;
                        theta_base_s2     <= 32'd0;
                        prev_lane7_msb_s2 <= 1'b0;
                        if (update_en) begin
                            amp_curr_s2    <= amp_in;
                            amp_pending_s2 <= 1'b0;
                        end else if (amp_pending_s2) begin
                            amp_curr_s2    <= amp_next_s2;
                            amp_pending_s2 <= 1'b0;
                        end

                        for (int k = 0; k < 8; k++) begin
                            if (step_s1[1] == 32'd0 || (theta_next_comb[k][31] != prev_lane7_msb_s2)) begin
                                theta_s2[k] <= 32'd0;
                                amp_s2[k]   <= 16'd0; // ゼロクロス通過後のレーンを0にミュート
                            end else begin
                                theta_s2[k] <= theta_next_comb[k];
                                amp_s2[k]   <= amp_curr_s2; // ゼロクロス前のレーンは最後まで出力
                            end
                        end
                    end else begin
                        // まだゼロクロスに達していないため発振継続
                        osc_state_s2      <= ST_WAIT_ZC;
                        theta_base_s2     <= theta_base_s2 + step_s1[8];
                        prev_lane7_msb_s2 <= theta_next_comb[7][31];
                        for (int k = 0; k < 8; k++) begin
                            theta_s2[k] <= theta_next_comb[k];
                            amp_s2[k]   <= amp_curr_s2;
                        end
                    end
                end

                default: osc_state_s2 <= ST_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Stage 3 & Stage 4: 4個の TDP BRAM 読み出し & 微少位相・振幅の遅延調整
    // ------------------------------------------------------------------------
    logic        [9:0]  lut_addr_s2  [7:0];
    logic signed [16:0] d_s2         [7:0];
    logic signed [16:0] d_s3         [7:0];
    logic signed [16:0] d_s4         [7:0];
    logic        [15:0] amp_s3       [7:0];
    logic        [15:0] amp_s4       [7:0];
    logic        [35:0] bram_dout_s4 [7:0];

    always_comb begin
        for (int k = 0; k < 8; k++) begin
            lut_addr_s2[k] = theta_s2[k][31:22];
            d_s2[k]        = {~theta_s2[k][21], theta_s2[k][20:5]};
        end
    end

    always_ff @(posedge clk) begin
        for (int k = 0; k < 8; k++) begin
            // Stage 3
            d_s3[k]   <= d_s2[k];
            amp_s3[k] <= amp_s2[k];

            // Stage 4
            d_s4[k]   <= d_s3[k];
            amp_s4[k] <= amp_s3[k];
        end
    end

    genvar b;
    generate
        for (b = 0; b < 4; b++) begin : gen_bram
            dds_tdp_bram_lut #(
                .INIT_FILE(INIT_FILE)
            ) u_bram (
                .clk      (clk),
                .addr_a_s2(lut_addr_s2[2*b]),
                .dout_a_s4(bram_dout_s4[2*b]),
                .addr_b_s2(lut_addr_s2[2*b + 1]),
                .dout_b_s4(bram_dout_s4[2*b + 1])
            );
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Stage 5 ~ Stage 10: 8レーン並列 DSP補間 (Stage 5~7) & 振幅乗算 (Stage 8~10)
    // ------------------------------------------------------------------------
    genvar lane;
    generate
        for (lane = 0; lane < 8; lane++) begin : gen_dsp_lane
            dds_taylor_dsp_lane u_dsp_lane (
                .clk     (clk),
                .s_lut_s4(signed'(bram_dout_s4[lane][35:18])),
                .c_lut_s4(signed'(bram_dout_s4[lane][17:0])),
                .d_s4    (d_s4[lane]),
                .amp_s4  (amp_s4[lane]),
                .dout_s10(dout[lane])
            );
        end
    endgenerate

    // パイプライン有効信号の生成 (Stage 1 ~ Stage 10 の10クロック遅延)
    logic [10:1] valid_shreg;
    always_ff @(posedge clk) begin
        if (rst) valid_shreg <= 10'b0;
        else     valid_shreg <= {valid_shreg[9:1], 1'b1};
    end
    assign dout_valid = valid_shreg[10];

endmodule


// ============================================================================
// 2. True Dual-Port BRAM Module (Stage 2 入力 -> Stage 4 出力: 2クロック遅延)
// ============================================================================
module dds_tdp_bram_lut #(
    parameter string INIT_FILE = "dds_sincos_lut.mem"
)(
    input  logic        clk,
    input  logic [9:0]  addr_a_s2,
    output logic [35:0] dout_a_s4,
    input  logic [9:0]  addr_b_s2,
    output logic [35:0] dout_b_s4
);

    (* ram_style = "block" *) logic [35:0] rom_mem [0:1023];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, rom_mem);
        end
    end

    logic [35:0] rdata_a_s3, rdata_b_s3;

    always_ff @(posedge clk) begin
        // Stage 3: BRAM内部メモリコア読み出しラッチ
        rdata_a_s3 <= rom_mem[addr_a_s2];
        rdata_b_s3 <= rom_mem[addr_b_s2];

        // Stage 4: BRAM内部出力レジスタ (DOA_REG / DOB_REG = 1)
        dout_a_s4  <= rdata_a_s3;
        dout_b_s4  <= rdata_b_s3;
    end

endmodule


// ============================================================================
// 3. DSP演算モジュール (Stage 4 入力 -> Stage 10 出力: 6クロック遅延)
// ============================================================================
module dds_taylor_dsp_lane (
    input  logic               clk,
    input  logic signed [17:0] s_lut_s4, // Stage 4: 18bit signed sin(phi_M)
    input  logic signed [17:0] c_lut_s4, // Stage 4: 18bit signed (pi/4)*cos(phi_M)
    input  logic signed [16:0] d_s4,     // Stage 4: 17bit signed 微少位相 (-65536 ~ +65535)
    input  logic        [15:0] amp_s4,   // Stage 4: 16bit unsigned 振幅設定 (0 ~ 65535)
    output logic signed [15:0] dout_s10  // Stage 10: 16bit signed 最終出力 (2の補数)
);

    // ------------------------------------------------------------------------
    // DSP #1: 1次テイラー級数補間 (Stage 5 -> Stage 6 -> Stage 7)
    // ------------------------------------------------------------------------
    logic signed [17:0] s_s5;
    logic signed [17:0] c_s5;
    logic signed [16:0] d_s5;
    logic        [15:0] amp_s5;

    logic signed [17:0] s_s6;
    logic signed [34:0] mult1_s6;
    logic        [15:0] amp_s6;

    logic signed [47:0] p1_s7;
    logic        [15:0] amp_s7;

    localparam logic signed [47:0] ROUND_DSP1 = 48'sd16777216; // 2^24

    always_ff @(posedge clk) begin
        // Stage 5
        s_s5     <= s_lut_s4;
        c_s5     <= c_lut_s4;
        d_s5     <= d_s4;
        amp_s5   <= amp_s4;

        // Stage 6
        s_s6     <= s_s5;
        mult1_s6 <= c_s5 * d_s5;
        amp_s6   <= amp_s5;

        // Stage 7
        p1_s7    <= (48'(s_s6) <<< 25) + 48'(mult1_s6) + ROUND_DSP1;
        amp_s7   <= amp_s6;
    end

    wire signed [17:0] sin_interp_s7 = p1_s7[42:25];

    // ------------------------------------------------------------------------
    // DSP #2: 動的振幅スケーリング (Stage 8 -> Stage 9 -> Stage 10)
    // ------------------------------------------------------------------------
    logic signed [17:0] sin_s8;
    logic signed [16:0] amp_s8;
    logic signed [34:0] mult2_s9;
    logic signed [47:0] p2_s10;

    localparam logic signed [47:0] ROUND_DSP2 = 48'sd131072; // 2^17

    always_ff @(posedge clk) begin
        // Stage 8
        sin_s8   <= sin_interp_s7;
        amp_s8   <= {1'b0, amp_s7};

        // Stage 9
        mult2_s9 <= sin_s8 * amp_s8;

        // Stage 10
        p2_s10   <= 48'(mult2_s9) + ROUND_DSP2;
    end

    assign dout_s10 = p2_s10[33:18];

endmodule