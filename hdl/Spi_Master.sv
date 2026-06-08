`timescale 1ns / 1ps
/* ---
模块功能：SPI Master 协议控制模块

支持特性：
  - 四线制（MOSI/MISO 分离 + SCLK + CS）/ 三线制（SDIO 双向 + SCLK + CS）
  - CPOL / CPHA 四种模式可配置
  - MSB First / LSB First 可选
  - 传输位宽可配置（8 / 16 / 24 / 32 bit，或自定义 total_bits）
  - rw_cmd 动态控制模式：
      00=仅写  01=仅读  10=写后读(半双工)  11=同时读写(全双工)
  - 自动片选控制（cs_keep 模式下传输结束后保持 CS 拉低）
  - 支持多从机片选（cs_sel 1-hot 编码，最多4路）
  - 传输结束产生 done 脉冲，busy 指示传输进行中

与 AXI_Lite_Slave 的接口约定：
  - 配置信号在 o_spi_start 脉冲到来前已稳定（由 TRIG_REG 最后写入保证）
  - o_spi_start 为单拍脉冲，触发一次完整的 SPI 传输
  - i_spi_busy 拉高期间，AXI 侧再次写入 TRIG_REG 不产生效果（由上层保证）
  - 传输完成后 i_spi_done 产生单拍脉冲，AXI 侧读取 RDATA_REG 获取接收数据
  - o_spi_rdata 在 done 脉冲后保持有效，直到下一次 spi_start
--- */

module Spi_Master #(
    parameter integer                   C_DATA_WIDTH        = 32    ,      //--- 最大数据位宽（与 AXI 数据总线等宽） ---
    parameter integer                   C_CS_WIDTH          = 4            //--- 片选路数 ---
)(
    //--- 系统时钟与复位 ---
    input  logic                        i_clk                       ,      //--- 系统时钟（与 AXI_Lite_Slave 同源） ---
    input  logic                        i_rst                       ,      //--- 同步高电平复位 ---

    //--- 配置接口（来自 AXI_Lite_Slave，在 spi_start 前已稳定） ---
    input  logic [15 : 0]               i_spi_clk_div               ,      //--- 时钟分频系数（f_sclk = f_clk / (2*(div+1))） ---
    input  logic                        i_spi_cpol                  ,      //--- SPI 极性：0-空闲低，1-空闲高 ---
    input  logic                        i_spi_cpha                  ,      //--- SPI 相位：0-第一沿采样，1-第二沿采样 ---
    input  logic [1 : 0]                i_spi_rw_cmd                ,      //--- 读写方向：00-仅写，01-仅读，10-写后读 ,11-边读边写 ---
    input  logic                        i_spi_lsb_first             ,      //--- 位序：0-MSB First，1-LSB First ---
    input  logic [31 : 0]               i_spi_cs_sel                ,      //--- 片选（1-hot 编码，32bit） ---
    input  logic                        i_spi_cs_keep               ,      //--- 1-传输结束后保持 CS 拉低，0-传输结束拉高 CS ---

    //--- 增强配置（精确位数控制） ---
    input  logic [5 : 0]                i_spi_total_bits            ,      //--- 本次传输总比特数，控制 bit_cnt 截止（TX+RX 总和） ---
    input  logic [5 : 0]                i_spi_tx_bits               ,      //--- 仅写阶段比特数，之后切换为接收（rw_cmd=10 时有效） ---
    input  logic [5 : 0]                i_spi_rx_bits               ,      //--- 接收阶段对齐位数，控制 rx_align 宽度（显式配置） ---

    //--- 数据接口（来自 AXI_Lite_Slave） ---
    input  logic [C_DATA_WIDTH - 1 : 0] i_spi_wdata                 ,      //--- 待发送数据（MSB/LSB 由 lsb_first 决定移位方向） ---
    output logic [C_DATA_WIDTH - 1 : 0] o_spi_rdata                 ,      //--- 接收数据（done 后有效，保持至下次 start） ---
    output logic                        o_spi_rdata_valid           ,      //--- 接收数据有效脉冲（单拍） ---

    //--- 控制与状态接口（来自/至 AXI_Lite_Slave） ---
    input  logic                        i_spi_start                 ,      //--- 启动脉冲（单拍，由 TRIG_REG 写操作产生） ---
    output logic                        o_spi_busy                  ,      //--- 忙标志：传输期间拉高 ---
    output logic                        o_spi_done                  ,      //--- 完成脉冲：传输结束单拍拉高 ---

    //--- SPI 物理接口 ---
    output logic                        o_sclk                      ,      //--- SPI 时钟 ---
    output logic [C_CS_WIDTH - 1 : 0]   o_cs_n                      ,      //--- 片选（低有效，1-hot 取反） ---
    output logic [C_CS_WIDTH - 1 : 0]   o_mosi                      ,      //--- MOSI 输出数据 ---
    input  logic [C_CS_WIDTH - 1 : 0]   i_miso                      ,      //--- MISO 输入数据 ---
    output logic [C_CS_WIDTH - 1 : 0]   o_mosi_oe                          //--- MOSI 输出使能（1=驱动，供外部 IOBUF 控制） ---
);

//--- 状态机定义 ---
typedef enum logic [7:0] {
    ST_IDLE     = 8'b00000001,      //--- 空闲状态 ---
    ST_CFG_LOAD = 8'b00000010,      //--- 配置加载状态 ---
    ST_CS_SETUP = 8'b00000100,      //--- CS 建立阶段 ---
    ST_TX       = 8'b00001000,      //--- 仅写阶段（半双工 TX） ---
    ST_RX       = 8'b00010000,      //--- 仅读阶段（半双工 RX） ---
    ST_TX_RX    = 8'b00100000,      //--- 全双工阶段（同时 TX+RX） ---
    ST_CS_HOLD  = 8'b01000000,      //--- CS 保持阶段 ---
    ST_DONE     = 8'b10000000       //--- 传输完成 ---
} spi_state_e;

spi_state_e                         current_state                           ;
spi_state_e                         next_state                              ;

//--- 锁存相关配置信息（在 ST_IDLE 且 i_spi_start 时锁存，保证传输期间配置稳定） ---
logic [15 : 0]                      latch_spi_clk_div                       ;
logic                               latch_spi_cpol                          ;
logic                               latch_spi_cpha                          ;
logic [1 : 0]                       latch_spi_rw_cmd                        ;
logic                               latch_spi_lsb_first                     ;
logic [31 : 0]                      latch_spi_cs_sel                        ;
logic                               latch_spi_cs_keep                       ;
logic [5 : 0]                       latch_spi_total_bits                    ;
logic [5 : 0]                       latch_spi_tx_bits                       ;
logic [5 : 0]                       latch_spi_rx_bits                       ;
logic [C_DATA_WIDTH - 1 : 0]        latch_spi_wdata                         ;

//--- TX/RX 数据路径寄存器 ---
logic [C_DATA_WIDTH - 1 : 0]        tx_load_msb = 0                         ;      //--- TX 并行加载（MSB 对齐） ---
logic [C_DATA_WIDTH - 1 : 0]        tx_load_lsb = 0                         ;      //--- TX 并行加载（LSB 对齐） ---
logic [C_DATA_WIDTH - 1 : 0]        rx_load_msb = 0                         ;      //--- RX 并行输出（MSB 对齐） ---
logic [C_DATA_WIDTH - 1 : 0]        rx_load_lsb = 0                         ;      //--- RX 并行输出（LSB 对齐） ---
logic [C_DATA_WIDTH - 1 : 0]        tx_shift    = 0                         ;      //--- TX 移位寄存器 ---
logic [C_DATA_WIDTH - 1 : 0]        rx_shift    = 0                         ;      //--- RX 移位寄存器 ---

//--- 内部时序控制信号 ---
logic [15 : 0]                      clk_div_cnt                             ;      //--- 时钟分频计数器 ---
logic                               sclk_int                                ;      //--- 内部 SCLK（分频后） ---
logic                               sclk_int_d1                             ;      //--- sclk_int 打一拍，用于边沿检测 ---
logic [5 : 0]                       bit_cnt                                 ;      //--- 已完成比特计数 ---
logic                               first_sampled_flag                      ;      //--- 首次采样标志（区分首次和后续边沿） ---
logic                               miso_sel                                ;      //--- MISO 选中位（根据 cs_sel 从多路中选取） ---

//--- SCLK 边沿检测 ---
wire sclk_edge = clk_div_cnt == latch_spi_clk_div                           ;      //--- SCLK 翻转使能（分频计数器命中） ---
wire sclk_rise = ( sclk_int && !sclk_int_d1)                                ;      //--- SCLK 上升沿 ---
wire sclk_fall = (!sclk_int &&  sclk_int_d1)                                ;      //--- SCLK 下降沿 ---

//--- 状态转移条件（组合逻辑） ---
wire \ST_IDLE->ST_CFG_LOAD          = i_spi_start;
wire \ST_CS_SETUP->ST_RX            = (latch_spi_rw_cmd == 2'b01);
wire \ST_CS_SETUP->ST_TX            = (latch_spi_rw_cmd == 2'b00) || (latch_spi_rw_cmd == 2'b10);
wire \ST_TX->ST_RX                  = (((bit_cnt == latch_spi_tx_bits - 1) && (latch_spi_rw_cmd == 2'b10)) && (latch_spi_cpol ? (latch_spi_cpha ? (first_sampled_flag && sclk_fall) : (first_sampled_flag && sclk_rise)) : (latch_spi_cpha ? first_sampled_flag && sclk_rise : first_sampled_flag && sclk_fall)));      //--- TX→RX：写后读模式，tx_bits 发完 ---
wire \ST_TX->ST_CS_HOLD             = (((bit_cnt == latch_spi_tx_bits - 1) && (latch_spi_rw_cmd == 2'b00)) && (latch_spi_cpol ? (latch_spi_cpha ? (first_sampled_flag && sclk_fall) : (first_sampled_flag && sclk_rise)) : (latch_spi_cpha ? first_sampled_flag && sclk_rise : first_sampled_flag && sclk_fall)));      //--- TX→CS保持：仅写模式结束 ---
wire \ST_CS_SETUP->ST_TX_RX         = (latch_spi_rw_cmd == 2'b11);
wire \ST_TX_RX->ST_CS_HOLD          = (bit_cnt == (latch_spi_total_bits - 1) && (latch_spi_cpol ? (latch_spi_cpha ? (first_sampled_flag && sclk_fall) : (first_sampled_flag && sclk_rise)) : (latch_spi_cpha ? first_sampled_flag && sclk_rise : first_sampled_flag && sclk_fall)));      //--- 全双工→CS保持：total_bits 发完 ---
wire \ST_RX->ST_CS_HOLD             = (bit_cnt == (latch_spi_total_bits - 1) && (latch_spi_cpol ? (latch_spi_cpha ? (first_sampled_flag && sclk_fall) : (first_sampled_flag && sclk_rise)) : (latch_spi_cpha ? first_sampled_flag && sclk_rise : first_sampled_flag && sclk_fall)));      //--- 仅读→CS保持：total_bits 收完 ---
wire \ST_CS_HOLD->ST_DONE           = latch_spi_cpha ? 1'b1 : (!sclk_int_d1 && sclk_edge);

//--- 输出组合逻辑 ---
assign o_spi_busy                   = (current_state != ST_IDLE);
assign o_sclk                       = current_state inside{ST_RX,ST_TX,ST_TX_RX} ? sclk_int_d1 : latch_spi_cpol ? 1'b1 : 1'b0;
assign o_mosi_oe                    = latch_spi_cs_sel[C_CS_WIDTH-1:0] & {C_CS_WIDTH{(latch_spi_rw_cmd == 2'b00 || latch_spi_rw_cmd == 2'b11) && current_state inside{ST_CS_SETUP,ST_TX,ST_TX_RX,ST_CS_HOLD} || (latch_spi_rw_cmd == 2'b10) && current_state inside{ST_CS_SETUP,ST_TX} && (current_state != ST_RX || bit_cnt <= latch_spi_tx_bits - 1)}};      //--- MOSI OE：仅选中片选通道输出使能 ---
assign o_mosi                       = o_mosi_oe & {C_CS_WIDTH{tx_shift[C_DATA_WIDTH - 1]}};

/* ---
 proc_latch_configration：配置锁存
 ST_IDLE 状态收到 spi_start 脉冲时锁存所有配置输入，保证整个传输期间配置稳定
--- */
always_ff @(posedge i_clk) begin : proc_latch_configration
    if (current_state == ST_IDLE && i_spi_start) begin
        latch_spi_clk_div    <= i_spi_clk_div   ;
        latch_spi_cpol       <= i_spi_cpol      ;
        latch_spi_cpha       <= i_spi_cpha      ;
        latch_spi_rw_cmd     <= i_spi_rw_cmd    ;
        latch_spi_lsb_first  <= i_spi_lsb_first ;
        latch_spi_cs_sel     <= i_spi_cs_sel    ;
        latch_spi_cs_keep    <= i_spi_cs_keep   ;
        latch_spi_total_bits <= i_spi_total_bits;
        latch_spi_tx_bits    <= i_spi_tx_bits   ;
        latch_spi_rx_bits    <= i_spi_rx_bits   ;
        latch_spi_wdata      <= i_spi_wdata     ;
    end
end

/* ---
proc_tx_align：TX 数据位宽对齐
根据 tx_bits 将 wdata 加载到 MSB/LSB 对齐寄存器；MSB 靠左，LSB 位反转靠右
--- */
always_ff @(posedge i_clk) begin : proc_tx_align
    integer i;
    if (current_state inside{ST_CFG_LOAD,ST_CS_SETUP}) begin
        case (latch_spi_tx_bits)
            6'd8    : begin
                tx_load_msb[C_DATA_WIDTH-1 -: 8] <= latch_spi_wdata[7:0];
                for (i = 0; i < 8; i++) tx_load_lsb[C_DATA_WIDTH-1 - i] <= latch_spi_wdata[i];
            end
            6'd16   : begin
                tx_load_msb[C_DATA_WIDTH-1 -: 16] <= latch_spi_wdata[15:0];
                for (i = 0; i < 16; i++) tx_load_lsb[C_DATA_WIDTH-1 - i] <= latch_spi_wdata[i];
            end
            6'd24   : begin
                tx_load_msb[C_DATA_WIDTH-1 -: 24] <= latch_spi_wdata[23:0];
                for (i = 0; i < 24; i++) tx_load_lsb[C_DATA_WIDTH-1 - i] <= latch_spi_wdata[i];
            end
            6'd32   : begin
                tx_load_msb                       <= latch_spi_wdata;
                for (i = 0; i < 32; i++) tx_load_lsb[C_DATA_WIDTH-1 - i] <= latch_spi_wdata[i];
            end
            default : begin
                tx_load_msb[C_DATA_WIDTH-1 -: 8] <= latch_spi_wdata[7:0];
                for (i = 0; i < 8; i++) tx_load_lsb[C_DATA_WIDTH-1 - i] <= latch_spi_wdata[i];
            end
        endcase
    end
end

/* ---
 proc_clk_div：SCLK 分频计数器
 数据传输期间自增，计数值达到 latch_spi_clk_div 时归零，产生 sclk_edge 翻转 SCLK
--- */
always_ff @(posedge i_clk) begin : proc_clk_div
    if (current_state inside{ST_IDLE,ST_CFG_LOAD,ST_DONE,ST_CS_SETUP}) begin
        clk_div_cnt <= 16'd0;
    end else begin
        if (clk_div_cnt == latch_spi_clk_div) begin
            clk_div_cnt <= 16'd0;
        end else begin
            clk_div_cnt <= clk_div_cnt + 1'b1;
        end
    end
end

/* ---
 proc_sclk_int：内部 SCLK 生成
 空闲时保持 CPOL 电平，传输期间在 sclk_edge 时翻转，仅写模式结束时强制拉回 CPOL
--- */
always_ff @(posedge i_clk) begin : proc_sclk_int
    if (((current_state == ST_TX && (\ST_TX->ST_CS_HOLD ))) && latch_spi_cpol ) begin
        sclk_int <= 1'b1;
    end else if (current_state inside{ST_DONE} || (current_state == ST_CS_HOLD && (next_state == ST_DONE))) begin
        if (i_spi_cpol) begin
            sclk_int <= 1'b1;
        end else begin
            sclk_int <= 1'b0;
        end
    end else if (current_state == ST_IDLE) begin
        if (i_spi_cpol) begin
            sclk_int <= 1'b1;
        end else begin
            sclk_int <= 1'b0;
        end
    end else if (current_state inside{ST_TX,ST_RX,ST_TX_RX,ST_CS_HOLD}) begin
        if (sclk_edge) begin
            sclk_int <= !sclk_int;
        end
    end
end

//--- proc_sclk_int_delay：SCLK 延迟一拍，用于边沿检测 ---
always_ff @(posedge i_clk) begin : proc_sclk_int_delay
    sclk_int_d1 <= sclk_int;
end

//--- proc_current_state：状态寄存器 ---
always_ff @(posedge i_clk) begin : proc_current_state
    if (i_rst) begin
        current_state <= ST_IDLE;
    end else begin
        current_state <= next_state;
    end
end

//--- comb_next_state：下一状态组合逻辑 ---
always_comb begin : comb_next_state
    next_state = current_state;
    case (current_state)
        ST_IDLE     : next_state = (\ST_IDLE->ST_CFG_LOAD   ) ? ST_CFG_LOAD : ST_IDLE                                                 ;
        ST_CFG_LOAD : next_state = ST_CS_SETUP                                                                                        ;
        ST_CS_SETUP : next_state = (\ST_CS_SETUP->ST_RX     ) ? ST_RX       :
                                    (\ST_CS_SETUP->ST_TX    ) ? ST_TX       :
                                    (\ST_CS_SETUP->ST_TX_RX ) ? ST_TX_RX    : ST_CS_SETUP                                             ;
        ST_TX       : next_state = (\ST_TX->ST_RX           ) ? ST_RX       : (\ST_TX->ST_CS_HOLD  )   ? ST_CS_HOLD  : ST_TX          ;
        ST_RX       : next_state = (\ST_RX->ST_CS_HOLD      ) ? ST_CS_HOLD  : ST_RX                                                   ;
        ST_TX_RX    : next_state = (\ST_TX_RX->ST_CS_HOLD   ) ? ST_CS_HOLD  : ST_TX_RX                                                ;
        ST_CS_HOLD  : next_state = (\ST_CS_HOLD->ST_DONE    ) ? ST_DONE     : ST_CS_HOLD                                              ;
        ST_DONE     : next_state = ST_IDLE;
        default     : next_state = ST_IDLE;
    endcase
end

/* ---
 proc_bit_cnt：比特计数器
 数据传输期间每次采样/驱动边沿后自增，边沿取决于 CPOL/CPHA
 CPOL^CPHA=0 → sclk_rise（模式0/2），CPOL^CPHA=1 → sclk_fall（模式1/3）
--- */
always_ff @(posedge i_clk) begin : proc_bit_cnt
    if (!(current_state inside{ST_TX,ST_RX,ST_TX_RX,ST_CS_SETUP})) begin
        bit_cnt  <= 6'd0;
    end else if (current_state == ST_CS_SETUP) begin
        bit_cnt  <= 6'd0;
    end else begin
        if(bit_cnt == latch_spi_total_bits - 1) begin
            bit_cnt <= bit_cnt;
        end else begin
            if (latch_spi_cpol) begin
                if (latch_spi_cpha) begin
                    if (first_sampled_flag && sclk_fall)
                        bit_cnt  <= bit_cnt + 1'b1;
                end else begin
                    if (first_sampled_flag && sclk_rise)
                        bit_cnt  <= bit_cnt + 1'b1;
                end
            end else begin
                if (latch_spi_cpha) begin
                    if (first_sampled_flag && sclk_rise)
                        bit_cnt  <= bit_cnt + 1'b1;
                end else begin
                    if (first_sampled_flag && sclk_fall)
                        bit_cnt  <= bit_cnt + 1'b1;
                end
            end
        end
    end
end

/* ---
 proc_first_sampled_flag：首次采样标志
 数据传输阶段第一个数据边沿到来时置位，用于 bit_cnt/tx_shift 区分首边沿
 CPOL^CPHA=0 → sclk_rise（模式0/2），CPOL^CPHA=1 → sclk_fall（模式1/3）
--- */
always_ff @(posedge i_clk) begin : proc_first_sampled_flag
    if (!(current_state inside{ST_TX,ST_RX,ST_TX_RX})) begin
        first_sampled_flag <= 1'b0;
    end else begin
        if (latch_spi_cpol ^ latch_spi_cpha) begin
            if (sclk_fall)
                first_sampled_flag <= 1'b1;
        end else begin
            if (sclk_rise)
                first_sampled_flag <= 1'b1;
        end
    end
end

/* ---
 proc_output_cs_n：片选输出
 CS_SETUP 阶段拉低选中从机，传输结束后根据 cs_keep 保持或拉高
--- */
always_ff @(posedge i_clk) begin : proc_output_cs_n
    if (i_rst) begin
        o_cs_n <= {C_CS_WIDTH{1'b1}};
    end else if ((!o_cs_n && current_state == ST_CS_HOLD && (\ST_CS_HOLD->ST_DONE )) || current_state == ST_DONE) begin
        if (latch_spi_cs_keep) begin
            o_cs_n <= ~latch_spi_cs_sel[C_CS_WIDTH-1:0];
        end else begin
            o_cs_n <= {C_CS_WIDTH{1'b1}};
        end
    end else if (current_state inside{ST_CS_SETUP,ST_TX,ST_RX,ST_TX_RX}) begin
        o_cs_n <= ~latch_spi_cs_sel[C_CS_WIDTH-1:0];
    end else if (current_state == ST_IDLE && !latch_spi_cs_keep) begin
        o_cs_n <= {C_CS_WIDTH{1'b1}};
    end
end

/* ---
 proc_tx_shift：TX 移位寄存器
 CS_SETUP 时加载初始值，传输阶段在数据边沿左移（高位出，低位补0）
 CPOL^CPHA=0 → sclk_rise 移位（模式0/2），CPOL^CPHA=1 → sclk_fall 移位（模式1/3）
--- */
always_ff @(posedge i_clk) begin : proc_tx_shift
    if (current_state == ST_CS_SETUP) begin
        if (latch_spi_lsb_first) begin
            tx_shift <= tx_load_lsb;
        end else begin
            tx_shift <= tx_load_msb;
        end
    end else if (current_state inside{ST_TX,ST_TX_RX,ST_RX,ST_CS_HOLD}) begin
        if (latch_spi_cpol) begin
            if (latch_spi_cpha) begin
                if (first_sampled_flag && sclk_fall)
                    tx_shift <= {tx_shift[C_DATA_WIDTH-2 : 0],1'b0};
            end else begin
                if (first_sampled_flag && sclk_rise)
                    tx_shift <= {tx_shift[C_DATA_WIDTH-2 : 0],1'b0};
            end
        end else begin
            if (latch_spi_cpha) begin
                if (first_sampled_flag && sclk_rise)
                    tx_shift <= {tx_shift[C_DATA_WIDTH-2 : 0],1'b0};
            end else begin
                if (first_sampled_flag && sclk_fall)
                    tx_shift <= {tx_shift[C_DATA_WIDTH-2 : 0],1'b0};
            end
        end
    end else begin
        tx_shift <= {C_DATA_WIDTH{1'b0}};
    end
end

/* ---
 comb_miso_sel：MISO 位选取
 根据 latch_spi_cs_sel（1-hot）从多路 i_miso 中选取当前从机的输入位
--- */
always_comb begin : comb_miso_sel
    miso_sel = 1'b0;
    for (int i = 0; i < C_CS_WIDTH; i++) begin
        if (latch_spi_cs_sel[i])
            miso_sel = i_miso[i];
    end
end

/* ---
 proc_rx_shift：RX 移位寄存器
 接收阶段在采样边沿左移并锁存 miso_sel，非接收模式时清零
 CPOL^CPHA=0 → sclk_fall 采样（模式0/2），CPOL^CPHA=1 → sclk_rise 采样（模式1/3）
--- */
always_ff @(posedge i_clk) begin : proc_rx_shift
    if ((!(current_state inside{ST_RX,ST_TX_RX,ST_CS_HOLD,ST_DONE})) || (latch_spi_rw_cmd != 2'b01 && latch_spi_rw_cmd != 2'b10 && latch_spi_rw_cmd != 2'b11)) begin
        rx_shift <= {C_DATA_WIDTH{1'b0}};
    end else if (current_state inside{ST_RX,ST_TX_RX}) begin
        if (latch_spi_rw_cmd == 2'b01 || latch_spi_rw_cmd == 2'b11 || (bit_cnt > latch_spi_tx_bits - 1)) begin
            if (latch_spi_cpol) begin
                if (latch_spi_cpha) begin
                    if (sclk_rise)
                        rx_shift <= {rx_shift[C_DATA_WIDTH - 2 : 0], miso_sel};
                end else begin
                    if (sclk_fall)
                        rx_shift <= {rx_shift[C_DATA_WIDTH - 2 : 0], miso_sel};
                end
            end else begin
                if (latch_spi_cpha) begin
                    if (sclk_fall)
                        rx_shift <= {rx_shift[C_DATA_WIDTH - 2 : 0], miso_sel};
                end else begin
                    if (sclk_rise)
                        rx_shift <= {rx_shift[C_DATA_WIDTH - 2 : 0], miso_sel};
                end
            end
        end
    end
end

/* ---
 proc_rx_align：RX 数据位宽对齐
 ST_CS_HOLD 阶段根据 rx_bits 将 rx_shift 对齐到 MSB/LSB 格式输出
--- */
always_ff @(posedge i_clk) begin : proc_rx_align
    integer k;
    if (current_state == ST_CS_HOLD) begin
        case (latch_spi_rx_bits)
            6'd8    : begin
                rx_load_msb <= {{(C_DATA_WIDTH - 8){1'b0}}, rx_shift[7:0]};
                for (k = 0; k < 8; k++) rx_load_lsb[k] <= rx_shift[7 - k];
            end
            6'd16   : begin
                rx_load_msb <= {{(C_DATA_WIDTH - 16){1'b0}}, rx_shift[15:0]};
                for (k = 0; k < 16; k++) rx_load_lsb[k] <= rx_shift[15 - k];
            end
            6'd24   : begin
                rx_load_msb <= {{(C_DATA_WIDTH - 24){1'b0}}, rx_shift[23:0]};
                for (k = 0; k < 24; k++) rx_load_lsb[k] <= rx_shift[23 - k];
            end
            6'd32   : begin
                rx_load_msb <= rx_shift;
                for (k = 0; k < 32; k++) rx_load_lsb[k] <= rx_shift[31 - k];
            end
            default : begin
                rx_load_msb <= {{(C_DATA_WIDTH - 8){1'b0}}, rx_shift[7:0]};
                for (k = 0; k < 8; k++) rx_load_lsb[k] <= rx_shift[7 - k];
            end
        endcase
    end
end

/* ---
 proc_output_rdata：接收数据输出
 ST_DONE 阶段根据 lsb_first 输出 MSB/LSB 对齐结果，产生 o_spi_rdata_valid 脉冲
 仅读/半双工/全双工有效，仅写模式不输出
--- */
always_ff @(posedge i_clk) begin : proc_output_rdata
    if (i_rst || (current_state == ST_IDLE)) begin
        o_spi_rdata       <= {C_DATA_WIDTH{1'b0}};
        o_spi_rdata_valid <= 1'b0;
    end else if (current_state == ST_DONE && (latch_spi_rw_cmd == 2'b01 || latch_spi_rw_cmd == 2'b10 || latch_spi_rw_cmd == 2'b11)) begin
        if (latch_spi_lsb_first) begin
            o_spi_rdata       <= rx_load_lsb;
            o_spi_rdata_valid <= 1'b1;
        end else begin
            o_spi_rdata       <= rx_load_msb;
            o_spi_rdata_valid <= 1'b1;
        end
    end
end

/* ---
 proc_o_spi_done：传输完成脉冲
 ST_DONE 状态时拉高 o_spi_done（单拍）
--- */
always_ff @(posedge i_clk) begin : proc_o_spi_done
    o_spi_done <= (current_state == ST_DONE);
end

endmodule
