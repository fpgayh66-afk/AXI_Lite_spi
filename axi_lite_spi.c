/**
 * @file axi_lite_spi.c
 * @brief AXI-Lite SPI 控制器驱动实现
 *
 * ====== 硬件工作原理(参照 AXI_Lite_Slave.sv) ======
 *
 * 本驱动控制FPGA(PL端)中的SPI控制器,该控制器由两个子模块组成:
 *   1. AXI_Lite_Slave: 解析AXI4-Lite总线协议,提供寄存器读写接口
 *   2. Spi_Master:     执行SPI物理时序,产生SCK/MOSI/CS,采样MISO
 *
 * 【寄存器操作流程】
 *   1. 配置各寄存器:     设置CPOL/CPHA/片选/时钟等参数(每个字段一个独立寄存器)
 *   2. 写WDATA_REG:      写入要发送的数据
 *   3. 写TRIG_REG:       启动传输! (写1触发)
 *   4. 轮询STATUS_REG:   检查bit[2]=1是否完成, 或等待中断
 *   5. 读RDATA_REG:      获取接收到的数据
 *
 * 【中断机制】
 *   硬件中 o_intr = spi_done_flag
 *   - Spi_Master完成传输后发出done脉冲 → spi_done_flag置1 → o_intr拉高
 *   - PS端写STATUS_REG[2]=1 → spi_done_flag清0 → o_intr拉低(中断清除)
 *   - 没有中断使能寄存器,传输完成就会产生中断
 *   - 如果不想用中断,在GIC中屏蔽该中断线即可
 *
 * 【传输完成后各标志的清除方式】
 *   - spi_done_flag [2]: W1C — 写STATUS_REG[2]=1清除(本驱动ClearDone函数)
 *   - data_avail_flag [1]: 自动 — 读RDATA_REG时硬件自动清除
 *
 * ====== 内存映射I/O (MMIO) ======
 * FPGA中的外设被映射到CPU地址空间中,CPU通过读写特定地址来和外设通信。
 * 例如: Vivado中分配基地址 0x43C00000,则:
 *   读 0x43C00028 = 读取STATUS_REG
 *   写 0x43C00030 = 触发SPI传输
 *
 * volatile关键字: 告诉编译器每次都真的去读内存,不要用缓存的旧值。
 */

#include "axi_lite_spi.h"

/* ============================================================
 * 平台适配: 寄存器访问宏
 *
 * 使用 ARM 内联汇编 str/ldr 指令,从指令层面保证 32 位 AXI 字访问。
 * volatile 指针 / Xil_Out32 在特定条件下(MMU属性为Normal、编译器优化
 * 等)可能被拆成字节访问,导致 AXI AWADDR 出现奇数地址。
 *
 * 如果 axi_lite_spi_port.h 已经定义了,则跳过此处的默认定义。
 * 用户也可在编译时用 -D 覆盖:
 *   gcc -DAXI_LITE_SPI_READ32=my_read32 ...
 * ============================================================ */
static inline uint32_t reg_read32(uint32_t addr)
{
    uint32_t val;
    __asm__ volatile("ldr %0, [%1]" : "=r"(val) : "r"(addr) : "memory");
    return val;
}

static inline void reg_write32(uint32_t addr, uint32_t data)
{
    __asm__ volatile("str %0, [%1]" : : "r"(data), "r"(addr) : "memory");
}

#ifndef AXI_LITE_SPI_READ32
#define AXI_LITE_SPI_READ32(addr)        reg_read32(addr)
#endif

#ifndef AXI_LITE_SPI_WRITE32
#define AXI_LITE_SPI_WRITE32(addr, data)  reg_write32(addr, data)
#endif

/* ============================================================
 * 可配置常量(可通过 -D 编译选项覆盖)
 * ============================================================ */
#ifndef AXI_LITE_SPI_POLL_MAX_RETRIES
#define AXI_LITE_SPI_POLL_MAX_RETRIES    1000000   // 默认最大轮询次数(约相当于1秒)
#endif

#ifndef AXI_LITE_SPI_DEFAULT_TIMEOUT_US
#define AXI_LITE_SPI_DEFAULT_TIMEOUT_US  1000000   // 默认超时: 1秒(对于SPI的微秒级传输足够)
#endif

#ifndef AXI_LITE_SPI_POLL_PERIOD_US
#define AXI_LITE_SPI_POLL_PERIOD_US      1         // 每次轮询估算消耗约1微秒
#endif

/* ============================================================
 * 内部辅助函数(static = 仅本文件内可见)
 * ============================================================ */

/**
 * @brief 计算寄存器的绝对地址: 基地址 + 偏移 = 绝对地址
 */
static inline uint32_t reg_addr(const axi_lite_spi_handle_t* hdl, uint32_t offset)
{
    return hdl->base_addr + offset;
}

/**
 * @brief 校验传输位宽是否合法
 *
 * 要求: 1) 在 8~32 范围内  2) 是8的倍数(整字节)
 *
 * (bits & 0x7) == 0 等价于 bits % 8 == 0,但位运算更快。
 * 0x7 = 0b0111,任何8的倍数的二进制低3位都是0:
 *   8(0b1000), 16(0b10000), 24(0b11000), 32(0b100000) 全部满足
 *   而 7(0b0111), 10(0b1010) 不满足
 *
 * @return 1=合法, 0=非法
 */
static inline int is_valid_bits(uint8_t bits)
{
    // bits=0 是合法的: 表示"本方向不传输数据"
    //   例: 只写模式 tx_bits=8, rx_bits=0 (不接收)
    //       只读模式 tx_bits=0, rx_bits=8 (不发送有效数据)
    // bits>0 时必须是8的倍数且在8~32范围内
    return (bits == 0) || ((bits >= 8) && (bits <= 32) && ((bits & 0x7) == 0));
}

/**
 * @brief 设置读写模式(rw_cmd), 直接写 RW_CMD_REG[1:0]
 *
 * 每个字段都是独立寄存器,无需读-改-写,直接写目标寄存器即可。
 */
static inline void set_rw_mode(const axi_lite_spi_handle_t* hdl, uint8_t mode)
{
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_RW_CMD_REG), (uint32_t)mode);
}

/**
 * @brief 执行一次完整的SPI传输(核心内部函数)
 *
 * 所有公开API(WriteOnly/ReadOnly/WriteThenRead/FullDuplex)最终都调用此函数。
 *
 * 流程:
 *   1. 检查busy — 如果硬件还在忙,拒绝新传输
 *   2. 设置rw_mode — 写RW_CMD_REG
 *   3. 配置传输bit数 — 写TOTAL_BITS/TX_BITS/RX_BITS三个寄存器
 *   4. 写发送数据 — 写WDATA_REG
 *   5. 触发传输 — 写TRIG_REG=1,硬件开始干活
 *   6. 只写模式 → 立即返回(发后不管,fire-and-forget)
 *   7. 其他模式 → 等待done(轮询STATUS_REG[2]) → 等待data_avail → 读RDATA_REG → 清除done
 *
 * 注意: 第7步使用轮询方式。如果用中断模式,用户可以:
 *   - 调用Transfer()而不是此函数(Transfer只触发不等待)
 *   - 在中断回调中自行读RDATA_REG和ClearDone
 */
static int spi_exec_transfer(axi_lite_spi_handle_t* hdl,
                             uint8_t  rw_mode,
                             uint32_t wdata,
                             uint8_t  total_bits,
                             uint8_t  tx_bits,
                             uint8_t  rx_bits,
                             uint32_t* rdata)
{
    int ret;
    uint32_t status;

    // --- 第1步: 检查硬件是否忙 ---
    status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
    if (status & AXI_LITE_SPI_STATUS_BUSY) {
        return AXI_LITE_SPI_BUSY;
    }

    // --- 第2步: 设置读写模式 ---
    set_rw_mode(hdl, rw_mode);

    // --- 第3步: 配置传输bit数 ---
    ret = AXI_LITE_SPI_SetTransferBits(hdl, total_bits, tx_bits, rx_bits);
    if (ret != AXI_LITE_SPI_OK) {
        return ret;
    }

    // --- 第4步: 写入发送数据 ---
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_WDATA_REG), wdata);

    // --- 第5步: 触发传输 ---
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_TRIG_REG), 1);

    // --- 第6步: 只写模式直接返回 ---
    if (rw_mode == AXI_LITE_SPI_RW_WRITE_ONLY) {
        return AXI_LITE_SPI_OK;
    }

    // --- 第7a步: 等待传输完成(轮询) ---
    ret = AXI_LITE_SPI_WaitDone(hdl, AXI_LITE_SPI_DEFAULT_TIMEOUT_US);
    if (ret != AXI_LITE_SPI_OK) {
        return ret;
    }

    // --- 第7b步: 等待接收数据就绪(轮询) ---
    {
        uint32_t retries = 0;
        status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
        while (!(status & AXI_LITE_SPI_STATUS_RDATA_READY)) {
            if (retries >= AXI_LITE_SPI_POLL_MAX_RETRIES) {
                AXI_LITE_SPI_ClearDone(hdl);
                return AXI_LITE_SPI_ERR_TIMEOUT;
            }
            retries++;
            status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
        }
    }

    // 读RDATA_REG,硬件会同时自动清除data_avail_flag(bit[1])
    if (rdata != NULL) {
        *rdata = AXI_LITE_SPI_ReadData(hdl);
    }

    // --- 第7c步: 清除done标志 ---
    AXI_LITE_SPI_ClearDone(hdl);

    return AXI_LITE_SPI_OK;
}

/* ============================================================
 * 驱动API实现
 * ============================================================ */

/**
 * @brief 初始化SPI驱动句柄
 *
 * 设置全部字段为安全的默认值:
 *   - SPI模式0(CPOL=0,CPHA=0), MSB优先, CS[0]选中
 *   - 中断回调为空(NULL)
 */
int AXI_LITE_SPI_Init(axi_lite_spi_handle_t* hdl, uint32_t base_addr)
{
    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    hdl->base_addr        = base_addr;

    hdl->config.clk_div   = 1;
    hdl->config.cpol      = 0;
    hdl->config.cpha      = 0;
    hdl->config.lsb_first = 0;
    hdl->config.cs_keep   = 0;
    hdl->config.cs_sel    = 1;

    hdl->irq_callback  = NULL;
    hdl->irq_user_data = NULL;

    return AXI_LITE_SPI_OK;
}

/**
 * @brief 配置SPI参数(每个字段写独立寄存器)
 *
 * 新硬件每个配置字段都是独立寄存器,直接写即可,无需位打包。
 */
int AXI_LITE_SPI_SetConfig(axi_lite_spi_handle_t* hdl, const axi_lite_spi_config_t* cfg)
{
    if (hdl == NULL || cfg == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    // CPOL/CPHA: [0]=cpol, [1]=cpha
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_CPOL_CPHA_REG),
                         ((uint32_t)(cfg->cpol) & 0x1) |
                         (((uint32_t)(cfg->cpha) & 0x1) << 1));

    // LSB_FIRST: [0]=lsb_first
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_LSB_FIRST_REG),
                         (uint32_t)(cfg->lsb_first) & 0x1);

    // CS_KEEP: [0]=cs_keep
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_CS_KEEP_REG),
                         (uint32_t)(cfg->cs_keep) & 0x1);

    // CS_SEL: [31:0]=cs_sel (1-hot, 32bit)
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_CS_SEL_REG), cfg->cs_sel);

    // CLK_DIV: [15:0]=clk_div
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_CLK_DIV_REG),
                         cfg->clk_div & 0xFFFF);

    // 保存软件副本
    hdl->config = *cfg;
    return AXI_LITE_SPI_OK;
}

/**
 * @brief 获取当前SPI配置(从硬件寄存器读回)
 */
int AXI_LITE_SPI_GetConfig(axi_lite_spi_handle_t* hdl, axi_lite_spi_config_t* cfg)
{
    uint32_t val;

    if (hdl == NULL || cfg == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    // CPOL_CPHA_REG: [0]=cpol, [1]=cpha
    val = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_CPOL_CPHA_REG));
    cfg->cpol = (uint8_t)(val & 0x1);
    cfg->cpha = (uint8_t)((val >> 1) & 0x1);

    // LSB_FIRST_REG: [0]=lsb_first
    val = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_LSB_FIRST_REG));
    cfg->lsb_first = (uint8_t)(val & 0x1);

    // CS_KEEP_REG: [0]=cs_keep
    val = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_CS_KEEP_REG));
    cfg->cs_keep = (uint8_t)(val & 0x1);

    // CS_SEL_REG: [31:0]=cs_sel
    cfg->cs_sel = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_CS_SEL_REG));

    // CLK_DIV_REG: [15:0]=clk_div
    cfg->clk_div = (uint16_t)(AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_CLK_DIV_REG)) & 0xFFFF);

    return AXI_LITE_SPI_OK;
}

/**
 * @brief 配置传输bit数(三个独立寄存器)
 *
 * 驱动层强制校验: 每个值都必须是8的倍数且在8~32范围内。
 */
int AXI_LITE_SPI_SetTransferBits(axi_lite_spi_handle_t* hdl,
                                 uint8_t total_bits,
                                 uint8_t tx_bits,
                                 uint8_t rx_bits)
{
    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    // --- 字节对齐校验 ---
    if (!is_valid_bits(total_bits) ||
        !is_valid_bits(tx_bits)    ||
        !is_valid_bits(rx_bits)) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    // 发送和接收的位数不能超过总位数
    if (tx_bits > total_bits || rx_bits > total_bits) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    // 写三个独立寄存器
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_TOTAL_BITS_REG),
                         (uint32_t)total_bits & 0x3F);
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_TX_BITS_REG),
                         (uint32_t)tx_bits & 0x3F);
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_RX_BITS_REG),
                         (uint32_t)rx_bits & 0x3F);

    return AXI_LITE_SPI_OK;
}

/**
 * @brief 启动SPI传输(底层触发,不等待完成)
 */
int AXI_LITE_SPI_Transfer(axi_lite_spi_handle_t* hdl, uint32_t wdata)
{
    uint32_t status;

    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
    if (status & AXI_LITE_SPI_STATUS_BUSY) {
        return AXI_LITE_SPI_BUSY;
    }

    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_WDATA_REG), wdata);
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_TRIG_REG), 1);

    return AXI_LITE_SPI_OK;
}

/**
 * @brief 仅写模式
 */
int AXI_LITE_SPI_WriteOnly(axi_lite_spi_handle_t* hdl, uint32_t wdata, uint8_t bits)
{
    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    if (!is_valid_bits(bits)) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    return spi_exec_transfer(hdl, AXI_LITE_SPI_RW_WRITE_ONLY,
                             wdata, bits, bits, 0, NULL);
}

/**
 * @brief 仅读模式
 */
int AXI_LITE_SPI_ReadOnly(axi_lite_spi_handle_t* hdl, uint32_t dummy,
                          uint8_t bits, uint32_t* rdata)
{
    if (hdl == NULL || rdata == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    if (!is_valid_bits(bits)) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    return spi_exec_transfer(hdl, AXI_LITE_SPI_RW_READ_ONLY,
                             dummy, bits, 0, bits, rdata);
}

/**
 * @brief 先写后读(半双工)模式
 */
int AXI_LITE_SPI_WriteThenRead(axi_lite_spi_handle_t* hdl, uint32_t wdata,
                               uint8_t tx_bits, uint8_t rx_bits, uint32_t* rdata)
{
    if (hdl == NULL || rdata == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    if (!is_valid_bits(tx_bits) || !is_valid_bits(rx_bits)) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    return spi_exec_transfer(hdl, AXI_LITE_SPI_RW_HALF_DUPLEX,
                             wdata,
                             (uint8_t)(tx_bits + rx_bits),
                             tx_bits,
                             rx_bits,
                             rdata);
}

/**
 * @brief 全双工模式
 */
int AXI_LITE_SPI_FullDuplex(axi_lite_spi_handle_t* hdl, uint32_t wdata,
                            uint8_t bits, uint32_t* rdata)
{
    if (hdl == NULL || rdata == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    if (!is_valid_bits(bits)) {
        return AXI_LITE_SPI_ERR_RANGE;
    }

    return spi_exec_transfer(hdl, AXI_LITE_SPI_RW_FULL_DUPLEX,
                             wdata, bits, bits, bits, rdata);
}

/**
 * @brief 获取STATUS_REG原始值
 */
uint32_t AXI_LITE_SPI_GetStatus(axi_lite_spi_handle_t* hdl)
{
    if (hdl == NULL) {
        return 0;
    }
    return AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
}

/**
 * @brief 检查SPI是否忙
 */
int AXI_LITE_SPI_IsBusy(axi_lite_spi_handle_t* hdl)
{
    uint32_t status = AXI_LITE_SPI_GetStatus(hdl);
    return (status & AXI_LITE_SPI_STATUS_BUSY) ? 1 : 0;
}

/**
 * @brief 清除spi_done_flag (W1C: 写STATUS_REG[2]=1)
 */
int AXI_LITE_SPI_ClearDone(axi_lite_spi_handle_t* hdl)
{
    uint32_t status_val;

    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    status_val = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
    status_val |= AXI_LITE_SPI_STATUS_DONE;
    AXI_LITE_SPI_WRITE32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG), status_val);

    return AXI_LITE_SPI_OK;
}

/**
 * @brief 等待传输完成(轮询方式)
 */
int AXI_LITE_SPI_WaitDone(axi_lite_spi_handle_t* hdl, uint32_t timeout_us)
{
    uint32_t max_retries;
    uint32_t retries = 0;
    volatile uint32_t status;

    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    if (timeout_us > 0) {
        max_retries = timeout_us / AXI_LITE_SPI_POLL_PERIOD_US;
        if (max_retries == 0) {
            max_retries = 1;
        }
    } else {
        max_retries = AXI_LITE_SPI_POLL_MAX_RETRIES;
    }

    while (retries < max_retries) {
        status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));
        if (status & AXI_LITE_SPI_STATUS_DONE) {
            return AXI_LITE_SPI_OK;
        }
        retries++;
    }

    return AXI_LITE_SPI_ERR_TIMEOUT;
}

/**
 * @brief 读取SPI接收数据
 */
uint32_t AXI_LITE_SPI_ReadData(axi_lite_spi_handle_t* hdl)
{
    if (hdl == NULL) {
        return 0;
    }
    return AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_RDATA_REG));
}

/* ============================================================
 * 中断相关API实现
 * ============================================================ */

int AXI_LITE_SPI_RegisterIRQCallback(axi_lite_spi_handle_t* hdl,
                                     axi_lite_spi_irq_callback_t callback,
                                     void* user_data)
{
    if (hdl == NULL) {
        return AXI_LITE_SPI_ERR_PARAM;
    }

    hdl->irq_callback  = callback;
    hdl->irq_user_data = user_data;

    return AXI_LITE_SPI_OK;
}

void AXI_LITE_SPI_IRQHandler(axi_lite_spi_handle_t* hdl)
{
    uint32_t status;

    if (hdl == NULL) {
        return;
    }

    status = AXI_LITE_SPI_READ32(reg_addr(hdl, AXI_LITE_SPI_STATUS_REG));

    if (status & AXI_LITE_SPI_STATUS_DONE) {
        AXI_LITE_SPI_ClearDone(hdl);

        if (hdl->irq_callback != NULL) {
            hdl->irq_callback(hdl->irq_user_data);
        }
    }
}
