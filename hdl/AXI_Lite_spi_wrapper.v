`timescale 1ns / 1ps
/* ---
模块功能：AXI_Lite_spi Verilog封装层

适配场景：Vivado Block Design (BD) 顶层封装
核心目的：BD不识别SystemVerilog语法，需用纯Verilog封装SV编写的AXI_Lite_spi核心模块
          所有接口/参数与核心模块完全透传，无额外逻辑

时钟域说明：
  - 与核心模块保持一致，仅使用 AXI 时钟 S_AXI_ACLK
  - 复位为低有效异步复位 S_AXI_ARESETN

参数说明：
  - C_S_AXI_DATA_WIDTH  —— AXI 数据总线位宽（默认32）
  - C_S_AXI_ADDR_WIDTH  —— AXI 地址总线位宽（默认7，覆盖0x00~0x18）
  - C_CS_WIDTH          —— SPI 片选路数（默认4）
--- */

module AXI_Lite_spi_wrapper #(
    parameter integer                               C_S_AXI_DATA_WIDTH  = 32            ,   //--- AXI 数据总线位宽 ---
    parameter integer                               C_S_AXI_ADDR_WIDTH  = 7             ,   //--- AXI 地址总线位宽（覆盖 0x00~0x18）---
    parameter integer                               C_CS_WIDTH          = 1                 //--- SPI 片选路数 ---
)(
    //--- AXI-Lite 时钟与复位 ---
    input  wire                                     S_AXI_ACLK                          ,   //--- AXI 时钟 ---
    input  wire                                     S_AXI_ARESETN                       ,   //--- AXI 异步低有效复位 ---

    //--- AXI-Lite 写地址通道 ---
    input  wire [C_S_AXI_ADDR_WIDTH - 1 : 0]        S_AXI_AWADDR                        ,
    input  wire [2 : 0]                             S_AXI_AWPROT                        ,
    input  wire                                     S_AXI_AWVALID                       ,
    output wire                                     S_AXI_AWREADY                       ,

    //--- AXI-Lite 写数据通道 ---
    input  wire [C_S_AXI_DATA_WIDTH - 1 : 0]        S_AXI_WDATA                         ,
    input  wire [C_S_AXI_DATA_WIDTH/8 - 1 : 0]      S_AXI_WSTRB                         ,
    input  wire                                     S_AXI_WVALID                        ,
    output wire                                     S_AXI_WREADY                        ,

    //--- AXI-Lite 写响应通道 ---
    output wire [1 : 0]                             S_AXI_BRESP                         ,
    output wire                                     S_AXI_BVALID                        ,
    input  wire                                     S_AXI_BREADY                        ,

    //--- AXI-Lite 读地址通道 ---
    input  wire [C_S_AXI_ADDR_WIDTH - 1 : 0]        S_AXI_ARADDR                        ,
    input  wire [2 : 0]                             S_AXI_ARPROT                        ,
    input  wire                                     S_AXI_ARVALID                       ,
    output wire                                     S_AXI_ARREADY                       ,

    //--- AXI-Lite 读数据通道 ---
    output wire [C_S_AXI_DATA_WIDTH - 1 : 0]        S_AXI_RDATA                         ,
    output wire [1 : 0]                             S_AXI_RRESP                         ,
    output wire                                     S_AXI_RVALID                        ,
    input  wire                                     S_AXI_RREADY                        ,

    //--- 中断输出 ---
    output wire                                      o_intr                             ,   //--- 中断输出至 PS/Microblaze ---

    //--- SPI 物理接口 ---
    output wire                                      o_sclk                             ,   //--- SPI 时钟 ---
    output wire [C_CS_WIDTH - 1 : 0]                 o_cs_n                             ,   //--- 片选（低有效）---
    output wire [C_CS_WIDTH - 1 : 0]                 o_mosi                             ,   //--- 四线制 MOSI 输出 ---
    input  wire [C_CS_WIDTH - 1 : 0]                 i_miso                             ,   //--- 主机输入从机输出 ---
    output wire [C_CS_WIDTH - 1 : 0]                 o_mosi_oe                              //--- MOSI 输出使能（供外部 IOBUF 控制）---
);

// ============================================================
// 例化 AXI_Lite_spi 核心模块
// 所有接口信号一一对应连接，参数透传
// ============================================================
AXI_Lite_spi #(
    .C_S_AXI_DATA_WIDTH ( C_S_AXI_DATA_WIDTH   ),  //--- 透传数据位宽参数 ---
    .C_S_AXI_ADDR_WIDTH ( C_S_AXI_ADDR_WIDTH   ),  //--- 透传地址位宽参数 ---
    .C_CS_WIDTH         ( C_CS_WIDTH           )   //--- 透传 SPI 片选路数参数 ---
) u_AXI_Lite_spi (
    //--- AXI-Lite 时钟与复位 ---
    .S_AXI_ACLK         ( S_AXI_ACLK            ),
    .S_AXI_ARESETN      ( S_AXI_ARESETN         ),

    //--- AXI-Lite 写地址通道 ---
    .S_AXI_AWADDR       ( S_AXI_AWADDR          ),
    .S_AXI_AWPROT       ( S_AXI_AWPROT          ),
    .S_AXI_AWVALID      ( S_AXI_AWVALID         ),
    .S_AXI_AWREADY      ( S_AXI_AWREADY         ),

    //--- AXI-Lite 写数据通道 ---
    .S_AXI_WDATA        ( S_AXI_WDATA           ),
    .S_AXI_WSTRB        ( S_AXI_WSTRB           ),
    .S_AXI_WVALID       ( S_AXI_WVALID          ),
    .S_AXI_WREADY       ( S_AXI_WREADY          ),

    //--- AXI-Lite 写响应通道 ---
    .S_AXI_BRESP        ( S_AXI_BRESP           ),
    .S_AXI_BVALID       ( S_AXI_BVALID          ),
    .S_AXI_BREADY       ( S_AXI_BREADY          ),

    //--- AXI-Lite 读地址通道 ---
    .S_AXI_ARADDR       ( S_AXI_ARADDR          ),
    .S_AXI_ARPROT       ( S_AXI_ARPROT          ),
    .S_AXI_ARVALID      ( S_AXI_ARVALID         ),
    .S_AXI_ARREADY      ( S_AXI_ARREADY         ),

    //--- AXI-Lite 读数据通道 ---
    .S_AXI_RDATA        ( S_AXI_RDATA           ),
    .S_AXI_RRESP        ( S_AXI_RRESP           ),
    .S_AXI_RVALID       ( S_AXI_RVALID          ),
    .S_AXI_RREADY       ( S_AXI_RREADY          ),

    //--- 中断输出 ---
    .o_intr             ( o_intr                ),

    //--- SPI 物理接口 ---
    .o_sclk             ( o_sclk                ),
    .o_cs_n             ( o_cs_n                ),
    .o_mosi             ( o_mosi                ),
    .i_miso             ( i_miso                ),
    .o_mosi_oe          ( o_mosi_oe             )
);

endmodule