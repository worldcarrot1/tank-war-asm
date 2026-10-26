; ============================================================
; game.inc —— 公共常量与结构体定义（v2 对战版）
; 所有模块共享的定义集中在这里，改协议/平衡性只动这个文件。
; 对应设计文档 docs/GAME_DESIGN.md v2（纯对战射击）。
; 注意：变量（mapData / tanks / bullets 等）统一定义在 game.asm，
; 其他模块用 extern 声明引用，本文件只放常量与结构体，避免重复定义。
; ============================================================

; ---- 窗口与渲染 ----
HUD_H       equ 48                  ; 底部信息条高度（像素）：上行玩家标识、下行积分板（会话 23 拆分）
MAP_W       equ 992                 ; 地图宽度（31 列 x 32，奇数宽保证镜像对称）
MAP_H       equ 608                 ; 地图高度（19 行 x 32，奇数行保证单行底边界）
WND_W       equ MAP_W               ; 窗口客户区宽度
WND_H       equ MAP_H + HUD_H       ; 窗口客户区高度（地图 + 底部信息条）
CELL        equ 32                  ; 地图格子边长（像素）

COLS        equ MAP_W / CELL        ; 31 列
ROWS        equ MAP_H / CELL        ; 20 行

; ---- 回合节奏 ----
ROUND_JUDGE_TICKS equ 300          ; 剩最后 1 辆后定格 5s 再判分
ROUNDS_MIN   equ 11                ; 比赛局数下限（奇数）
ROUNDS_MAX   equ 51                ; 比赛局数上限（奇数）

; ---- 界面状态（ui.asm）----
ST_MENU     equ 0                   ; 主菜单
ST_NUMSEL   equ 1                   ; 人数选择
ST_SET      equ 2                   ; 按键设置
ST_LAN      equ 3                   ; 联机大厅
ST_PLAY     equ 4                   ; 对局中
ST_SKILL    equ 5                   ; 技能说明页
ST_DEMO     equ 6                   ; 玩法演示页
ST_ACHG     equ 7                   ; 会话40：成就图鉴页（翻页翻阅）

; ---- 会话40：成就系统（achv.asm；表序即图鉴序，按稀有度分组）----
ACH_COUNT   equ 24                  ; 成就总数（会话41 增"追风者"=24；改表后同步）
ACH_ROW_PG  equ 6                   ; 图鉴每页行数
RAR_COM     equ 0                   ; 稀有度：普通
RAR_RARE    equ 1                   ; 稀有度：稀有
RAR_EPIC    equ 2                   ; 稀有度：史诗
RAR_LEG     equ 3                   ; 稀有度：传奇
; 事件类型（AchvEvent 第一参）
AK_SHOT     equ 0                   ; 开火一发
AK_KILL     equ 1                   ; 击杀（value=武器 WP_*）
AK_PICKUP   equ 2                   ; 拾取道具
AK_SKILL    equ 3                   ; 技能发动（value=SK_  id）
AK_BLOCK    equ 4                   ; 冰盾挡弹一次
AK_HURT     equ 5                   ; 实际扣血（value=扣后 hp，0=致死）
AK_SWAP     equ 6                   ; 换位成交
AK_LASER    equ 7                   ; 激光发射（二段起爆）
AK_WIN      equ 8                   ; 夺冠（value=亚军分；mode 由 netMode/botMask 现推）
AK_MATCHST  equ 9                   ; 新局开始（清场，不经 actor 闸）
; 内部伪 kind（仅表内匹配用）
AK_MKILL    equ 10                  ; 单场击杀峰值（prog=best，解锁在 bump 内判 goal）
AK_REVENGE  equ 11                  ; 以牙还牙：击杀上次带走自己的对手（瞬时）
                                    ;  （会话40 替换"千钧一发/1血扛伤"——一命制下
                                    ;   任何命中即死，value==1 分支永不可达）
AK_FLAWLESS equ 12                  ; 零受伤害夺冠（瞬时）
AK_SHUTOUT  equ 13                  ; 对手零分（瞬时）
; AK_KILL param / value 语义
WP_ANY      equ -1                  ; 武器通配
WP_BULLET   equ 0
WP_MINE     equ 1
WP_LASER    equ 2
; AK_WIN param 语义
WM_ANY      equ 0
WM_NET      equ 1
WM_BOT      equ 2

; 成就定义表项（achv.asm 的 achvDefs；ui.asm 图鉴渲染共用此形状）
ACHDEF STRUCT
    kind    dd ?                     ; AK_*（AK_MKILL/LOWHP/FLAWLESS/SHUTOUT 为内部伪 kind）
    param   dd ?                     ; 匹配参数：-1 通配 / SK_ id / WP_* / WM_*；其余 0
    goal    dd ?                     ; 达成线
    rarity  dd ?                     ; RAR_*
    pNameEn dd ?                     ; 英文题名
    pNameCn dd ?                     ; 中文题名（UTF-16 dw 串）
    pDescEn dd ?
    pDescCn dd ?
ACHDEF ENDS
ACH_SIZE    equ SIZEOF ACHDEF         ; 8 dd = 32B
ACH_PAGES   equ (ACH_COUNT + ACH_ROW_PG - 1) / ACH_ROW_PG   ; 图鉴页数（24/6 -> 4 整页）

; ---- 游戏节奏 ----
TICK_MS     equ 16                  ; 约 60 tick/秒

; ---- 地图格子类型（字符画 -> 运行时编码）----
TILE_EMPTY  equ 0                   ; '.'
TILE_STEEL  equ 1                   ; '#'  子弹反弹
TILE_BRICK  equ 2                   ; 'b'  清子块后反弹，整格空后穿过
TILE_WATER  equ 3                   ; '~'  挡坦克，子弹穿过
TILE_ICE    equ 4                   ; '-'  坦克滑行，子弹穿过
TILE_DIRT   equ 5                   ; 'd'  泥土：坦克减速，子弹穿过
ARENA_COUNT equ 51                  ; 内置对战图 ARENA1..51（每局随机一张；
                                    ;  ARENA21 起会话 30/31 新增，墙:地形≈10:3；
                                    ;  51 与 ROUNDS_MAX 对齐，打满恰好一轮一图）

; ---- 细墙挡板 ----
; 墙的视觉与碰撞都不再是整格：每个墙格渲染/判定为
; 「中心 WALL_THICK x WALL_THICK 点 + 朝相邻墙格的连接条」，
; 相邻墙格连成一条细挡板线（Tank Trouble 风格）。
; 渲染（gfx.asm）与碰撞（game.asm WallRects/WallRectsHit）共用同一几何。
WALL_THICK  equ 8                   ; 挡板厚度（像素），格内居中

; ---- 朝向（会话 19 起：整数航向角，不再离散 4 方向）----
; dir 语义 = 航向角 0..359：0=+x(右)，屏幕 y 向下，顺时针为正
; 90=下, 180=左, 270=上。常数名沿用，值变为姿态角（供渲染/演示直接用）。
DIR_RIGHT   equ 0
DIR_DOWN    equ 90
DIR_LEFT    equ 180
DIR_UP      equ 270
TURN_SPEED  equ 2                   ; 每 tick 转向 2 度（左键减、右键加）。
                                    ;  会话 32：4→2，用户点名"太灵敏不好
                                    ;  射击"（240°/s→120°/s）
ANGLE_SPAN  equ 360
TRIG_SHIFT  equ 10                  ; cosTBL/sinTBL 标度 x1024，右移 10（必须 sar）
FIX_SHIFT   equ 16                  ; 子弹/坦克位移 16.16 定点
FIX_ONE     equ 65536
FIX_TBL64   equ 64                  ; 65536/1024：tbl 值 * 像素速度 * 64 = 16.16 速度

; ---- 坦克 ----
MAX_PLAYERS equ 4                   ; slot 槽位（M1 只激活 0/1）
KEY_PER     equ 6                   ; 每玩家键位数：0前进1后退2左转3右转4开火5技能
TANK_SIZE   equ 25                  ; 坦克碰撞/绘制边长（21 的 1.2 倍）
TANK_SPEED  equ 2                   ; 每 tick 基础移动像素（偶 tick）（会话 23 降速）
TANK_SPEED_HI equ 3                 ; 奇 tick（2/3 交替 = 平均 2.5，高于弹速 2）
DIRT_SPEED  equ 1                   ; 泥土上每 tick 移动像素（半速以下的"陷住感"）
NITRO_BONUS equ 1                   ; 燃油加速叠加像素/tick（2.5->3.5，约 +40%）
TANK_HP     equ 1                   ; 一滴血（命中即淘汰）
LIVES_INIT  equ 1                   ; 每辆坦克初始命数（会话 23：一命制，死亡即淘汰到回合结束）
RESPAWN_TICKS equ 90                ; 阵亡后 1.5s 重生
SPAWN_PROT_TICKS equ 150            ; 重生保护 2.5s（免伤+闪烁）
FIRE_CD     equ 20                  ; 开火冷却 tick（§3）
PLAYER_SELF equ 0
PLAYER_PEER equ 1
PLAYER_P2   equ 1                   ; 本地第二坦克（对练用）

; ---- 会话38：黑色超强人机（挑战模式）----
; 菜单/命令行进入的挑战局：槽位1由 AI 接管，黑车身、快跑快转快射、3 条命。
; 会话38 引入、会话39 泛化：挑战局/对战混编时槽位 i 由 AI 接管（botMask 位 i），
; 黑车身、快跑快转快射。所有钩子一律 botMask 命中该槽才走，
; botMask=0 时全局行为与旧版逐字节一致（回归锁）。
BOT_SLOT    equ 1                   ; 人机占用槽位（=PLAYER_PEER）
BOT_LIVES   equ 1                   ; 会话42：血量与玩家相等（原 3 命，用户要求拉平）
BOT_SPEED   equ 2                   ; 偶 tick 速度（与玩家同，公平起步）
BOT_SPEED_HI equ 4                  ; 奇 tick 速度（玩家 3）→ 人机均速 3.0 > 玩家 2.5
BOT_TURN    equ 4                   ; 转向度/tick（玩家 2）→ 对准目标快一倍
BOT_FIRE_CD equ 12                  ; 开火冷却 tick（玩家 20）

; ---- 技能系统 ----
; 拾取物每 10s 随机生成一个（非水/非墙格），坦克中心格拾取，
; 再按各自"技能键"发动；连续拾取覆盖前一个。
SKILL_NONE      equ 0
SK_ICE_SHIELD   equ 1               ; 冰盾：挡一次伤害 + 周围 2x2 冰面
SK_LASER        equ 2               ; 激光炮：一段持续虚线预览，再按 1.3s 后穿墙直线激光
SK_REFLASER     equ 3               ; 反射激光：持续预览反弹路径，再按 1.3s 后全路径伤害
SK_GHOST        equ 4               ; 穿墙术：4s 或 3 次穿墙
SK_MINE         equ 5               ; 地雷：隐藏雷 2s 后生效（含自己）
SK_NITRO        equ 6               ; 燃油加速：50% 加速（与地形叠加）
SK_SWAP         equ 7               ; 换位术：发射子弹后可与之换位
SK_WATER        equ 8               ; 驭水术：可在水域行走
SK_PHANTOM      equ 9               ; 定格术：原地虚影 x2，实像免伤，6s
SKILL_COUNT     equ 9
PICKUP_PERIOD   equ 600             ; 10s @ 60tick
PICKUP_SIZE     equ 18              ; 拾取物边长（像素）
LASER_FIRE_TICKS equ 42             ; 二段再按后 0.7s 发射（会话 22 两段式；
                                    ; 会话 30：1.3s→0.7s，用户点名缩短）
LASER_STEP_PX   equ 300             ; 会话 30：光束像真光一样有传播速度
                                    ; （px/tick，穿满 992px 宽图约 3~4 tick，
                                    ; 极短但非零；伤害随束头推进逐 tick 结算）
SHIELD_TICKS    equ 420             ; 冰盾 7s
GHOST_TICKS     equ 240             ; 穿墙 4s
GHOST_USES      equ 3               ; 穿墙 3 次
MINE_ARM_TICKS  equ 120             ; 地雷 2s 生效
NITRO_TICKS     equ 300             ; 燃油加速 5s
WATER_TICKS     equ 360             ; 驭水 6s
PHANTOM_TICKS   equ 360             ; 虚影 6s
PHANTOM_USES    equ 2               ; 虚影可用 2 次
MAX_MINES       equ 16
MAX_LASER_PTS   equ 10              ; 起点 + 7 反弹折点 + 终点 = 9（留 1 富余）
LASER_BOUNCE_MAX equ 7              ; 反射激光最多反射 7 次
EFF_SHIELD      equ 1
EFF_NITRO       equ 2
EFF_GHOST       equ 4
EFF_WATER       equ 8
EFF_PHANTOM     equ 16

; ---- 冰面滑行 ----
ICE_SLIDE_MIN equ 8                 ; 滑行 tick 下限（8*2.5=20px 起步，可感；会话 23 随降速上调）
ICE_SLIDE_RNG equ 10                ; 8 + rand%10 -> 8..17 tick（20..42px）

; ---- 子弹（§3）----
MAX_BULLETS     equ 56              ; 全场弹池
MAX_PER_TANK    equ 10              ; 每辆坦克同屏上限
BULLET_FP       equ 176947            ; 弹速 2.7 px/tick 的 16.16 定点（会话 24：
                                    ;  比坦克均速 2.5 略快。非整数 -> 不再走
                                    ;  BULLET_SPEED*64 整数路径，改为 tbl*BULLET_FP>>10）
BULLET_SIZE_PX  equ 8               ; 弹体 8x8
BULLET_LIFE     equ 600             ; 存活 600 tick（10 秒）自动消失
BULLET_MAX_BOUNCE equ 10            ; 反弹 >=10 次消失

; ---- 网络协议 v1（会话36）----
; 单 UDP socket，收包按首字节分流：'W'=状态包 NET_PKT / 'T'=探测 NET_PROBE /
; 'H'=握手 NET_HS / 'L'=激光折线 NET_LSR。
; 注：状态包 magic 为 dw 'WT'（小端落内存字节 'W','T'），首字节即 'W'，
;     与探测包 sig "TWNET01..."（首字节 'T'）天然分家；PROTOCOL.md 已同步 v1。
NET_PKT STRUCT
    magic     dw ?                    ; dw 'WT'，内存首字节 'W'
    seq       dw ?                    ; 包序号：循环窗口判新（回绕安全）
    tx        dd ?                    ; 本端坦克像素 x（v1 改全 dd，不再截高字）
    ty        dd ?                    ; 本端坦克像素 y
    tdir      db ?                    ; 航向角量化 0..255（q=(deg*256+128)/360）
    thp       db ?                    ; 本端血量
    flags     db ?                    ; bit0 本 tick 开火, bit1 本端已死（B6）
    effOnLow  db ?                    ; 本端 effOn 低字节镜像（EFF_*）
    skillId   db ?                    ; 本端持有未发动技能 id（显示用）
    evtKind   db ?                    ; 事件槽类型 EVT_*（0=无）
    evtSeq    db ?                    ; 事件序号（接收端去重：同值只认一次）
    pad0      db ?
    evtX      dw ?                    ; MINE/ICE=坦克中心格 index / PICK=0
    evtY      dw ?                    ; 会话36：改作发送者 tag = lobbySeed 低 16
                                      ;  （自回声识别；原"保留0"语义作废，
                                      ;   收侧不读、事件生产者 py 恒 0）
    evtData   db ?                    ; MINE=布雷方槽位 / PICK=道具类型 / LASER=aimSkill id
    pad1      db ?
NET_PKT ENDS                          ; 26B（成员按自然对齐恰落此偏移）

NET_PKT_SIZE equ SIZEOF NET_PKT
NET_PORT     equ 28888                ; 首选监听端口（被占则退临时端口，B1）

; ---- 探测包（大厅发现/反向发现，16B）----
NET_PROBE STRUCT
    sig     db 'TWNET01'             ; 7 字节标识（兼容 v0 大厅广播字串）
    ver     db ?                     ; 协议版本 = 1
    ptype   db ?                     ; 0=announce（我在找对手） 1=reply（回给临时端口）
    start   db ?                     ; 会话36：发送端 myStart 标志（announce 搭载握手）
    port    dw ?                     ; 发送端真实端口（网络序；固定 28888 或临时）
    cookie  dd ?                     ; 发送端 lobbySeed（=GetTickCount，自回声过滤）
NET_PROBE ENDS

; ---- 激光折线包（会话36：发射端权威算好路径广播，接收端照抄起爆）----
NET_LSR STRUCT
    magic0  db 'L'                   ; 分流首字节
    npts    db ?                     ; 折点数 2..10
    len     dw ?                     ; 路径总长 px（laserLen，传播节奏用）
    seq     dw ?                     ; 事件序号（去重）
    skill   db ?                     ; SK_LASER / SK_REFLASER（保留：伤害规则标识）
    pad     db ?
    px      dw 20 dup (?)            ; laserX/laserY 交替（像素，<=992/608）
NET_LSR ENDS                         ; 48B
NET_LSR_SIZE equ SIZEOF NET_LSR

; ---- 握手包（开局同步，16B）----
NET_HS STRUCT
    magic0  db 'H'                   ; 分流首字节
    htype   db ?                     ; 0=HELLO（我在线，附种子） 1=START（我按下开始）
    ver     db ?
    pad     db ?
    seed    dd ?                     ; 本机 lobbySeed（双方 xor 成 netSharedSeed）
    rounds  dd ?                     ; 期望局数（取小）
    cookie  dd ?                     ; 对端 cookie（仅 reply 校验用，可 0）
NET_HS ENDS

; ---- 会话37 M3.5：中继服务器（非局域网联机）----
; 拓扑：双方都只与公网中继服务器单播；服务器按房间把对端报文
; 逐字节原样转发（'T'/'H'/'W'/'L'/'P' 全量透传，协议零改动）。
NET_SRV_PORT equ 28900               ; 中继服务器默认监听端口
NET_JOIN STRUCT                      ; 'J' 加入/应答包 16B（服务器识别，不转发）
    magic0  db 'J'
    jtype   db ?                     ; 0=join（客户端发） 1=ack（服务器回）
    ver     db ?                     ; = NET_VER
    jst     db ?                     ; ack: 0=等待队友 1=已配对 2=房间已满
    room    dd ?                     ; 房间号 1..999999
    cookie  dd ?                     ; join: 发送端 lobbySeed；ack: 0
    pad     dd ?
NET_JOIN ENDS
NET_JOIN_SIZE equ SIZEOF NET_JOIN
JOIN_ST_WAIT  equ 0
JOIN_ST_PAIR  equ 1
JOIN_ST_FULL  equ 2

; ---- RTT 探测包（'P'，会话37：延迟显示，双方直回，服务器仅转发）----
NET_PING STRUCT                      ; 16B
    magic0  db 'P'
    pingRpl db ?                     ; 0=ping 请求 1=pong 应答（原样回 ts）
    pad0    db ?
    pad1    db ?
    ts      dd ?                     ; 发送时刻 GetTickCount（pong 回显请求 ts）
    cookie  dd ?                     ; 发送端 lobbySeed（pong 装应答方种子）
    pad     dd ?
NET_PING ENDS
NET_PING_SIZE equ SIZEOF NET_PING

; ---- 会话51 STUN 步A：公网端点反射包（'S'，服务器->双方，服务器不转发）----
; 服务器在配对房间每次 'J' ack 后，把"另一名成员的观测源地址"反射给双方：
; 双方由此互见公网出口 addr:port（大厅显示；步B 直连升级的原料）。纯增量，
; 旧客户端分发器不认 'S' 自然忽略，协议版本字段保持 1。
; STRUCT 1 = pack(1)：room@10 非 4 对齐，禁用默认对齐否则汇编器插 pad 变 20B。
NET_STUN STRUCT 1
    magic0  db 'S'
    stVer   db ?                     ; = NET_VER
    rsv0    db ?                     ; 预留 0（将来子类型）
    rsv1    db ?
    peerIp  dd ?                     ; 对端观测 IP 裸 4 字节（网络序，可直接进 sockaddr/IpToStr）
    peerPort dw ?                    ; 对端观测端口 裸 2 字节（网络序 = sin_port 原字节）
    room    dd ?                     ; 所在房间（LE，与 'J' ack 同口径）
    cookie  dd ?                     ; 回显收件人最近一次 JOIN cookie（=其 lobbySeed，防伪证）
NET_STUN ENDS
NET_STUN_SIZE equ SIZEOF NET_STUN    ; =18

; ---- 协议常量 ----
EVT_NONE        equ 0
EVT_MINE        equ 1                 ; 布雷（evtX=中心格 index）
EVT_LASER_PREV  equ 2                 ; 激光二段启动（evtData=aimSkill）
EVT_LASER_FIRE  equ 3                 ; 保留：v1 走 NET_LSR 折线包，不占事件槽
EVT_PICK        equ 4                 ; 道具被拾（evtData=类型）
EVT_ICE         equ 5                 ; 冰盾碎冰（evtX=坦克中心格 index）
PKT_FIRE        equ 1                 ; flags bit0
PKT_DEAD        equ 2                 ; flags bit1
NET_ANN_TICKS   equ 30                ; 大厅 announce 周期 tick
NET_HS_TICKS    equ 8                 ; 大厅 HELLO/START 重发周期 tick
NET_TIMEOUT     equ 120               ; 收包超时 2s = 掉线（PROTOCOL 既有规则）

; ============================================================
; 结构体定义
; ============================================================

; 坦克状态（一个玩家一条，tanks[MAX_PLAYERS]）
TANK STRUCT
    x       dd ?                     ; 左上角像素坐标
    y       dd ?
    subpxX  dd ?                     ; 位移 16.16 余数（恒 0..65535，撞墙/停车清零）
    subpxY dd ?
    dir     dd ?                     ; 航向角 0..359（0右 90下 180左 270上，CW+）
    hp      dd ?
    alive   dd ?                     ; 0=死亡 1=存活
    fireCd  dd ?                     ; 开火冷却剩余 tick
    slide   dd ?                     ; 冰面滑行剩余 tick（0=无）
    sdir    dd ?                     ; 滑行冻结航向角（滑行期间 dir 可继续变）
    score   dd ?                     ; 本场得分（回合制积分）
    skill   dd ?                     ; 持有未发动的技能 id（SKILL_NONE=无）
    effOn   dd ?                     ; 激活效果位掩码 EFF_*
    shieldT dd ?                     ; 冰盾剩余 tick
    effT    dd ?                     ; 激活效果剩余 tick（加速/穿墙/驭水共用）
    wallPass dd ?                    ; 穿墙剩余次数
    swapBul dd ?                     ; 换位绑定子弹池索引（-1=无）
    aimT    dd ?                     ; 激光瞄准剩余 tick（0=无）
    aimSkill dd ?                    ; 瞄准中的技能 id
    lastCell dd ?                    ; 上 tick 中心格 index（穿墙计数）
    phantomX dd ?                    ; 虚影左上角 x（定格术）
    phantomY dd ?                    ; 虚影左上角 y
    phantomUses dd ?                 ; 虚影剩余次数（0..2）
    lives   dd ?                     ; 剩余命数（0=淘汰）
    respawnT dd ?                    ; 重生倒计时 tick（0=无）
    protT   dd ?                     ; 重生保护剩余 tick（免伤+闪烁）
    spawnX  dd ?                     ; 本回合出生点（重生用）
    spawnY  dd ?
    spawnDir dd ?                    ; 本回合出生航向角
TANK ENDS

; 子弹（全场固定池 bullets[MAX_BULLETS]）
; 反弹物理：存速度分量 vx/vy，反弹 = 对应分量取反（零乘除）
; 会话 19：vx/vy 改 16.16 有符号定点（任意角 |v| 恒 BULLET_FP 定点值精确），
; 每 tick subpx 进位产生整数步长；SIZEOF 32->44，引用处必须用 SIZEOF BULLET
; （game.asm 原 3 处 shl 5 已改 imul）。
BULLET STRUCT
    x       dd ?                     ; 弹体 8x8 左上角像素
    y       dd ?
    vx      dd ?                     ; 16.16 定点 x 速度（px/tick，可负）
    vy      dd ?                     ; 16.16 定点 y 速度
    owner   dd ?                     ; 所属坦克槽位
    active  dd ?                     ; 0=空闲槽位 1=在飞
    bounces dd ?                     ; 已反弹次数
    age     dd ?                     ; 已存活 tick 数
    subpxX  dd ?                     ; x 余数累加器（恒 0..65535）
    subpxY  dd ?
    fireAng dd ?                     ; 发射角 0..359（换位/调试用，不渲染）
BULLET ENDS
