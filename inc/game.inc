; ============================================================
; game.inc —— 公共常量与结构体定义（v2 对战版）
; 所有模块共享的定义集中在这里，改协议/平衡性只动这个文件。
; 对应设计文档 docs/GAME_DESIGN.md v2（纯对战射击）。
; 注意：变量（mapData / tanks / bullets 等）统一定义在 game.asm，
; 其他模块用 extern 声明引用，本文件只放常量与结构体，避免重复定义。
; ============================================================

; ---- 窗口与渲染 ----
HUD_H       equ 32                  ; 顶部计分条高度（像素）
MAP_W       equ 992                 ; 地图宽度（31 列 x 32，奇数宽保证镜像对称）
MAP_H       equ 608                 ; 地图高度（19 行 x 32，奇数行保证单行底边界）
WND_W       equ MAP_W               ; 窗口客户区宽度
WND_H       equ MAP_H + HUD_H       ; 窗口客户区高度（地图 + 计分条）
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

; ---- 游戏节奏 ----
TICK_MS     equ 16                  ; 约 60 tick/秒

; ---- 地图格子类型（字符画 -> 运行时编码）----
TILE_EMPTY  equ 0                   ; '.'
TILE_STEEL  equ 1                   ; '#'  子弹反弹
TILE_BRICK  equ 2                   ; 'b'  清子块后反弹，整格空后穿过
TILE_WATER  equ 3                   ; '~'  挡坦克，子弹穿过
TILE_ICE    equ 4                   ; '-'  坦克滑行，子弹穿过
TILE_DIRT   equ 5                   ; 'd'  泥土：坦克减速，子弹穿过
ARENA_COUNT equ 20                  ; 内置对战图 ARENA1..20（每局随机一张）

; ---- 细墙挡板 ----
; 墙的视觉与碰撞都不再是整格：每个墙格渲染/判定为
; 「中心 WALL_THICK x WALL_THICK 点 + 朝相邻墙格的连接条」，
; 相邻墙格连成一条细挡板线（Tank Trouble 风格）。
; 渲染（gfx.asm）与碰撞（game.asm WallRects/WallRectsHit）共用同一几何。
WALL_THICK  equ 8                   ; 挡板厚度（像素），格内居中

; ---- 方向 ----
DIR_UP      equ 0
DIR_RIGHT   equ 1
DIR_DOWN    equ 2
DIR_LEFT    equ 3

; ---- 坦克 ----
MAX_PLAYERS equ 4                   ; slot 槽位（M1 只激活 0/1）
KEY_PER     equ 6                   ; 每玩家键位数：0上1下2左3右4开火5技能
TANK_SIZE   equ 25                  ; 坦克碰撞/绘制边长（21 的 1.2 倍）
TANK_SPEED  equ 4                   ; 每 tick 基础移动像素（偶 tick）
TANK_SPEED_HI equ 5                 ; 奇 tick（4/5 交替 = 平均 4.5，比子弹慢 25%）
DIRT_SPEED  equ 2                   ; 泥土上每 tick 移动像素（减速）
TANK_HP     equ 3
LIVES_INIT  equ 3                   ; 每辆坦克初始命数
RESPAWN_TICKS equ 90                ; 阵亡后 1.5s 重生
SPAWN_PROT_TICKS equ 150            ; 重生保护 2.5s（免伤+闪烁）
FIRE_CD     equ 20                  ; 开火冷却 tick（§3）
PLAYER_SELF equ 0
PLAYER_PEER equ 1
PLAYER_P2   equ 1                   ; 本地第二坦克（对练用）

; ---- 技能系统 ----
; 拾取物每 10s 随机生成一个（非水/非墙格），坦克中心格拾取，
; 再按各自"技能键"发动；连续拾取覆盖前一个。
SKILL_NONE      equ 0
SK_ICE_SHIELD   equ 1               ; 冰盾：挡一次伤害 + 周围 2x2 冰面
SK_LASER        equ 2               ; 激光炮：0.7s 后穿墙直线激光
SK_REFLASER     equ 3               ; 反射激光：预览反弹路径 0.7s 后全路径伤害
SK_GHOST        equ 4               ; 穿墙术：4s 或 3 次穿墙
SK_MINE         equ 5               ; 地雷：隐藏雷 2s 后生效（含自己）
SK_NITRO        equ 6               ; 燃油加速：50% 加速（与地形叠加）
SK_SWAP         equ 7               ; 换位术：发射子弹后可与之换位
SK_WATER        equ 8               ; 驭水术：可在水域行走
SK_PHANTOM      equ 9               ; 定格术：原地虚影 x2，实像免伤，6s
SKILL_COUNT     equ 9
PICKUP_PERIOD   equ 600             ; 10s @ 60tick
PICKUP_SIZE     equ 18              ; 拾取物边长（像素）
LASER_AIM_TICKS equ 42              ; 0.7s 瞄准延迟
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
ICE_SLIDE_MIN equ 6                 ; 滑行 tick 下限（6*4.5=27px 起步，可感）
ICE_SLIDE_RNG equ 10                ; 6 + rand%10 -> 6..15 tick（27..67px）

; ---- 子弹（§3）----
MAX_BULLETS     equ 56              ; 全场弹池
MAX_PER_TANK    equ 10              ; 每辆坦克同屏上限
BULLET_SPEED    equ 6               ; px/tick
BULLET_SIZE_PX  equ 8               ; 弹体 8x8
BULLET_LIFE     equ 600             ; 存活 600 tick（10 秒）自动消失
BULLET_MAX_BOUNCE equ 10            ; 反弹 >=10 次消失

; ---- 网络状态包（v1 兼容，M3 扩展为 slot 版）----
NET_PKT STRUCT
    magic   dw ?                     ; 标识 'TW'
    seq     dw ?                     ; 包序号，用于丢弃乱序旧包
    tx      dw ?                     ; 本端坦克 tile 坐标 x
    ty      dw ?                     ; 本端坦克 tile 坐标 y
    tdir    db ?                     ; 本端坦克朝向
    thp     db ?                     ; 本端坦克血量
    flags   db ?                     ; bit0: 本 tick 开火
    pad     db ?                     ; 对齐填充
    fireX   dw ?                     ; 开火时子弹初始位置
    fireY   dw ?
    fireDir db ?
    pad2    db ?
NET_PKT ENDS

NET_PKT_SIZE equ SIZEOF NET_PKT
NET_PORT    equ 28888                ; 本地监听端口（收发同端口）

; ============================================================
; 结构体定义
; ============================================================

; 坦克状态（一个玩家一条，tanks[MAX_PLAYERS]）
TANK STRUCT
    x       dd ?                     ; 左上角像素坐标
    y       dd ?
    dir     dd ?                     ; DIR_UP..DIR_LEFT
    hp      dd ?
    alive   dd ?                     ; 0=死亡 1=存活
    fireCd  dd ?                     ; 开火冷却剩余 tick
    slide   dd ?                     ; 冰面滑行剩余 tick（0=无）
    sdir    dd ?                     ; 滑行方向
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
    spawnDir dd ?                    ; 本回合出生朝向
TANK ENDS

; 子弹（全场固定池 bullets[MAX_BULLETS]）
; 反弹物理：存速度分量 vx/vy，反弹 = 对应分量取反（零乘除）
BULLET STRUCT
    x       dd ?                     ; 弹体 8x8 左上角像素
    y       dd ?
    vx      dd ?                     ; 速度分量，0 或 ±BULLET_SPEED
    vy      dd ?
    owner   dd ?                     ; 所属坦克槽位
    active  dd ?                     ; 0=空闲槽位 1=在飞
    bounces dd ?                     ; 已反弹次数
    age     dd ?                     ; 已存活 tick 数
BULLET ENDS
