`timescale 1ns / 1ps
/* ---
模块功能：AXI4-Lite 从机寄存器控制器，为 SPI_Master 提供配置接口

寄存器地址映射（字节地址，4字节对齐）：

  0x00  R/W  CPOL_CPHA_REG   [0]       =spi_cpol             SPI时钟极性(CPOL)
                              [1]       =spi_cpha             SPI时钟相位(CPHA)

  0x04  R/W  RW_CMD_REG      [1:0]     =spi_rw_cmd           传输模式：
                                                                2b00 = 仅写(Write Only)
                                                                2b01 = 仅读(Read Only)
                                                                2b10 = 半双工(Write-Then-Read)
                                                                2b11 = 全双工(Simultaneous RW)

  0x08  R/W  LSB_FIRST_REG   [0]       =spi_lsb_first        位序(0=MSB优先,1=LSB优先)

  0x0C  R/W  CS_KEEP_REG     [0]       =spi_cs_keep          CS保持(1=传输后保持CS低)

  0x10  R/W  CS_SEL_REG      [31:0]    =spi_cs_sel           片选(1-hot编码,32bit)

  0x14  R/W  CLK_DIV_REG     [15:0]    =spi_clk_div          SPI时钟分频系数

  0x18  R/W  WDATA_REG       [31:0]    =spi_wdata            SPI写数据

  0x1C  R/W  TOTAL_BITS_REG  [5:0]     =spi_total_bits       总传输比特数(1~32)

  0x20  R/W  TX_BITS_REG     [5:0]     =spi_tx_bits          写阶段比特数(tx_bits≤total_bits)

  0x24  R/W  RX_BITS_REG     [5:0]     =spi_rx_bits          接收对齐位数(显式配置，见Spi_Master注释)

  0x28  R    STATUS_REG      [0]       =spi_busy             SPI忙标志(只读,硬件置位)
                              [1]       =data_avail_flag      可读数据标志(读RDATA_REG自动清除)
                              [2]       =spi_done_flag        传输完成标志(W1C清除)

  0x2C  R    RDATA_REG       [31:0]    =spi_rdata            SPI读数据(只读,快照)

  0x30  W    TRIG_REG         [0]       =spi_start            写1启动SPI传输

中断说明：
  o_intr = spi_done_flag
  - spi_done_flag   置位：i_spi_done 脉冲时（任意模式传输完成）
                    清除：PS 写 STATUS_REG [2]=1（W1C）
  - PS端典型流程：收到中断 → 读 STATUS_REG 确认 → 按需读 RDATA_REG → 写 STATUS_REG bit2=1 清除
--- */

module AXI_Lite_Slave #(
    parameter integer                               C_S_AXI_DATA_WIDTH      = 32        ,
    parameter integer                               C_S_AXI_ADDR_WIDTH      = 7
)(
    //--- AXI-Lite 时钟与复位 ---
    input  logic                                    S_AXI_ACLK                          ,
    input  logic                                    S_AXI_ARESETN                       ,

    //--- AXI-Lite 写地址通道 ---
    input  logic [C_S_AXI_ADDR_WIDTH - 1 : 0]       S_AXI_AWADDR                        ,
    input  logic [2 : 0]                            S_AXI_AWPROT                        ,
    input  logic                                    S_AXI_AWVALID                       ,
    output logic                                    S_AXI_AWREADY                       ,

    //--- AXI-Lite 写数据通道 ---
    input  logic [C_S_AXI_DATA_WIDTH - 1 : 0]       S_AXI_WDATA                         ,
    input  logic [C_S_AXI_DATA_WIDTH/8 - 1 : 0]     S_AXI_WSTRB                         ,
    input  logic                                    S_AXI_WVALID                        ,
    output logic                                    S_AXI_WREADY                        ,

    //--- AXI-Lite 写响应通道 ---
    output logic [1 : 0]                            S_AXI_BRESP                         ,
    output logic                                    S_AXI_BVALID                        ,
    input  logic                                    S_AXI_BREADY                        ,

    //--- AXI-Lite 读地址通道 ---
    input  logic [C_S_AXI_ADDR_WIDTH - 1 : 0]       S_AXI_ARADDR                        ,
    input  logic [2 : 0]                            S_AXI_ARPROT                        ,
    input  logic                                    S_AXI_ARVALID                       ,
    output logic                                    S_AXI_ARREADY                       ,

    //--- AXI-Lite 读数据通道 ---
    output logic [C_S_AXI_DATA_WIDTH - 1 : 0]       S_AXI_RDATA                         ,
    output logic [1 : 0]                            S_AXI_RRESP                         ,
    output logic                                    S_AXI_RVALID                        ,
    input  logic                                    S_AXI_RREADY                        ,

    //--- 配置输出至 SPI_Master ---
    output logic [15:0]                             o_spi_clk_div                       ,
    output logic                                    o_spi_cpol                          ,
    output logic                                    o_spi_cpha                          ,
    output logic [1 : 0]                            o_spi_rw_cmd                        ,
    output logic                                    o_spi_lsb_first                     ,
    output logic [31:0]                             o_spi_cs_sel                        ,
    output logic                                    o_spi_cs_keep                       ,

    //--- 数据路径 ---
    output logic [C_S_AXI_DATA_WIDTH - 1 : 0]       o_spi_wdata                         ,
    input  logic [C_S_AXI_DATA_WIDTH - 1 : 0]       i_spi_rdata                         ,
    input  logic                                    i_spi_rdata_valid                   ,   //--- RX数据有效脉冲（单拍）---

    //--- 控制与状态 ---
    output logic                                    o_spi_start                         ,
    input  logic                                    i_spi_busy                          ,
    input  logic                                    i_spi_done                          ,   //--- 传输完成脉冲（单拍）---
    output logic                                    o_intr                              ,   //--- 中断输出（仅spi_done_flag）---

    //--- 增强配置 ---
    output logic [5 : 0]                            o_spi_total_bits                    ,
    output logic [5 : 0]                            o_spi_tx_bits                       ,
    output logic [5 : 0]                            o_spi_rx_bits                           //--- 接收对齐位数（显式配置给Spi_Master）---
);

//--- 寄存器地址定义 ---
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_CPOL_CPHA_REG  = 7'h00;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_RW_CMD_REG     = 7'h04;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_LSB_FIRST_REG  = 7'h08;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_CS_KEEP_REG    = 7'h0C;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_CS_SEL_REG     = 7'h10;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_CLK_DIV_REG    = 7'h14;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_WDATA_REG      = 7'h18;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_TOTAL_BITS_REG = 7'h1C;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_TX_BITS_REG    = 7'h20;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_RX_BITS_REG    = 7'h24;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_STATUS_REG     = 7'h28;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_RDATA_REG      = 7'h2C;
localparam logic [C_S_AXI_ADDR_WIDTH - 1 : 0]  ADDR_TRIG_REG       = 7'h30;

//--- 内部寄存器 ---
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_cpol_cpha                       ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_rw_cmd                          ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_lsb_first                       ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_cs_keep                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_cs_sel                          ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_clk_div                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_wdata                           ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_total_bits                      ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_tx_bits                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_rx_bits                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]             reg_rdata_hold                      ;   //--- RX数据快照 ---

//--- AXI-Lite 握手内部信号 ---
logic                                           aw_en                               ;
logic [C_S_AXI_ADDR_WIDTH - 1 : 0]              axi_awaddr                          ;
logic                                           axi_awready                         ;
logic                                           axi_wready                          ;
logic                                           axi_bvalid                          ;
logic                                           axi_arready                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]              axi_rdata                           ;
logic                                           axi_rvalid                          ;
logic [1:0]                                     axi_bresp                           ;
logic [C_S_AXI_ADDR_WIDTH - 1 : 0]              axi_araddr                          ;

//--- 状态与标志 ---
logic                                           spi_start_pulse                     ;
logic                                           spi_done_flag                       ;   //--- 传输完成标志（W1C清除）---
logic                                           data_avail_flag                     ;   //--- 可读数据标志（读RDATA_REG自动清除）---

//--- AXI-Lite 接口连接 ---
assign S_AXI_AWREADY    = axi_awready   ;
assign S_AXI_WREADY     = axi_wready    ;
assign S_AXI_BRESP      = axi_bresp     ;
assign S_AXI_BVALID     = axi_bvalid    ;
assign S_AXI_ARREADY    = axi_arready   ;
assign S_AXI_RDATA      = axi_rdata     ;
assign S_AXI_RRESP      = 2'b00         ;
assign S_AXI_RVALID     = axi_rvalid    ;

//--- 配置输出连接 ---
assign o_spi_cpol           = reg_cpol_cpha[0]      ;
assign o_spi_cpha           = reg_cpol_cpha[1]      ;
assign o_spi_rw_cmd         = reg_rw_cmd[1:0]       ;
assign o_spi_lsb_first      = reg_lsb_first[0]      ;
assign o_spi_cs_keep        = reg_cs_keep[0]        ;
assign o_spi_cs_sel         = reg_cs_sel            ;
assign o_spi_clk_div        = reg_clk_div[15:0]     ;
assign o_spi_wdata          = reg_wdata             ;
assign o_spi_total_bits     = reg_total_bits[5:0]   ;
assign o_spi_tx_bits        = reg_tx_bits[5:0]      ;
assign o_spi_rx_bits        = reg_rx_bits[5:0]      ;
assign o_spi_start          = spi_start_pulse       ;

//--- o_intr：仅由 spi_done_flag 触发 ---
assign o_intr = spi_done_flag;

/* ---
 proc_awready：写地址通道 AWREADY
 复位后置低，允许一次写地址握手；BVALID 握手结束后重新开放
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_awready
    if (!S_AXI_ARESETN) begin
        axi_awready <= 1'b0;
        aw_en       <= 1'b1;
    end else begin
        if (!axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awready <= 1'b1;
            aw_en       <= 1'b0;
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end else begin
            axi_awready <= 1'b0;
        end
    end
end

/* ---
 proc_awaddr_latch：写地址锁存
 在 AWREADY 握手成功时锁存 AXI 写地址，供寄存器写译码使用
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_awaddr_latch
    if (!S_AXI_ARESETN) begin
        axi_awaddr <= {C_S_AXI_ADDR_WIDTH{1'b0}};
    end else begin
        if (!axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
            axi_awaddr <= S_AXI_AWADDR;
    end
end

/* ---
 proc_wready：写数据通道 WREADY
 与 AWREADY 同时有效，单拍握手后置低
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_wready
    if (!S_AXI_ARESETN) begin
        axi_wready <= 1'b0;
    end else begin
        if (!axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end
end

/* ---
 proc_reg_write：寄存器写操作 & spi_start 脉冲生成
 根据 axi_awaddr 译码写入对应寄存器。TRIG_REG 在非忙时产生单拍启动脉冲，
 忙时返回 SLVERR。STATUS_REG 支持 W1C 清除（在 proc_status 中处理）。
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_reg_write
    if (!S_AXI_ARESETN) begin
        reg_cpol_cpha   <= 32'd0;
        reg_rw_cmd      <= 32'd0;
        reg_lsb_first   <= 32'd0;
        reg_cs_keep     <= 32'd0;
        reg_cs_sel      <= 32'd0;
        reg_clk_div     <= 32'd1;
        reg_wdata       <= 32'd0;
        reg_total_bits  <= 32'd0;
        reg_tx_bits     <= 32'd0;
        reg_rx_bits     <= 32'd0;
        spi_start_pulse <= 1'b0;
        axi_bresp       <= 2'b00;
    end else begin
        spi_start_pulse <= 1'b0;
        axi_bresp       <= 2'b00;

        if (axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID) begin
            case (axi_awaddr)
                ADDR_CPOL_CPHA_REG : begin
                    if (S_AXI_WSTRB[0]) reg_cpol_cpha[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_cpol_cpha[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_cpol_cpha[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_cpol_cpha[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_RW_CMD_REG : begin
                    if (S_AXI_WSTRB[0]) reg_rw_cmd[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_rw_cmd[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_rw_cmd[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_rw_cmd[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_LSB_FIRST_REG : begin
                    if (S_AXI_WSTRB[0]) reg_lsb_first[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_lsb_first[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_lsb_first[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_lsb_first[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_CS_KEEP_REG : begin
                    if (S_AXI_WSTRB[0]) reg_cs_keep[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_cs_keep[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_cs_keep[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_cs_keep[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_CS_SEL_REG : begin
                    if (S_AXI_WSTRB[0]) reg_cs_sel[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_cs_sel[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_cs_sel[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_cs_sel[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_CLK_DIV_REG : begin
                    if (S_AXI_WSTRB[0]) reg_clk_div[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_clk_div[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_clk_div[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_clk_div[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_WDATA_REG : begin
                    if (S_AXI_WSTRB[0]) reg_wdata[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_wdata[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_wdata[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_wdata[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_TOTAL_BITS_REG : begin
                    if (S_AXI_WSTRB[0]) reg_total_bits[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_total_bits[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_total_bits[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_total_bits[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_TX_BITS_REG : begin
                    if (S_AXI_WSTRB[0]) reg_tx_bits[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_tx_bits[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_tx_bits[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_tx_bits[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_RX_BITS_REG : begin
                    if (S_AXI_WSTRB[0]) reg_rx_bits[ 7: 0] <= S_AXI_WDATA[ 7: 0];
                    if (S_AXI_WSTRB[1]) reg_rx_bits[15: 8] <= S_AXI_WDATA[15: 8];
                    if (S_AXI_WSTRB[2]) reg_rx_bits[23:16] <= S_AXI_WDATA[23:16];
                    if (S_AXI_WSTRB[3]) reg_rx_bits[31:24] <= S_AXI_WDATA[31:24];
                end
                ADDR_STATUS_REG : begin
                    //--- W1C：写1清除 spi_done_flag（在 proc_status 中处理）---
                end
                ADDR_RDATA_REG : begin
                    //--- 只读，写操作忽略 ---
                end
                ADDR_TRIG_REG : begin
                    if (S_AXI_WSTRB[0] && S_AXI_WDATA[0]) begin
                        if (!i_spi_busy) begin
                            spi_start_pulse <= 1'b1;
                            axi_bresp       <= 2'b00;
                        end else begin
                            axi_bresp       <= 2'b10;   //--- SLVERR：SPI busy ---
                        end
                    end
                end
                default : begin end
            endcase
        end
    end
end

/* ---
 proc_rdata_hold：RX 数据快照寄存器
 i_spi_rdata_valid 有效时锁存，PS 在 spi_done 中断后读取
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_rdata_hold
    if (!S_AXI_ARESETN) begin
        reg_rdata_hold <= {C_S_AXI_DATA_WIDTH{1'b0}};
    end else begin
        if (i_spi_rdata_valid)
            reg_rdata_hold <= i_spi_rdata;
    end
end

/* ---
 proc_status：状态寄存器 data_avail_flag & spi_done_flag

 data_avail_flag：
   置位：i_spi_rdata_valid 脉冲时
   清除：PS 读取 RDATA_REG 时自动清零（优先级：Set > Clear）

 spi_done_flag：
   置位：i_spi_done 脉冲时（任意 rw_cmd 模式传输完成均触发）
   清除：PS 写 STATUS_REG [2]=1（W1C）
   优先级：Set > Clear（同拍 done 到来时保持置位）
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_status
    if (!S_AXI_ARESETN) begin
        data_avail_flag <= 1'b0;
        spi_done_flag   <= 1'b0;
    end else begin
        //--- data_avail_flag ---
        if (i_spi_rdata_valid)
            data_avail_flag <= 1'b1;
        else if (axi_rvalid && S_AXI_RREADY && (axi_araddr == ADDR_RDATA_REG))
            data_avail_flag <= 1'b0;

        //--- spi_done_flag ---
        if (i_spi_done)
            spi_done_flag <= 1'b1;
        else if (axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID &&
                 (axi_awaddr == ADDR_STATUS_REG) &&
                 S_AXI_WSTRB[0] && S_AXI_WDATA[2])
            spi_done_flag <= 1'b0;
    end
end

/* ---
 proc_bvalid：写响应通道 BVALID
 写握手成功后置位，BREADY 握手后清除
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_bvalid
    if (!S_AXI_ARESETN) begin
        axi_bvalid <= 1'b0;
    end else begin
        if (axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID && !axi_bvalid)
            axi_bvalid <= 1'b1;
        else if (S_AXI_BREADY && axi_bvalid)
            axi_bvalid <= 1'b0;
    end
end

/* ---
 proc_arready：读地址通道 ARREADY & 锁存读地址
 复位后接收一次读地址握手，RVALID 握手后重新开放
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_arready
    if (!S_AXI_ARESETN) begin
        axi_arready <= 1'b0;
        axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
    end else begin
        if (!axi_arready && S_AXI_ARVALID) begin
            axi_arready <= 1'b1;
            axi_araddr  <= S_AXI_ARADDR;
        end else begin
            axi_arready <= 1'b0;
        end
    end
end

/* ---
 proc_rvalid：读数据通道 RVALID
 ARREADY 握手成功后置位，RREADY 握手后清除
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_rvalid
    if (!S_AXI_ARESETN) begin
        axi_rvalid <= 1'b0;
    end else begin
        if (axi_arready && S_AXI_ARVALID && !axi_rvalid)
            axi_rvalid <= 1'b1;
        else if (axi_rvalid && S_AXI_RREADY)
            axi_rvalid <= 1'b0;
    end
end

/* ---
 proc_rdata：读数据通道 RDATA
 根据 axi_araddr 译码输出对应寄存器的当前值
--- */
always_ff @(posedge S_AXI_ACLK) begin : proc_rdata
    if (!S_AXI_ARESETN) begin
        axi_rdata <= {C_S_AXI_DATA_WIDTH{1'b0}};
    end else begin
        if (axi_arready && S_AXI_ARVALID) begin
            case (axi_araddr)
                ADDR_CPOL_CPHA_REG : axi_rdata <= reg_cpol_cpha                                                         ;
                ADDR_RW_CMD_REG    : axi_rdata <= reg_rw_cmd                                                            ;
                ADDR_LSB_FIRST_REG : axi_rdata <= reg_lsb_first                                                         ;
                ADDR_CS_KEEP_REG   : axi_rdata <= reg_cs_keep                                                           ;
                ADDR_CS_SEL_REG    : axi_rdata <= reg_cs_sel                                                            ;
                ADDR_CLK_DIV_REG   : axi_rdata <= reg_clk_div                                                           ;
                ADDR_WDATA_REG     : axi_rdata <= reg_wdata                                                             ;
                ADDR_TOTAL_BITS_REG: axi_rdata <= reg_total_bits                                                        ;
                ADDR_TX_BITS_REG   : axi_rdata <= reg_tx_bits                                                           ;
                ADDR_RX_BITS_REG   : axi_rdata <= reg_rx_bits                                                           ;
                ADDR_STATUS_REG    : axi_rdata <= {{(C_S_AXI_DATA_WIDTH-3){1'b0}},
                                                      spi_done_flag,                   //--- [2] 传输完成标志 ---
                                                      data_avail_flag,                 //--- [1] 可读数据标志 ---
                                                      i_spi_busy}                      //--- [0] SPI忙 ---
                                                                                       ;
                ADDR_RDATA_REG     : axi_rdata <= reg_rdata_hold                                                     ;
                ADDR_TRIG_REG      : axi_rdata <= {C_S_AXI_DATA_WIDTH{1'b0}}                                        ;
                default            : axi_rdata <= {C_S_AXI_DATA_WIDTH{1'b0}}                                        ;
            endcase
        end
    end
end

endmodule
