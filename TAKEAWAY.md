# TransferEngine

## TransferEngineImpl::init()
- 连接元数据、决定装哪些 transport、发现本机拓扑
- 配置 transport 类型: 强制TCP > 平台专用(Ascend等) > GPU P2P(NVLink/MUSA) > RDMA(有HCA) > TCP(兜底)

## Transport
- 核心数据模型的四层结构: 一次数据传输会被拆分成4层
    - TransferRequest: 用户的一次传输请求
    - TransferTask: 一个`TransferRequest` 在引擎内部对应一个`TransferTask`, 负责跟踪进度; 一个 task 会被拆成多个`Slice`, task 完成 = 所有 slice 完成.
    - Slice: 物理传输的最小单位, 因为 一次大的传输可能跨多块内存、超过单次网卡操作上限, 必须切片.
    - BatchDesc: 一批TransferTask任务

## RDMA

**RDMA（Remote Direct Memory Access，远程直接内存访问）** ：一台机器可以直接读写另一台机器的内存，全程 **不打扰对方 CPU、不经过操作系统内核** .

- 为什么需要 RDMA（传统 TCP/IP 的痛点）?
    - 传统网络传输走内核协议栈，存在三大开销： 
        1. **多次内存拷贝** ：数据在用户态与内核态缓冲区之间反复 copy;
        2. **CPU 深度参与** ：每个包都要 CPU 跑协议栈、处理中断，大流量时 CPU 被吃满;
        3. **上下文切换** ：用户态/内核态频繁切换，延迟高。
    - RDMA三大机制:
        - **Kernel Bypass（内核旁路）** ：应用通过 Verbs API 直接和网卡交互，数据路径不经过内核;
        - **Zero Copy（零拷贝）** ：网卡 DMA 引擎直接从/向应用内存收发数据，中间无拷贝;
        - **CPU Offload（协议卸载）** ：分片、重组、可靠性由网卡硬件完成，CPU 只需下发指令。
    - 工作模型：QP + WR + CQ:
        - **QP（Queue Pair 队列对）** ：每个连接由发送队列(SQ) + 接收队列(RQ)组成;
        - **WR（Work Request 工作请求）** ：应用把「读/写哪段内存」封装成 WR 投递到队列;
        - **CQ（Completion Queue 完成队列）** ：网卡完成后放入完成通知，应用轮询获取。

- RoCE 与 InfiniBand
RDMA 最早诞生于 **InfiniBand（IB）** 专用网络； **RoCE（RDMA over Converged Ethernet）** 让 RDMA 跑在普通以太网上。

| RoCE 版本 | 封装层 | 是否可跨路由 | 说明 |
|-----------|--------|--------------|------|
| RoCEv1 | 以太网帧 (L2) | ❌ 不可跨路由 | 仅限同二层网络 |
| RoCEv2 | UDP/IP (L3)   | ✅ 可跨三层   | 数据中心主流 |

> 判断依据：`ibstat` 中 `Link layer: Ethernet` 即 RoCE 模式；`Base lid / SM lid = 0` 说明无 IB 的 LID/子网管理器概念。RoCEv2 + IPv4 通常对应 GID 表中 `VER=v2` 的 IPv4 条目。

- 单边 RDMA vs 双边 RDMA: 本质区别为 **对端 CPU 是否参与本次数据传输**
    - 双边（Two-sided：SEND / RECV） 
        - 接收方必须 **提前投递 RECV** （准备好接收缓冲区），否则发送失败。 
        - **接收方 CPU 需要参与、有感知** 。 
        - 发送方无需知道对端内存地址，数据落点由接收方 RECV 决定。 
        - 语义 = **消息传递** ，适合握手、控制信令、通知。 
    - 单边（One-sided：WRITE / READ / Atomic） 
        - **对端 CPU 完全不参与、无感知** ，对端无需投递任何请求。 
        - 发起方 **必须预先知道对端内存地址 + rkey（远程访问密钥）** 。 
        - `RDMA_WRITE` ：把本地数据写入远端内存； `RDMA_READ` ：把远端数据读到本地。 
        - 语义 = **远程内存读写** ，延迟最低、CPU 开销最小。

### 列出本机所有RDMA设备
`ibv_devices`: 列出本机所有可用的 RDMA 设备（InfiniBand / RoCE 网卡），显示每个设备的名称（device）和节点 GUID（全局唯一标识）
```bash
    device                 node GUID
    ------              ----------------
    mlx5_0              08c0eb03xxxxxx98 # Mellanox 网卡（mlx5 驱动）
    mlx5_1              b8cef603xxxxxxee
    mlx5_2              b8cef603xxxxxxd6
    mlx5_3              b8cef603xxxxxxe2
```
`mlx5_1/2/3` 的 GUID 前缀都是`b8cef603` ，很可能是 同一张多口网卡 或同型号网卡；而`mlx5_0` 前缀`08c0eb03` 不同，可能是另一张网卡（常见于一块做管理/存储、另一块做计算的架构）

### 查看每块设备的端口状态
`ibstat`: 显示每块 RDMA 设备的详细状态
    - State （端口状态：Active / Down）
    - Physical state （物理链路：LinkUp / Disabled / Polling）
    - Rate （速率，如 100/200/400 Gb/sec）
    - Link layer （链路层类型：InfiniBand 还是 Ethernet/RoCE）
```bash
CA 'mlx5_0'
        CA type: MT4125 # 对应 ConnectX-6 Dx 网卡
        Number of ports: 1
        Port 1:
                State: Active # 端口逻辑状态正常、可用
                Physical state: LinkUp # 物理链路已连接（光纤/线缆插好且对端在线）
                Rate: 200 # 链路速率 200 Gb/s ，速率很高，工作正常
                Base lid: 0 # 因为是以太网模式，没有 IB 的 LID 概念
                LMC: 0
                SM lid: 0
                Link layer: Ethernet # 跑的是 RoCE （RDMA over Ethernet），不是原生 InfiniBand
CA 'mlx5_1'
        ...
4CA 'mlx5_2'
        ...
CA 'mlx5_3'
        ...
```
这台机器的 4 块 ConnectX-6 Dx 网卡 全部 Active + LinkUp + 200Gb/s;

`Link layer: Ethernet` 说明它们工作在 RoCE 模式 （用以太网承载 RDMA）, 而不是 InfiniBand + 子网管理器

### 查看 RDMA 设备与内核网络接口的对应关系
既然是 RoCE，就需要知道每个`mlx5_x` 对应哪个以太网口
`rdma link show`: 显示每个 RDMA link 的状态，并列出它绑定的 netdev（内核网卡名）
```bash
0/1: mlx5_0/1: state ACTIVE physical_state LINK_UP netdev eth0 
1/1: mlx5_1/1: state ACTIVE physical_state LINK_UP netdev eth1 
2/1: mlx5_2/1: state ACTIVE physical_state LINK_UP netdev eth2 
3/1: mlx5_3/1: state ACTIVE physical_state LINK_UP netdev eth3 
```
每块 RDMA 设备一一对应一个内核以太网口，`eth0~eth3`;

这就是 RoCE 的典型结构：RDMA 逻辑设备`mlx5_x` 挂在标准以太网口`ethx` 之上，RDMA 流量和普通 TCP/IP 流量共用同一张物理网卡，但走不同的处理路径

### 查看这些 RDMA 网卡是否配置了 IP 地址
`ip -br addr show eth0; ip -br addr show eth1; ip -br addr show eth2; ip -br addr show eth3`: 逐个显示 eth0~eth3 的状态和 IP 地址
```bash
eth0             UP             xx.xxx.xxx.214/26 aaaa:aaaa:aaaa:8::214/64 fe80::ac0:xxxx:xxxx:1b98/64 
eth1             UP             xx.xxx.xxx.215/26 aaaa:aaaa:aaaa:8::215/64 fe80::bace:xxxx:xxxx:c6ee/64 
eth2             UP             xx.xxx.xxx.216/26 aaaa:aaaa:aaaa:8::216/64 fe80::bace:xxxx:xxxx:c6d6/64 
eth3             UP             xx.xxx.xxx.217/26 aaaa:aaaa:aaaa:8::217/64 fe80::bace:xxxx:xxxx:c6e2/64 
```
四个口都`UP` ，且都配了 IPv4 地址(`.214~.217` ，同一个`/26` 子网), 满足了 RoCEv2 通信的基本前提 （RoCEv2 用 IP/UDP 封装）

每行还有一个`fe80::` 开头的地址，那是 链路本地地址（自动生成）

四个口在同一子网，通常意味着这是 多轨（multi-rail）RoCE 组网，用于 GPU/存储高带宽场景，每块卡走独立物理链路以叠加带宽

### RdmaTransport::install 初始化流程
1. initializeRdmaResources  →  开本地网卡硬件(有了 context 才能描述资源)
2. allocateLocalSegmentID   →  基于网卡资源,生成"我的资源清单"
3. startHandshakeDaemon     →  启动一个后台守护,监听别的节点发来的 握手请求
4. updateLocalSegmentDesc   →  最后才对外公布(公布后立刻可能有人来连,所以 daemon 必须先就绪)

### RdmaTransport::submitTransferTask 提交传输任务
遍历每个 request → 查目标段(远端在哪)+ 选本地网卡 → 按`kBlockSize` 切成多个 slice → 每个 slice 填好本地 lkey / 远端 rkey / 地址 → 按网卡分组 → 攒够一批`submitPostSend` 下发硬件。

提交是同步返回的,但传输是异步的 ——`submitPostSend` 只是把请求塞进网卡队列就返回`Status::OK()` ,数据还在飞。所以需要下面的`getTransferStatus` 来轮询完成情况

```text
submitTransfer(装batch)
   → submitTransferTask(选网卡→切片→填key→分组→submitPostSend下发硬件)   [同步返回]
      → 网卡异步搬数据
         → 每片完成回调 Slice::markSuccess/markFailed(原子累加到task)
            → getTransferStatus 轮询 success+failed==slice_count 判定完成
```

# RealClient
## 核心API
- `Put()` —— 写入一个对象(带副本配置`ReplicateConfig` )
- `Get()` —— 按 key 读出数据到`slices`
- `Query()` —— 只查元数据(副本在哪),不搬数据
- `Remove()` —— 删除对象及其所有副本

## TransferSubmitter
- 一次传输,到底走哪条路?
    - `Client::Get/Put` 拿到"数据在哪"(一个`Replica::Descriptor` )之后,并不是无脑丢给 TransferEngine. 因为副本可能在 不同介质 上,最优搬运方式完全不同:
        - 数据就在 本进程内存 → 直接`memcpy` 最快,根本不用走网络
        - 数据在 远端节点内存 → 走 TransferEngine 做 RDMA/TCP
        - 数据在 本地磁盘文件 → 走文件读
        - 数据在 NVMe-oF → 走 SPDK
        ```cpp
        enum class TransferStrategy {
            LOCAL_MEMCPY = 0,     // Local memory copy using memcpy
            TRANSFER_ENGINE = 1,  // Remote transfer using transfer engine
            FILE_READ = 2,        // File read operation
            EMPTY = 3,
            SPDK_NVMF = 4  // Spdk nvmf operation
        };
        ```
    - `TransferSubmitter` 的职责就是:分析这次传输,选出最优策略,然后提交,并返回一个`TransferFuture` 让调用方异步等待结果

## MountSegment
- 为什么需要 mount?
    - Store 是分布式的,一个 client 想让 别的节点能通过 RDMA 读写自己的内存 ,必须做两件事:
        - 让本地的 TransferEngine 知道这块内存(注册成 RDMA 可访问的 memory region,即 MR)
        - 让 Master 知道这块内存(登记到全局,这样 Master 分配对象时才能把它算作可用空间)
    - `MountSegment` 就是 同时完成这两件注册 的地方. Master 管"数据该放哪",TransferEngine 管"数据怎么搬"——mount 一块内存,必须两边都登记.

