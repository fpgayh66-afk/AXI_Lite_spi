/**
 * @file axi_lite_spi.h
 * @brief AXI-Lite SPI 控制器驱动头文件
 *
 * ====== 背景知识 ======
 * 这个文件是一个"驱动程序"的头文件,用于让CPU(PS端,如ARM核)通过软件控制
 * FPGA(PL端)中的SPI硬件模块。
 *
 * 【SPI是什么?】
 * SPI(Serial Peripheral Interface, 串行外设接口)是一种常用的通信协议,用于芯片之间传输数据。
 * 它使用4根信号线:
 *   - SCK (串行时钟): 由主设备产生,控制数据传输的节奏
 *   - MOSI (主出从入): 主设备发送数据给从设备的线
 *   - MISO (主入从出): 从设备发送数据给主设备的线
 *   - CS/SS (片选): 选择与哪个从设备通信(可以有多个从设备共用SCK/MOSI/MISO)
 *
 * 【AXI-Lite是什么?】
 * AXI-Lite是ARM公司定义的一种"片上总线协议",用于CPU和各个外设之间通信。
 * CPU通过读写特定地址来和外设交换数据,就像CPU访问内存一样。
 *
 * 【什么是寄存器?】
 * 寄存器是硬件中的一小块存储空间(通常32位)。CPU通过读写这些寄存器地址来控制硬件。
 *
 * ====== 硬件寄存器映射(参照 AXI_Lite_Slave.sv) ======
 *   0x00 CPOL_CPHA_REG  R/W  [0]cpol [1]cpha
 *   0x04 RW_CMD_REG     R/W  [1:0]rw_cmd
 *   0x08 LSB_FIRST_REG  R/W  [0]lsb_first
 *   0x0C CS_KEEP_REG    R/W  [0]cs_keep
 *   0x10 CS_SEL_REG     R/W  [31:0]cs_sel (1-hot)
 *   0x14 CLK_DIV_REG    R/W  [15:0]clk_div
 *   0x18 WDATA_REG      R/W  [31:0]wdata
 *   0x1C TOTAL_BITS_REG R/W  [5:0]total_bits (1~32)
 *   0x20 TX_BITS_REG    R/W  [5:0]tx_bits
 *   0x24 RX_BITS_REG    R/W  [5:0]rx_bits
 *   0x28 STATUS_REG     R    [0]busy [1]data_avail [2]done (W1C)
 *   0x2C RDATA_REG      R    [31:0]rdata (只读)
 *   0x30 TRIG_REG       W    [0]start (写1启动)
 *
 * ====== 中断机制(参照硬件 o_intr = spi_done_flag) ======
 * PL端(FPGA)每完成一次SPI传输(不管是读还是写),就会自动拉高中断信号 o_intr。
 * PS端(CPU)收到中断后:
 *   1. 读 STATUS_REG 确认是 spi_done_flag 置位
 *   2. 如果需要读取数据: 读 RDATA_REG (同时自动清除 data_avail_flag)
 *   3. 向 STATUS_REG 的 bit[2] 写 1 (W1C) 来清除 spi_done_flag,中断信号随之拉低
 *
 * 注意: 中断是硬件自动产生的,没有"中断使能寄存器"——只要传输完成就会产生中断。
 * 如果不想使用中断,在PS端的中断控制器(如GIC)中屏蔽该中断线即可。
 *
 * ====== 传输数据宽度说明 ======
 * 本驱动以字节为最小传输单位,只支持 1~4 字节传输(即 8/16/24/32 位)。
 * 虽然硬件支持 1~32 任意位宽,但实际SPI通信中非整字节的场景极少,
 * 且容易出错,因此驱动层面强制要求字节对齐。
 */

#ifndef AXI_LITE_SPI_H
#define AXI_LITE_SPI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================
 * 寄存器偏移地址(相对于基地址的字节偏移)
 * ============================================================ */
#define AXI_LITE_SPI_CPOL_CPHA_REG  0x00   // CPOL/CPHA: [0]=cpol, [1]=cpha
#define AXI_LITE_SPI_RW_CMD_REG     0x04   // 读写命令: [1:0]=rw_cmd
#define AXI_LITE_SPI_LSB_FIRST_REG  0x08   // LSB优先: [0]=lsb_first
#define AXI_LITE_SPI_CS_KEEP_REG    0x0C   // CS保持: [0]=cs_keep
#define AXI_LITE_SPI_CS_SEL_REG     0x10   // 片选: [31:0]=cs_sel (1-hot, 32bit)
#define AXI_LITE_SPI_CLK_DIV_REG    0x14   // 时钟分频: [15:0]=clk_div
#define AXI_LITE_SPI_WDATA_REG      0x18   // 写数据: [31:0]=wdata
#define AXI_LITE_SPI_TOTAL_BITS_REG 0x1C   // 总传输位数: [5:0]=total_bits (1~32)
#define AXI_LITE_SPI_TX_BITS_REG    0x20   // 写阶段位数: [5:0]=tx_bits
#define AXI_LITE_SPI_RX_BITS_REG    0x24   // 接收对齐位数: [5:0]=rx_bits
#define AXI_LITE_SPI_STATUS_REG     0x28   // 状态: [0]busy [1]data_avail [2]done (W1C)
#define AXI_LITE_SPI_RDATA_REG      0x2C   // 读数据: [31:0]rdata (只读)
#define AXI_LITE_SPI_TRIG_REG       0x30   // 触发: [0]=start (写1启动)

/* ============================================================
 * rw_cmd 传输模式值(写入 RW_CMD_REG[1:0])
 * ============================================================ */
#define AXI_LITE_SPI_RW_WRITE_ONLY   0   // 只写:   只发送数据,不关心从设备返回
#define AXI_LITE_SPI_RW_READ_ONLY    1   // 只读:   只接收数据,发送dummy产生时钟
#define AXI_LITE_SPI_RW_HALF_DUPLEX  2   // 半双工: 先发送命令,再接收响应(分两个阶段)
#define AXI_LITE_SPI_RW_FULL_DUPLEX  3   // 全双工: 同时发送和接收

/* ============================================================
 * STATUS_REG (状态寄存器) 位域定义
 *
 * STATUS_REG 的3个位分别对应3个硬件标志:
 *   bit[0] = spi_busy:         硬件正在传输中(只读,由硬件Spi_Master控制)
 *   bit[1] = data_avail_flag:  接收数据已就绪(读RDATA_REG自动清除)
 *   bit[2] = spi_done_flag:    传输已完成(写STATUS_REG[2]=1来清除,W1C)
 *
 * 中断信号 o_intr 直接等于 spi_done_flag:
 *   传输完成 → Spi_Master发出done脉冲 → spi_done_flag置1 → o_intr拉高
 *   清除方法 → PS端写 STATUS_REG 的 bit[2]=1 → spi_done_flag清0 → o_intr拉低
 * ============================================================ */
#define AXI_LITE_SPI_STATUS_BUSY        0x01   // bit[0]=1: 硬件忙,正在传输中
#define AXI_LITE_SPI_STATUS_RDATA_READY 0x02   // bit[1]=1: 接收数据已就绪,读RDATA_REG自动清除
#define AXI_LITE_SPI_STATUS_DONE        0x04   // bit[2]=1: 传输已完成,写STATUS_REG[2]=1来清除(W1C)

/* ============================================================
 * 传输字节数限制
 *
 * 传输以字节为单位: 最小1字节(8位), 最大4字节(32位)。
 * 虽然硬件支持1~32任意位宽,但驱动层强制整字节。
 * ============================================================ */
#define AXI_LITE_SPI_MIN_TXRX_BYTES     1      // 最小: 1字节 = 8位
#define AXI_LITE_SPI_MAX_TXRX_BYTES     4      // 最大: 4字节 = 32位
#define AXI_LITE_SPI_MIN_TXRX_BITS      8      // 最小位宽: 8位
#define AXI_LITE_SPI_MAX_TXRX_BITS      32     // 最大位宽: 32位

/* ============================================================
 * 返回值定义
 *   0  = 成功
 *   负数 = 错误码
 *   正数 = 提示信息(如忙)
 * ============================================================ */
#define AXI_LITE_SPI_OK            0   // 操作成功
#define AXI_LITE_SPI_ERR_PARAM    -1   // 参数错误(NULL指针等)
#define AXI_LITE_SPI_ERR_RANGE    -2   // 范围错误(数值超出范围或非字节对齐)
#define AXI_LITE_SPI_ERR_TIMEOUT  -3   // 轮询等待超时
#define AXI_LITE_SPI_BUSY          1   // SPI正忙(非错误,稍后重试)

/* ============================================================
 * 传输模式枚举
 * ============================================================ */
typedef enum {
    AXI_LITE_SPI_MODE_WRITE_ONLY  = AXI_LITE_SPI_RW_WRITE_ONLY,   // 0: 只写
    AXI_LITE_SPI_MODE_READ_ONLY   = AXI_LITE_SPI_RW_READ_ONLY,    // 1: 只读
    AXI_LITE_SPI_MODE_HALF_DUPLEX = AXI_LITE_SPI_RW_HALF_DUPLEX,  // 2: 半双工
    AXI_LITE_SPI_MODE_FULL_DUPLEX = AXI_LITE_SPI_RW_FULL_DUPLEX   // 3: 全双工
} axi_lite_spi_mode_t;

/* ============================================================
 * 中断回调函数类型
 *
 * 传输完成后硬件自动拉高中断,ISR中调用此回调通知用户。
 * 注意: 回调运行在中断上下文中,必须短小精悍(只设置标志)。
 *
 * 使用示例:
 *   volatile int g_spi_done = 0;
 *   void my_callback(void* data) {
 *       *(volatile int*)data = 1;  // 只设标志,快速退出
 *   }
 *
 *   // 注册回调
 *   AXI_LITE_SPI_RegisterIRQCallback(&spi, my_callback, &g_spi_done);
 *
 *   // 平台ISR中调用(见 AXI_LITE_SPI_IRQHandler 说明)
 * ============================================================ */
typedef void (*axi_lite_spi_irq_callback_t)(void* user_data);

/* ============================================================
 * SPI配置结构体
 * ============================================================ */
typedef struct {
    uint32_t clk_div;        // 时钟分频系数: SPI时钟频率 = 系统时钟 / (clk_div * 2)
                             // 例: 系统100MHz, clk_div=5 → SPI时钟=10MHz, 范围1~65535

    uint8_t  cpol;           // 时钟极性: 0=SCK空闲低(常用), 1=SCK空闲高
    uint8_t  cpha;           // 时钟相位: 0=第一边沿采样, 1=第二边沿采样
    uint8_t  lsb_first;      // 位序: 0=MSB优先(常用), 1=LSB优先
    uint8_t  cs_keep;        // CS保持: 0=传输后拉高, 1=保持低(连续传输用)
    uint32_t cs_sel;         // 片选: 32位one-hot编码, 如0x1=CS[0], 0x2=CS[1]
} axi_lite_spi_config_t;

/* ============================================================
 * 驱动句柄
 * ============================================================ */
typedef struct {
    uint32_t                    base_addr;     // AXI-Lite外设基地址(查Vivado Address Editor)
    axi_lite_spi_config_t       config;        // 当前SPI配置的软件副本

    axi_lite_spi_irq_callback_t irq_callback;  // 中断回调函数指针(NULL=未注册)
    void*                       irq_user_data; // 回调时传入的用户自定义数据
} axi_lite_spi_handle_t;

/* ============================================================
 * 函数声明
 * ============================================================ */

/**
 * @brief 初始化SPI驱动句柄
 *
 * 设置默认配置: clk_div=1, cpol=0, cpha=0, lsb_first=0, cs_keep=0, cs_sel=1
 * 中断回调初始为NULL(未注册)。
 *
 * @param hdl       用户分配的句柄指针
 * @param base_addr AXI-Lite外设基地址(硬件决定的)
 * @return OK / ERR_PARAM
 */
int AXI_LITE_SPI_Init(axi_lite_spi_handle_t* hdl, uint32_t base_addr);

/**
 * @brief 配置SPI参数(写各配置寄存器 + CLK_DIV_REG)
 *
 * @param hdl 驱动句柄
 * @param cfg SPI配置参数
 * @return OK / ERR_PARAM
 */
int AXI_LITE_SPI_SetConfig(axi_lite_spi_handle_t* hdl, const axi_lite_spi_config_t* cfg);

/**
 * @brief 获取当前SPI配置(回读硬件寄存器)
 *
 * @param hdl 驱动句柄
 * @param cfg 输出: 当前配置写入此处
 * @return OK / ERR_PARAM
 */
int AXI_LITE_SPI_GetConfig(axi_lite_spi_handle_t* hdl, axi_lite_spi_config_t* cfg);

/**
 * @brief 配置传输字节数
 *
 * 传输必须以整字节为单位: 8/16/24/32 位(即1/2/3/4字节)。
 * 虽然硬件支持1~32任意位,但驱动强制整字节以确保数据完整性。
 *
 * @param hdl        驱动句柄
 * @param total_bits 总传输位数(8/16/24/32)
 * @param tx_bits    写阶段位数(8/16/24/32, 必须 <= total_bits)
 * @param rx_bits    接收位数(8/16/24/32, 必须 <= total_bits)
 * @return OK / ERR_PARAM / ERR_RANGE
 */
int AXI_LITE_SPI_SetTransferBits(axi_lite_spi_handle_t* hdl,
                                 uint8_t total_bits,
                                 uint8_t tx_bits,
                                 uint8_t rx_bits);

/**
 * @brief 启动SPI传输(底层接口,不等待完成)
 *
 * 将数据写入WDATA_REG,然后向TRIG_REG写1触发传输,立即返回。
 * 注意: 调用前需先用SetConfig和SetTransferBits配置好参数。
 *
 * @param hdl   驱动句柄
 * @param wdata 要发送的32位数据
 * @return OK / BUSY / ERR_PARAM
 */
int AXI_LITE_SPI_Transfer(axi_lite_spi_handle_t* hdl, uint32_t wdata);

/**
 * @brief 仅写模式 — 只发送数据,发后不管(不等待完成)
 *
 * @param hdl   驱动句柄
 * @param wdata 写数据(32位,只有低bits位有效)
 * @param bits  发送位数(8/16/24/32)
 * @return OK / BUSY / ERR_RANGE
 */
int AXI_LITE_SPI_WriteOnly(axi_lite_spi_handle_t* hdl, uint32_t wdata, uint8_t bits);

/**
 * @brief 仅读模式 — 只接收数据(发送dummy产生SCK时钟)
 *
 * @param hdl    驱动句柄
 * @param dummy  发送的哑数据(产生时钟用,通常0xFF或0x00)
 * @param bits   接收位数(8/16/24/32)
 * @param rdata  输出: 接收到的数据
 * @return OK / BUSY / ERR_RANGE
 */
int AXI_LITE_SPI_ReadOnly(axi_lite_spi_handle_t* hdl, uint32_t dummy,
                          uint8_t bits, uint32_t* rdata);

/**
 * @brief 先写后读(半双工)模式
 *
 * 常用于: 先发命令字,再收响应数据。
 * tx_bits和rx_bits都必须整字节(8/16/24/32)。
 *
 * @param hdl     驱动句柄
 * @param wdata   写数据(通常是命令字)
 * @param tx_bits 写阶段位数(8/16/24/32)
 * @param rx_bits 读阶段位数(8/16/24/32)
 * @param rdata   输出: 接收到的数据
 * @return OK / BUSY / ERR_RANGE
 */
int AXI_LITE_SPI_WriteThenRead(axi_lite_spi_handle_t* hdl, uint32_t wdata,
                               uint8_t tx_bits, uint8_t rx_bits, uint32_t* rdata);

/**
 * @brief 全双工模式 — 同时发送和接收
 *
 * @param hdl   驱动句柄
 * @param wdata 写数据
 * @param bits  传输位数(8/16/24/32)
 * @param rdata 输出: 接收到的数据
 * @return OK / BUSY / ERR_RANGE
 */
int AXI_LITE_SPI_FullDuplex(axi_lite_spi_handle_t* hdl, uint32_t wdata,
                            uint8_t bits, uint32_t* rdata);

/**
 * @brief 获取SPI状态寄存器原始值
 *
 * @param hdl 驱动句柄
 * @return STATUS_REG的32位值(bit[2:0]有效), hdl=NULL返回0
 */
uint32_t AXI_LITE_SPI_GetStatus(axi_lite_spi_handle_t* hdl);

/**
 * @brief 检查SPI是否忙
 *
 * @param hdl 驱动句柄
 * @return 1=忙, 0=空闲
 */
int AXI_LITE_SPI_IsBusy(axi_lite_spi_handle_t* hdl);

/**
 * @brief 清除spi_done标志 (W1C: 向STATUS_REG[2]写1)
 *
 * 硬件会在传输完成时将spi_done_flag置1,同时o_intr拉高。
 * 调用此函数向STATUS_REG的bit[2]写1来清除该标志,o_intr随之拉低。
 *
 * 在中断模式中,IRQHandler内部会自动调用此函数清除done标志。
 * 在轮询模式中,spi_exec_transfer内部也会自动调用。
 *
 * 原理: W1C(Write-1-to-Clear) — 向目标位写1来清除它,写0的位保持不变。
 * 这保证了软件只清除自己关心的位,不会误伤硬件同时更新的其他状态位。
 *
 * @param hdl 驱动句柄
 * @return OK / ERR_PARAM
 */
int AXI_LITE_SPI_ClearDone(axi_lite_spi_handle_t* hdl);

/**
 * @brief 等待传输完成(轮询方式)
 *
 * CPU反复读STATUS_REG检查bit[2](spi_done_flag),直到完成或超时。
 * 这是"忙等"(busy-wait),等待期间CPU不能做别的事。
 *
 * 如需更高效的方式,使用中断模式:
 *   先注册回调(RegisterIRQCallback),启动传输后CPU去做别的事,
 *   传输完成时硬件自动拉高中断→平台ISR调用IRQHandler→回调通知。
 *
 * @param hdl        驱动句柄
 * @param timeout_us 超时时间(微秒), 0=使用默认超时(~1秒)
 * @return OK / ERR_TIMEOUT
 */
int AXI_LITE_SPI_WaitDone(axi_lite_spi_handle_t* hdl, uint32_t timeout_us);

/**
 * @brief 读取SPI接收数据
 *
 * 从RDATA_REG读取硬件接收到的32位数据。
 * 调用前必须确保传输已完成(WaitDone返回OK,或中断回调已触发)。
 *
 * 注意: 读RDATA_REG的同时,硬件会自动清除data_avail_flag(bit[1])。
 *
 * @param hdl 驱动句柄
 * @return 32位接收数据(hdl=NULL返回0)
 */
uint32_t AXI_LITE_SPI_ReadData(axi_lite_spi_handle_t* hdl);

/* ============================================================
 * 中断相关API
 *
 * 中断机制(来自硬件设计):
 *   o_intr = spi_done_flag
 *   - 任何SPI传输完成(只写/只读/半双工/全双工),硬件自动拉高中断
 *   - 没有"中断使能寄存器",中断始终生效
 *   - 清中断: 写STATUS_REG[2]=1 (W1C),清除了spi_done_flag则o_intr拉低
 *
 * 使用流程:
 *   1. 注册回调:  RegisterIRQCallback(&spi, my_cb, &my_flag)
 *   2. 启动传输:  AXI_LITE_SPI_WriteOnly(&spi, data, 8)
 *   3. CPU做别的事...
 *   4. 传输完成 → o_intr拉高 → GIC触发IRQ
 *   5. 平台ISR中:  AXI_LITE_SPI_IRQHandler(&spi)
 *   6. IRQHandler: 检查done→清除done→调用my_cb
 *   7. 回调中设标志: *my_flag = 1
 *   8. 主程序检测到标志,读RDATA_REG获取数据
 * ============================================================ */

/**
 * @brief 注册中断回调函数
 *
 * 传输完成后,IRQHandler会调用此回调。回调运行在中断上下文中,应尽量简短。
 * 传入NULL可取消注册。
 *
 * @param hdl       驱动句柄
 * @param callback  回调函数指针(NULL=取消)
 * @param user_data 回调时原样传入的用户数据
 * @return OK / ERR_PARAM
 */
int AXI_LITE_SPI_RegisterIRQCallback(axi_lite_spi_handle_t* hdl,
                                     axi_lite_spi_irq_callback_t callback,
                                     void* user_data);

/**
 * @brief SPI中断服务函数 — 必须在平台ISR中调用
 *
 * 此函数完成中断处理的标准流程:
 *   1. 读STATUS_REG,确认spi_done_flag置位(中断来源确认)
 *   2. 向STATUS_REG[2]写1清除spi_done_flag(W1C),o_intr随之拉低
 *   3. 调用用户注册的回调函数(如果已注册)
 *
 * 平台ISR中的典型调用方式:
 *
 *   // 假设SPI模块的中断线连接到了GIC的SPI ID 61
 *   void GIC_SPI61_IRQHandler(void) {
 *       AXI_LITE_SPI_IRQHandler(&g_spi_dev);
 *   }
 *
 * @param hdl 驱动句柄
 */
void AXI_LITE_SPI_IRQHandler(axi_lite_spi_handle_t* hdl);

#ifdef __cplusplus
}
#endif

#endif /* AXI_LITE_SPI_H */
