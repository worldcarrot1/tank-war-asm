; ============================================================
; game.inc —— 公共常量与结构体定义
; 所有模块共享的定义集中在这里，改协议/平衡性只动这个文件
; ============================================================

; ---- 窗口与渲染 ----
WND_W       equ 640                 ; 窗口客户区宽度（像素）
WND_H       equ 480                 ; 窗口客户区高度（像素）
CELL        equ 32                  ; 地图格子边长（像素）
COLS        equ WND_W / CELL        ; 20 列
ROWS        equ WND_H / CELL        ; 15 行

; ---- 游戏节奏 ----
TICK_MS     equ 16                  ; 约 60 tick/秒
; NET_SEND_SKIP equ 2                ; 每 2 tick 发一次网络包（约 30Hz）

; ---- 地图格子类型 ----
TILE_EMPTY  equ 0
TILE_BRICK  equ 1                   ; 砖墙，可被子弹摧毁
TILE_STEEL  equ 2                   ; 钢墙，不可摧毁
TILE_BASE   equ 3                   ; 基地，被摧毁判负

; ---- 方向 ----
DIR_UP      equ 0
DIR_RIGHT   equ 1
DIR_DOWN    equ 2
DIR_LEFT    equ 3

; ---- 坦克属性 ----
TANK_SPEED  equ 2                   ; 每 tick 移动像素
TANK_HP     equ 3
MAX_BULLETS equ 8                   ; 场上子弹上限（固定数组，便于汇编遍历）
BULLET_SPEED equ 6

; ---- 玩家编号 ----
PLAYER_SELF equ 0
PLAYER_PEER equ 1

; ============================================================
; 结构体定义
; ============================================================

; 坦克状态（一个玩家一条）
TANK STRUCT
    x       dd ?                     ; 左上角像素坐标
    y       dd ?
    dir     dd ?                     ; DIR_UP..DIR_LEFT
    hp      dd ?
    alive   dd ?                     ; 0=死亡 1=存活
    fireCd  dd ?                     ; 开火冷却剩余 tick
TANK ENDS

; 子弹（场上所有子弹存进固定数组 bullets[MAX_BULLETS]）
BULLET STRUCT
    x       dd ?
    y       dd ?
    dir     dd ?
    owner   dd ?                     ; PLAYER_SELF / PLAYER_PEER
    active  dd ?                     ; 0=空闲槽位 1=在飞
BULLET ENDS

; 网络状态包（见 docs/PROTOCOL.md，定长便于汇编收发）
NET_PKT STRUCT
    magic   dw ?                     ; 标识字 'TW'
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
; 注意：变量（mapData / tanks / bullets 等）统一定义在 game.asm，
; 其他模块用 extern 声明引用，本文件只放常量与结构体，避免重复定义。
