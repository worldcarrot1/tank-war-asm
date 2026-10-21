# 网络协议设计（v1，会话 36 落地）

> v0（2026-10-16）为纸面设计；v1 是**已实测**的实现口径（同机双开回环
> `tools/net_loopback_test.py` 全绿 + 无头自检 T46 组 13 项断言）。
> 结构体定义唯一真源在 `inc/game.inc`，本文件是其协议语义说明。
>
> 命中判定规则沿用 v0 注记：反弹弹可击毁任何坦克（含发射者自己），
> 出弹点在炮口（车体边缘外）。

## 基本设定

| 项 | 值 |
|----|----|
| 传输 | UDP，无连接，单 socket（收包按首字节分流） |
| 拓扑 | P2P，两客户端直连，无服务器 |
| 监听端口 | 首选 28888；被占用则**换 socket 重绑临时端口**并用 `getsockname` 回读真实端口（B1，同机双开可行的前提） |
| 发包节奏 | 对局中每逻辑 tick 一个状态包（60Hz）；大厅期 announce 每 30 tick（手动直连模式 15 tick）、HELLO 每 8 tick |
| 同步模型 | 状态同步：只同步「结果状态」+「一次性事件」，不同步「输入」 |
| 协议版本 | NET_PROBE.ver / NET_HS.ver = 1（`NET_VER`） |

## 为什么选状态同步而不是帧同步

沿用 v0 结论，且 v1 实测验证了它：两端各自跑 60Hz 物理，镜像位靠收包覆盖，
子弹/地雷/激光在各自主机权威结算，无需跨机位精确。帧同步在汇编下任何
RNG/浮点分叉都是灾难；状态同步把分叉代价限制在「弹道微差」级别（见文末）。

## 收包分流（单 socket，首字节定类型）

| 首字节 | 包型 | 大小 | 用途 |
|--------|------|------|------|
| `'W'` | NET_PKT | 26B | 对局状态包（位置/朝向/血量/死亡/开火/效果镜像/事件槽） |
| `'T'` | NET_PROBE | 16B | 大厅发现：announce（0）/ reply（1），兼作握手兜底载体 |
| `'H'` | NET_HS | 16B | 大厅握手：HELLO（0）/ START（1），带种子与局数 |
| `'L'` | NET_LSR | 48B | 激光折线：发射端权威算好整条路径广播 |

状态包 magic 为 `dw 'WT'`（小端落内存字节 `'W','T'`，首字节即 `'W'`），
与探测包 sig `"TWNET01"`（首字节 `'T'`）天然分家——v0 文档写的 0x5457 系笔误。

## 状态包格式（NET_PKT，26 字节定长）

```
偏移  大小  字段       说明
0     2    magic      dw 'WT'（见上；本机 LSP 会对调，收端见「容错」节）
2     2    seq        发送序号，循环窗口判新（见「seq 窗口」节）
4     4    tx         本端坦克像素 x（v1 改全 dd，不再截低 16 位）
8     4    ty         本端坦克像素 y
12    1    tdir       航向角量化 0..255：q=(deg*256+128)/360，
                      还原 dir=(q*360+128)>>8，往返误差 ≤1 度
13    1    thp        本端血量
14    1    flags      bit0=本 tick 开火，bit1=本端已死（B6 死亡权威位）
15    1    effOnLow   本端 effOn 低字节镜像（EFF_SHIELD/NITRO/GHOST/WATER/PHANTOM）
16    1    skillId    本端持有未发动技能 id（对端显示/演示用）
17    1    evtKind    事件槽类型 EVT_*（0=无事件）
18    1    evtSeq     事件序号（接收端去重：同值只认一次）
19    1    pad0
20    2    evtX       MINE/ICE=坦克中心格 index（row*COLS+col）/ PICK=0
22    2    evtY       发送者 tag = lobbySeed 低 16 位（自回声识别，见「防回声」）
24    1    evtData    MINE=布雷方槽位 / PICK=道具类型 / LASER=aimSkill id
25    1    pad1
```

### flags / 死亡权威（B6）

- bit0 开火：收端先把 tdir 还原为度数写入镜像 dir，再用 tx/ty/dir 本地
  `SpawnBullet`——开火方向以发包瞬间的量化角为准（v0 语义保留）。
- bit1 死亡：`NetApplyRx` 见到置位 -> 镜像 `alive=0, hp=0`；未置位 -> `alive=1`。
  v0 的无条件 `alive=1` 会把对方尸体「打复活」，回合永不结束，v1 修正。
  死亡结算权在被死者本机（命中判定权威），对端只是镜像显示。

### 事件槽（evtKind/evtSeq/evtX/evtData）

| EVT | 值 | 语义 | 收端动作 |
|-----|----|------|----------|
| EVT_MINE | 1 | 布雷 | 在 evtX 格放雷，owner=PLAYER_PEER，arm=MINE_ARM_TICKS |
| EVT_LASER_PREV | 2 | 激光二段启动 | 镜像 `aimSkill=evtData, aimT=LASER_FIRE_TICKS`（预览对称推演） |
| EVT_LASER_FIRE | 3 | 保留不用 | v1 激光实际走 NET_LSR 折线包 |
| EVT_PICK | 4 | 道具被拾 | 删除本地同型幽灵道具 |
| EVT_ICE | 5 | 冰盾碎冰 | 以 evtX 格为起点 2×2 铺 TILE_ICE（只转换空格） |

事件在**连续 3 个状态包**里重复携带（同 evtSeq），接收端按 evtSeq 去重
（同值只认一次，`lastEvtSeq` 判新）——丢 2 包仍到，第 3 包不重放。

### seq 循环窗口

新包 seq 与已收 peerSeq 之差按 mod 2^16 半圆判定：`(seq - peerSeq) mod 65536 ∈
[1, 32767]` 才采纳。回绕安全（65530 -> 3 照收；倒退的旧包、跨半圆乱包丢弃）。
v0 的无符号 `jbe` 会在回合切换清零 seqSelf 后把真包永久丢弃，v1 删除该清零。

## 探测包（NET_PROBE，16 字节）

```
0     7    sig      "TWNET01"（兼容 v0 大厅广播字串）
7     1    ver      = 1
8     1    ptype    0=announce（我在找对手） 1=reply（单播回对方临时端口）
9     1    start    发送端 myStart 标志（握手状态搭载，见「LSP 容错」）
10    2    port     发送端真实监听端口（网络序）
12    4    cookie   发送端 lobbySeed（自回声过滤 + 对端种子来源）
```

周期：局域网模式每 30 tick 向 `255.255.255.255:28888` **广播**一份、再向
`127.0.0.1:28888` **环回**补发一份（广播不过环，这份是同机双开互发现的钥匙）；
手动直连模式每 15 tick 向目标 `ip:port` 单播。收端拿到 announce 后：记
peerKnown、以 fromAddr + 载荷 port 字段回填对端真实地址、**单播一份 reply 回它**
（临时端口一方靠 reply 反向发现——固定端口一方永远收得到 announce）。

## 握手包（NET_HS，16 字节）

```
0     1    magic0   'H'（分流首字节；v0 计划的 dw 'HS' 双字节 magic 作废，
                      本机 LSP 把 'H' 改写成 0x44，故握手为单字节首标）
1     1    htype    0=HELLO（我在线，附种子） 1=START（我按下了开始）
2     1    ver      = 1
3     1    pad
4     4    seed     本机 lobbySeed
8     4    rounds   期望局数（收端取小）
12    4    cookie   对端种子观测值（v1 不校验）
```

peerKnown 后每 8 tick 发 HELLO，已按开始则同带一份 START。**但**由于 LSP 会
损坏 'H' 包，握手状态同时搭载在探测包（cookie=对端种子、start=已按开始）上，
HELLO/START 只是快路径冗余。

## 开局握手时序（B2 修复核心）

1. 双方进大厅：`NetEnterLan` -> `lobbySeed = GetTickCount`（0 兜底 1）。
2. 互相发现（announce/reply 双向），各自 gotHello=1、hsPeerSeed=对端 cookie。
3. 双方各按 Enter -> myStart + gotStart **齐**才 `NetCanStart`（修 v0 单边 Enter 开局）。
4. `NetEnterMatch`：`netSharedSeed = lobbySeed xor hsPeerSeed` -> `SetNetSeed`
   （写 rngMatch；为 0 兜底 0x09E3779B9）；maxRounds 取小；`mapIndex` 与出生点
   从共享流抽取 -> **两端同图同出生点袋**。
5. 主从定序：`netRole = (lobbySeed > hsPeerSeed) ? 1 : 0`；role 1 一方出生点
   槽位交换（slot0↔3、slot1↔0），保证双方分踞半场两端、不会重叠出生。
6. rngMatch 共享流同时驱动**道具生成**（SpawnPickup 选位选型走共享流，
   两端同位同型；被拾走靠 EVT_PICK 消幽灵）。滑行随机仍走本机 rngState
   （A 档技能各自收敛，不入共享流，selftest 传统 md5 中性）。

## 掉线检测与自愈（B4）

对局中 `rxSeen && netTick - lastRxTick > NET_TIMEOUT(120 tick = 2s)` ->
`netLost=1`，UI 显示「连接丢失」覆盖层并冻结输入推进；**照发照收**，
收到任意一个合法包即 `netLost=0` 自愈（对方回来就续上，无需重开大厅）。
`peerKnown` 不因超时清零。暂停期间 NetFlush 停摆属设计内（掉线判定一并冻结）。

## 自回声防御（同机双开 + LSP 单播自回的实战产物）

同一 socket 绑 INADDR_ANY 会把自己 sendto 的包 recvfrom 回来（本机 LSP 实测
单播必自回声）。三道过滤，全部在 seq 窗口与镜像写入**之前**：

| 包型 | 判据 | 备注 |
|------|------|------|
| NET_PKT | `evtY == lobbySeed 低 16` 即丢 | lobbySeed==0 时旁路（自检可直喂包测试；联机时恒非 0） |
| NET_LSR | `seq == lastSentLsr` 即丢 | 记本端最后发出的折线 seq |
| NET_PROBE / NET_HS | `cookie == lobbySeed` 即丢 | 自己 announce/HELLO 的回声 |

残余风险：tag 只 16 位，与**对端**恰好同低 16 位的概率 1/65536，v1 接受。

## 本机链路（LSP）三处怪癖与容错

会话 36 在开发机 Winsock LSP 链路上实测到、代码已针对性处理（换机器不触发、
但不容错就复现「搜索中/永久掉线」级故障）：

1. **状态包 magic 前两字节被对调**落线：收端检测 `'T','W'` 形态且排除探测
   sig（`'T','W','N'` 开头）后原地换回再走正常解析。
2. **'H' 单字节被改写成 0x44**：握手放弃 dw 'HS' 双字节 magic 方案，
   状态冗余搭载到 NET_PROBE（cookie/start 字段），'H' 包仅作快路径。
3. **广播包源端口随机化**：回包不能打 fromAddr 的端口，对端真实监听口
   一律取 announce 载荷里的 `port` 字段。

## 激光折线包（NET_LSR，48 字节）——发射端权威路径

```
0     1    magic0   'L'
1     1    npts     折点数 2..10（起点+反弹点+终点）
2     2    len      路径总长 px（laserLen，接收端按同一传播节奏起爆）
4     2    seq      = 事件序号（去重 + 防回声）
6     1    skill    SK_LASER / SK_REFLASER（伤害规则标识，保留）
7     1    pad
8     40   px       laserX/laserY 交替 dw（像素，<=992/608），共 20 个 dw
```

发射端（车主本机）预览结束时算好整条反弹折线广播；收端照抄路径几何起爆，
用本地镜像位起束、清 aimSkill。**不做**两端各自推演反弹（弹道微差会让
反弹点分叉）。同 seq 去重、npts 越界（<2 或 >MAX_LASER_PTS）整包丢弃。

## 命中判定（权威约定，沿用 v0）

子弹命中谁，由**被击中一方**本地判定：扣血后 hp 随状态包广播。
好处：不需要命中事件包；代价：被击中方掉线时对方打不中它——可接受。

## 手输直连（B8，跨网入口）

大厅底部编辑行，放行 `0-9 . :` 退格回车；回车/点连接 -> `ParseIp` ->
`NetSetManual`（manualMode=1，announce 从广播切为定向单播）。

`ParseIp` 语法（纯整数运算，无 CRT；网络序 u32：第 k 段落第 k 字节）：

- `a.b.c.d` -> 端口默认 28888；`a.b.c.d:p` -> p∈[1,65535]（`:0` 拒收）
- 段值 >255 拒；空尾段（`1.2.3.`）拒；端口 >65535 拒；尾随空格/制表符容忍
- 例：`127.0.0.1` -> 0x0100007F + 28888

连**临时端口**的对端也可行：我方 announce 打开其入站、其 reply 打开我方入站，
等效最简 NAT 打洞（对同一公网出口/端口映射拓扑足够；对称 NAT 见下）。

跨网对战实操（ZeroTier/SakuraFrp 组网、防火墙放行、对称 NAT 判定）见
[ONLINE_PLAY.md](ONLINE_PLAY.md)。游戏自身不做 STUN 打洞，列入 M3.5。

## 技能同步分档（v1 口径）

| 档 | 技能 | 做法 |
|----|------|------|
| A·镜像 | 冰盾/穿墙/氮气/驭水 | effOn+skillId 随状态包镜像；效果物理（水带矩形等）由两端用本车位+镜像位**对称**计算，天然收敛；盾挡弹在车主机结算 |
| A·事件 | 激光（预览+折线包）/ 地雷 / 道具 | EVT_LASER_PREV + NET_LSR / EVT_MINE / 共享流同位同型 + EVT_PICK |
| **B·v1 禁用** | 换位术 SK_SWAP、定格术 SK_PHANTOM | netMode 拾取池剔除（SpawnPickup 取 1..7，7→8 重映射，永不发 {7,9}）+ TryUseSkill 双保险早退。原因：DoSwap 同时挪两车/虚影判弹各自演算，两端镜像差会**永久发散**。要联机可用需「发动方权威+双坐标包」，属 M3 事件层 |

## 已知分歧（状态同步固有，v1 接受）

- 弹道微差：双方 60Hz 各自演算 + tdir 量化 ≤1 度，几秒内子弹位置有像素级差；
- 砖块啃噬：子弹打砖各自结算，同一格两边子块可能不同（视觉级）；
- 滑行时长：本机 rngState 独立，不影响对方视角位置判定收敛。
M3 计划的事件重同步（关键分歧点强覆盖）暂不需要——回环实测无肉眼可见分叉。

## 诊断转储（netloop 验收对账格式）

`tankwar.exe netloop` 自动进大厅+到位自动开局+开转储；文件
`netdump_host.txt`（固定端口方）/ `netdump_guest.txt`：

```
H <isFixed> <lobbySeed> <port> <pid>          —— 开文件即写
B <hello> <start> <myStart> <peerKnown> <tick> —— 大厅期每 16 tick
G <sharedSeed> <maxRounds> <mapIndex>          —— NetEnterMatch 写（同种子证据）
T <tick> <rx> <lost> <pk> <x0> <y0> <mx> <my> <a0> <a1> <hp1> <sk1> <ef1>
  <aim1> <b0> <b1> <m0> <m1> <pick> <rngm>     —— 对局每 tick 一行
```

T 行：rx=rxSeen 累计收包数、lost/pk=netLost/peerKnown；0=本端 1/mx my=镜像；
hp1/sk1/ef1/aim1=镜像血量/技能/效果/瞄准；b=按 owner 弹计数、m=雷计数、
pick=当前道具型、rngm=rngMatch 共享流值（两端同行应相等）。

## 联机建立流程（v1 实现版，替代 v0 四步）

1. 双方启动（bind 28888 或退避临时口），菜单进「联机大厅」，或大厅内手输 IP 直连
2. announce/reply 互发现（LAN 广播+环回；跨网手动单播）
3. HELLO 换种子 -> 双方按 Enter -> 共享种子开局（同图同出生点）
4. 对局：每 tick 状态包 + 事件槽 + 激光折线包
5. 2s 无包 -> netLost 覆盖层；来一包即自愈；Esc 回大厅可重连
