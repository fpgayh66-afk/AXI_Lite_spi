`timescale 1ns / 1ps
/* ---
模块功能：AXI_Lite_spi 顶层模块

负责例化并连接以下两个子模块：
  1. AXI_Lite_Slave  —— 解析 AXI4-Lite 协议，提供寄存器配置接口
  2. Spi_Master      —— 执行 SPI 物理时序，驱动 SPI 总线

时钟域说明：
  - AXI_Lite_Slave 使用 AXI 时钟 S_AXI_ACLK
  - Spi_Master     使用同一时钟（单时钟域设计，无需跨时钟处理）
  - AXI_Lite_Slave 复位为低有效异步复位 S_AXI_ARESETN
  - Spi_Master     复位为高有效同步复位，由 ~S_AXI_ARESETN 转换得到
--- */

module AXI_Lite_spi #(
    parameter integer                               C_S_AXI_DATA_WIDTH  = 32        ,   //--- AXI 数据总线位宽 ---
    parameter integer                               C_S_AXI_ADDR_WIDTH  = 7         ,   //--- AXI 地址总线位宽（覆盖 0x00~0x18）---
    parameter integer                               C_CS_WIDTH          = 4             //--- SPI 片选路数 ---
)(
    //--- AXI-Lite 时钟与复位 ---
    input  logic                                    S_AXI_ACLK                          ,   //--- AXI 时钟 ---
    input  logic                                    S_AXI_ARESETN                       ,   //--- AXI 异步低有效复位 ---

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

    //--- 中断输出 ---
    output logic                                    o_intr                              ,   //--- 中断输出至 PS/Microblaze ---

    //--- SPI 物理接口 ---
    output logic                                    o_sclk                              ,   //--- SPI 时钟 ---
    output logic [C_CS_WIDTH - 1 : 0]               o_cs_n                              ,   //--- 片选（低有效）---
    output logic [C_CS_WIDTH - 1 : 0]               o_mosi                              ,   //--- 四线制 MOSI 输出 ---
    input  logic [C_CS_WIDTH - 1 : 0]               i_miso                              ,   //--- 主机输入从机输出 ---
    output logic [C_CS_WIDTH - 1 : 0]               o_mosi_oe                               //--- MOSI 输出使能（供外部 IOBUF 控制）---
);

// ============================================================
// 复位转换
// AXI_Lite_Slave 使用低有效异步复位 S_AXI_ARESETN
// Spi_Master     使用高有效同步复位，由此转换得到
// ============================================================
logic                                               spi_rst                             ;

assign spi_rst = ~S_AXI_ARESETN;

// ============================================================
// AXI_Lite_Slave → Spi_Master 内部连线
// ============================================================

//--- 配置信号 ---
logic [15:0]                                        w_spi_clk_div                       ;
logic                                               w_spi_cpol                          ;
logic                                               w_spi_cpha                          ;
logic [1 : 0]                                       w_spi_rw_cmd                        ;
logic                                               w_spi_lsb_first                     ;
logic [31:0]                                        w_spi_cs_sel                        ;
logic                                               w_spi_cs_keep                       ;

//--- 数据路径 ---
logic [C_S_AXI_DATA_WIDTH - 1 : 0]                  w_spi_wdata                         ;
logic [C_S_AXI_DATA_WIDTH - 1 : 0]                  w_spi_rdata                         ;

//--- 控制与状态 ---
logic                                               w_spi_start                         ;
logic                                               w_spi_busy                          ;
logic                                               w_spi_done                          ;

//--- 增强配置 ---
logic [5 : 0]                                       w_spi_total_bits                    ;
logic [5 : 0]                                       w_spi_tx_bits                       ;
logic [5 : 0]                                       w_spi_rx_bits                       ;

logic                                               w_spi_rdata_valid                   ;

// ============================================================
// 子模块例化
// ============================================================

//--- AXI_Lite_Slave 例化 ---
AXI_Lite_Slave #(
    .C_S_AXI_DATA_WIDTH ( C_S_AXI_DATA_WIDTH   ),
    .C_S_AXI_ADDR_WIDTH ( C_S_AXI_ADDR_WIDTH   )
) u_AXI_Lite_Slave (
    //--- 时钟与复位 ---
    .S_AXI_ACLK         ( S_AXI_ACLK            ),
    .S_AXI_ARESETN      ( S_AXI_ARESETN         ),
    //--- 写地址通道 ---
    .S_AXI_AWADDR       ( S_AXI_AWADDR          ),
    .S_AXI_AWPROT       ( S_AXI_AWPROT          ),
    .S_AXI_AWVALID      ( S_AXI_AWVALID         ),
    .S_AXI_AWREADY      ( S_AXI_AWREADY         ),
    //--- 写数据通道 ---
    .S_AXI_WDATA        ( S_AXI_WDATA           ),
    .S_AXI_WSTRB        ( S_AXI_WSTRB           ),
    .S_AXI_WVALID       ( S_AXI_WVALID          ),
    .S_AXI_WREADY       ( S_AXI_WREADY          ),
    //--- 写响应通道 ---
    .S_AXI_BRESP        ( S_AXI_BRESP           ),
    .S_AXI_BVALID       ( S_AXI_BVALID          ),
    .S_AXI_BREADY       ( S_AXI_BREADY          ),
    //--- 读地址通道 ---
    .S_AXI_ARADDR       ( S_AXI_ARADDR          ),
    .S_AXI_ARPROT       ( S_AXI_ARPROT          ),
    .S_AXI_ARVALID      ( S_AXI_ARVALID         ),
    .S_AXI_ARREADY      ( S_AXI_ARREADY         ),
    //--- 读数据通道 ---
    .S_AXI_RDATA        ( S_AXI_RDATA           ),
    .S_AXI_RRESP        ( S_AXI_RRESP           ),
    .S_AXI_RVALID       ( S_AXI_RVALID          ),
    .S_AXI_RREADY       ( S_AXI_RREADY          ),
    //--- 配置输出 ---
    .o_spi_clk_div      ( w_spi_clk_div         ),
    .o_spi_cpol         ( w_spi_cpol            ),
    .o_spi_cpha         ( w_spi_cpha            ),
    .o_spi_rw_cmd       ( w_spi_rw_cmd          ),
    .o_spi_lsb_first    ( w_spi_lsb_first       ),
    .o_spi_cs_sel       ( w_spi_cs_sel          ),
    .o_spi_cs_keep      ( w_spi_cs_keep         ),
    //--- 数据路径 ---
    .o_spi_wdata        ( w_spi_wdata           ),
    .i_spi_rdata        ( w_spi_rdata           ),
    .i_spi_rdata_valid  (w_spi_rdata_valid      ),
    //--- 控制与状态 ---
    .o_spi_start        ( w_spi_start           ),
    .i_spi_busy         ( w_spi_busy            ),
    .i_spi_done         ( w_spi_done            ),
    .o_intr             ( o_intr                ),
    //--- 增强配置 ---
    .o_spi_total_bits   ( w_spi_total_bits      ),
    .o_spi_tx_bits      ( w_spi_tx_bits         ),
    .o_spi_rx_bits      ( w_spi_rx_bits         )
);

//--- Spi_Master 例化 ---
Spi_Master #(
    .C_DATA_WIDTH       ( C_S_AXI_DATA_WIDTH    ),
    .C_CS_WIDTH         ( C_CS_WIDTH            )
) u_Spi_Master (
    //--- 时钟与复位 ---
    .i_clk              ( S_AXI_ACLK            ),
    .i_rst              ( spi_rst               ),  //--- 高有效同步复位 ---
    //--- 配置接口 ---
    .i_spi_clk_div      ( w_spi_clk_div         ),
    .i_spi_cpol         ( w_spi_cpol            ),
    .i_spi_cpha         ( w_spi_cpha            ),
    .i_spi_rw_cmd       ( w_spi_rw_cmd          ),
    .i_spi_lsb_first    ( w_spi_lsb_first       ),
    .i_spi_cs_sel       ( w_spi_cs_sel          ),
    .i_spi_cs_keep      ( w_spi_cs_keep         ),
    //--- 增强配置 ---
    .i_spi_total_bits   ( w_spi_total_bits      ),
    .i_spi_tx_bits      ( w_spi_tx_bits         ),
    .i_spi_rx_bits      ( w_spi_rx_bits         ),
    //--- 数据路径 ---
    .i_spi_wdata        ( w_spi_wdata           ),
    .o_spi_rdata        ( w_spi_rdata           ),
    .o_spi_rdata_valid  (w_spi_rdata_valid      ),
    //--- 控制与状态 ---
    .i_spi_start        ( w_spi_start           ),
    .o_spi_busy         ( w_spi_busy            ),
    .o_spi_done         ( w_spi_done            ),
    //--- SPI 物理接口 ---
    .o_sclk             ( o_sclk                ),
    .o_cs_n             ( o_cs_n                ),
    .o_mosi             ( o_mosi                ),
    .i_miso             ( i_miso                ),
    .o_mosi_oe          ( o_mosi_oe             )
);

endmodule