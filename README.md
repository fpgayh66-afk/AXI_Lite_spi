# AXI_Lite_SPI — 基于 AXI4-Lite 的可配置 SPI Master 控制器

## 概述

本项目实现了一个基于 **AXI4-Lite** 总线接口的高度可配置 **SPI Master** 控制器，面向 Xilinx 7系列/UltraScale/UltraScale+ FPGA 及 SoC（Zynq/MicroBlaze）平台。

处理器（PS/软核）通过 AXI4-Lite 总线读写寄存器即可完成 SPI 配置与数据收发，无需手动控制 SPI 时序。

## 功能特性

| 特性 | 说明 |
|------|------|
| **总线接口** | AXI4-Lite (32-bit 数据, 7-bit 地址) |
| **SPI 模式** | Mode 0/1/2/3 全部支持（CPOL/CPHA 可配置） |
| **通信模式** | 仅写 / 仅读 / 半双工（写后读）/ 全双工 |
| **位序** | MSB First / LSB First 可选 |
| **传输位宽** | 8 / 16 / 24 / 32 bit 可配置（自定义 total_bits） |
| **时钟** | 可编程分频：f_sclk = f_clk / (2 × (div+1)) |
| **片选** | 多路 1-hot CS（默认4路），自动控制 + cs_keep 保持模式 |
| **中断** | 传输完成自动产生中断，W1C 清除 |
| **状态** | busy 忙标志 / data_avail 数据就绪 / done 完成标志 |
| **错误处理** | 忙时写触发寄存器返回 AXI SLVERR |
| **Vivado 集成** | Verilog 封装层适配 Block Design，含 TCL GUI 参数化脚本 |

## 模块架构

```
┌─────────────────────────────────────────────────┐
│                AXI_Lite_spi (Top)               │
│                                                 │
│  ┌──────────────────┐   ┌──────────────────┐   │
│  │  AXI_Lite_Slave  │   │   Spi_Master     │   │
│  │                  │   │                  │   │
│  │  AXI4-Lite 协议  │   │  SPI 时序控制    │   │
│  │  寄存器组         │◄──│  状态机          │   │
│  │  读/写译码       │──►│  移位寄存器      │   │
│  │  中断生成        │   │  SCLK 生成       │   │
│  │                  │   │  CS 控制         │   │
│  └──────────────────┘   └──────────────────┘   │
│                                                 │
└─────────────────────────────────────────────────┘
         ▲                              │
    AXI4-Lite Bus               SPI Physical Interface
    (S_AXI_*)                   (o_sclk, o_cs_n, o_mosi, i_miso, o_mosi_oe)
```

## 文件结构

```
AXI_Lite_spi/
├── hdl/
│   ├── AXI_Lite_Slave.sv          # AXI4-Lite 从机寄存器控制器
│   ├── Spi_Master.sv              # SPI 物理时序状态机
│   ├── AXI_Lite_spi.sv            # 顶层集成模块
│   └── AXI_Lite_spi_wrapper.v     # Vivado BD 纯 Verilog 封装层
├── tb/
│   └── tb_AXI_Lite_spi_0_1.sv     # 完整仿真测试平台（含 SPI 从机行为模型）
├── tcl/
│   └── AXI_Lite_spi_wrapper_v1_0.tcl  # Vivado IP Packager GUI 脚本
├── component.xml                  # IP 描述文件
└── README.md
```

## 寄存器映射

| 偏移 | 名称 | 类型 | 说明 |
|------|------|------|------|
| `0x00` | CPOL_CPHA_REG | R/W | Bit[0]=CPOL, Bit[1]=CPHA |
| `0x04` | RW_CMD_REG | R/W | Bit[1:0]: 00=仅写, 01=仅读, 10=半双工, 11=全双工 |
| `0x08` | LSB_FIRST_REG | R/W | Bit[0]: 0=MSB first, 1=LSB first |
| `0x0C` | CS_KEEP_REG | R/W | Bit[0]: 1=传输后 CS 保持低 |
| `0x10` | CS_SEL_REG | R/W | Bit[31:0]: 1-hot 片选编码 |
| `0x14` | CLK_DIV_REG | R/W | Bit[15:0]: SPI 时钟分频系数 |
| `0x18` | WDATA_REG | R/W | Bit[31:0]: 待发送数据 |
| `0x1C` | TOTAL_BITS_REG | R/W | Bit[5:0]: 总传输比特数 (1~32) |
| `0x20` | TX_BITS_REG | R/W | Bit[5:0]: 写阶段比特数 |
| `0x24` | RX_BITS_REG | R/W | Bit[5:0]: 接收对齐位数 |
| `0x28` | STATUS_REG | R | Bit[0]=busy, Bit[1]=data_avail, Bit[2]=done (W1C) |
| `0x2C` | RDATA_REG | R | Bit[31:0]: 接收数据快照 |
| `0x30` | TRIG_REG | W | Bit[0]=1 启动传输 (忙时返回 SLVERR) |

## AXI-Lite 操作流程

```
1. 写配置寄存器 (CPOL/CPHA/RW_CMD/CLK_DIV/CS_SEL/TOTAL_BITS/TX_BITS/RX_BITS)
2. 写 WDATA_REG (发送数据)
3. 写 TRIG_REG = 0x1 (启动 SPI 传输)
4. 等待:
    - 轮询模式: 读 STATUS_REG 检查 bit[2]=1
    - 中断模式: 等待 o_intr 上升沿
5. 读 RDATA_REG (获取接收数据, data_avail 自动清零)
6. 写 STATUS_REG bit[2]=1 (W1C 清除 done 标志和中断)
```

## SPI 时钟计算

```
f_sclk = f_clk / (2 × (CLK_DIV + 1))

示例: f_clk=100MHz, CLK_DIV=1 → f_sclk = 25MHz
```

## 使用示例 (C 伪代码)

```c
// 配置 SPI Mode 0, 仅写, 32bit, CS0, SCLK=25MHz
axi_write(0x00, 0x00000000);   // CPOL=0, CPHA=0
axi_write(0x04, 0x00000000);   // 仅写模式
axi_write(0x08, 0x00000000);   // MSB first
axi_write(0x0C, 0x00000000);   // 不保持 CS
axi_write(0x10, 0x00000001);   // 选中 CS0
axi_write(0x14, 0x00000001);   // 分频系数=1
axi_write(0x18, 0x12345678);   // 写数据
axi_write(0x1C, 0x00000020);   // 32 bits
axi_write(0x20, 0x00000020);   // TX 32 bits
axi_write(0x30, 0x00000001);   // 触发传输

// 等待完成
uint32_t status;
do { status = axi_read(0x28); } while (!(status & 0x4));

// 清除 done 标志
axi_write(0x28, 0x00000004);
```

## Vivado 集成

### Block Design 方式

1. 将 `hdl/` 下的所有源文件添加到 Vivado 工程
2. 使用 `AXI_Lite_spi_wrapper.v` 作为 BD 顶层模块
3. 连接到 PS 的 AXI-Lite Master 接口

### IP Packager 方式

1. 使用 `component.xml` + `tcl/` + `hdl/` 打包为自定义 IP
2. 在 Vivado IP Catalog 中即可搜索添加
3. TCL 脚本提供 GUI 参数配置界面

## 仿真

```bash
# 使用 Vivado xsim
cd tb
xvlog ../hdl/*.sv ../hdl/*.v ./tb_AXI_Lite_spi_0_1.sv
xelab tb_AXI_Lite_spi -debug typical
xsim tb_AXI_Lite_spi -gui
```

仿真包含以下测试：
- 寄存器读写测试
- 仅写 / 仅读 / 半双工 / 全双工四种模式
- 多片选独立读写
- CPOL/CPHA 全部四种 SPI Mode
- LSB First 位序
- 可变传输位宽 (8/16/24/32 bit)
- 背靠背连续传输
- Busy 错误处理 (SLVERR)
- W1C 清除与中断测试
- 复位后状态验证

## 兼容性

| FPGA 系列 | 支持 |
|-----------|------|
| Xilinx 7 Series | ✅ |
| UltraScale | ✅ |
| UltraScale+ | ✅ |
| Zynq-7000 | ✅ |
| Zynq MPSoC | ✅ |
| MicroBlaze | ✅ |

## License

MIT License
