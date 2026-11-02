`timescale 1ns / 1ps
/*
Data is input into the dac with the rising edge of SCLK. -> FPGA refresh mosi on the previous falling edge
Data is output from the dac on the falling edge of SCLK. -> DAC refresh miso on the falling edge -> FPGA register miso on the next rising edge
*/
// Implements the DAC5681Z 16-bit SPI interface, including transmit and readback.
module spi_dac5681z(
	input 	logic 			clk,		//125MHz system clk
	input	logic			rst,		//active high
	input 	logic 			start,		//start to transfer data
	
	input 	logic [15:0]	data_tx,	//[15:8] = instruction word bit, [7:0] = data bit
	output 	logic [7:0]		data_rx,	//data read from DAC(effective only in read mode)
	output 	logic 			sclk,		//SPI clk(CPOL=0), ~7.8MHz
	output	logic			csb,		//SDENB, active low
	
	input 	logic			miso,		//SDO (DAC->FPGA), A8
	output	logic			mosi,		//SDOIO(FPGA->DAC), A9
	output	logic			done		//tranmit done
);

    // SCLK 分频：125MHz / 16 = 7.8125MHz
    // 周期 128ns > 100ns(min)，高/低各 64ns > 40ns(min)
    localparam int SCLK_DIV = 16;
    localparam int SCLK_DIV_W = $clog2(SCLK_DIV);
    logic [SCLK_DIV_W-1:0] sclk_div_cnt;
    logic                  sclk_en;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sclk_div_cnt <= '0;
            sclk         <= 1'b0;       // CPOL=0，空闲低
        end else if (sclk_en) begin
            if (sclk_div_cnt == SCLK_DIV-1) begin
                sclk_div_cnt <= '0;
                sclk         <= ~sclk;
            end else begin
                sclk_div_cnt <= sclk_div_cnt + 1'b1;
            end
        end else begin
            sclk_div_cnt <= '0;
            sclk         <= 1'b0;
        end
    end

    // SCLK edge detect
    logic sclk_d1, sclk_d2;
    logic sclk_rise, sclk_fall;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sclk_d1 <= 1'b0;
            sclk_d2 <= 1'b0;
        end else begin
            sclk_d1 <= sclk;
            sclk_d2 <= sclk_d1;
        end
    end
    assign sclk_rise = ~sclk_d2 & sclk_d1;		// rising edge
    assign sclk_fall =  sclk_d2 & ~sclk_d1;   	// falling edge
	
    // SPI 状态机（固定 16 位：8 指令 + 8 数据）
    typedef enum {IDLE, WAIT_SETUP, SHIFT, WAIT_HOLD, DONE} state_t;
    state_t state;

    logic [4:0]  bit_cnt;     // 16..1 before each rising edge
    logic [15:0] tx_shift;
    logic [7:0]  rx_shift;
    logic [2:0]  wait_cnt;    // 扩大到 3 bit
    logic        is_read;

    // t_s(SDENB) min = 20ns → 125MHz 下取 3 拍 = 24ns
    localparam int WAIT_CYCLES = 3;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= IDLE;
            csb      <= 1'b1;
            mosi     <= 1'b0;
            done     <= 1'b0;
            data_rx  <= 8'h0;
            tx_shift <= 16'h0;
            rx_shift <= 8'h0;
            bit_cnt  <= 5'd0;
            sclk_en  <= 1'b0;
            is_read  <= 1'b0;
            wait_cnt <= 3'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE:
                begin
                    csb     <= 1'b1;
                    sclk_en <= 1'b0;
                    if (start) begin
                        tx_shift <= data_tx;
                        is_read  <= data_tx[15];     // MSB = R/W
                        bit_cnt  <= 5'd16;
                        csb      <= 1'b0;
                        mosi     <= data_tx[15];     // 首发 bit 提前放上
                        wait_cnt <= 3'd0;
                        state    <= WAIT_SETUP;
                    end
                end

                // CS 建立时间（≥20ns）后启动 SCLK
                WAIT_SETUP:
                begin
                    if (wait_cnt < WAIT_CYCLES) begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end else begin
                        sclk_en <= 1'b1;
                        state   <= SHIFT;
                        wait_cnt <= 3'd0;
                    end
                end

                SHIFT:
                begin
                    // 上升沿：DAC 采样 MOSI；FPGA 采样 MISO
                    if (sclk_rise) begin
                        tx_shift <= {tx_shift[14:0], 1'b0};

                        // 读操作：后 8 位（bit_cnt 7..0）收 SDO
                        if (is_read && bit_cnt <= 8)
                            rx_shift <= {rx_shift[6:0], miso};

                        if (bit_cnt != 0)
                            bit_cnt <= bit_cnt - 1'b1;
                    end

                    // 下降沿：刷新下一 bit 到 MOSI
                    // （DAC 在下一个上升沿采样，建立时间充足）
                    if (sclk_fall) begin
                        mosi <= tx_shift[15];
						if (bit_cnt == 0) begin
							state <= WAIT_HOLD;
							wait_cnt <= 4'd0;
						end
                    end
                end

                // CS 保持时间（≥20ns）后释放
                WAIT_HOLD:
                begin
                    if (wait_cnt < WAIT_CYCLES) begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end else begin
                        sclk_en <= 1'b0;
                        state   <= DONE;
                    end
                end

                DONE:
                begin
                    data_rx <= rx_shift;
                    csb     <= 1'b1;
                    done    <= 1'b1;
                    state   <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule