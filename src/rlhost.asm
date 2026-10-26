; ============================================================
; rlhost.asm —— 会话47：RL 训练管道宿主（tankwar.exe rlhost）
; 64 位 Python 无法加载 x86 的 tankwar_rl.dll，故把环境整个装进
; exe：Python 以子进程开 N 个 tankwar.exe rlhost，stdin/stdout 走
; 定长二进制帧。无头 tick 路径与 selftest 同源（已验证可用），
; 多进程 = 多环境并行，单帧快照 3.6KB 走匿名管道开销可忽略。
;
; ---- 协议（小端；请求恒 64B；应答 SNAP 恒 rlSnapLen B）----
; 会话47C：META 追加两位（旧 [62]/[63] 保留位）——
;  [62]BULLET_FP(弹速 16.16 定点模长) [63]FIX_ONE(65536)
; 会话47C：rlMetaVer 1→3（47B 加 [62]/[63] 时未升号，此处补上）——RESET/STEP/PING 应答帧尾并入 inputTable
;  4槽×6 dword 电平（STEP 应答里即本 tick 实际生效值，bot 槽由
;  BotThink 覆写=行为克隆标签）。应答帧长 = META[0](SNAP_TOTAL) +
;  MAX_PLAYERS*KEY_PER*4，与 rlrec UDP 帧逐字节同构。
; 请求帧:
;   [0]   u8  cmd    1=RESET 2=STEP 3=PING 4=META
;   [1]   u8  flags  bit0: slot1 手动（botMask=0，双手动自博弈）
;                    bit1: 换位 slot0=启发式 bot、slot1=主机（BC 采集）
;                    全 0：botMask=2，slot1=启发式 bot 陪练（默认）
;   [4]   u32 cmd1=seed(0=时间播种)  cmd2=推进 tick 数(0..240)
;   [8]   i32[6] act slot0  F,B,CCW,CW,Fire,Skill（电平 0/1）
;   [32]  i32[6] act slot1  （flags.bit0 或 bit1 时生效）
; 应答帧:
;   cmd 1/2/3 → SNAP（布局见 BuildSnap）
;   cmd 4     → META 帧 64 dword（尺寸/偏移/常量，Python 启动握手，
;               结构漂移时 Python 读表自动跟随，永不静默错位）
; 其余命令回 SNAP；stdin EOF / stdout 写失败（父进程没了）→ 退出。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

STD_INPUT_HANDLE  equ 0FFFFFFF6h        ; -10
STD_OUTPUT_HANDLE equ 0FFFFFFF5h        ; -11
RL_MAGIC          equ 'RLS1'            ; SNAP 帧头
RL_METAVER        equ 3

; ---- SNAP 头部：14 个 dword，其后依次 tanks/bullets/mapData 原样 ----
SNAP_HDR      equ 56
SNAP_TOTAL    equ SNAP_HDR + 4*SIZEOF TANK + MAX_BULLETS*SIZEOF BULLET + COLS*ROWS

; ---- 同工程模块接口 ----
GameInit    PROTO
GameUpdate  PROTO
extern tanks       :TANK
extern bullets     :BULLET
extern mapData     :byte
extern mapIndex    :dword
extern inputTable  :dword
extern gTick       :dword
extern rngMatch    :dword
extern rngState    :dword
extern rngSeedOvr  :dword
extern botAggro    :dword             ; 会话50：RESET flags bit2 → 启发式陪练激进化
extern pickupType  :dword
extern pickupX     :dword
extern pickupY     :dword
extern pickupTimer :dword
extern matchOver   :dword
extern roundsPlayed:dword
extern maxRounds   :dword
extern botMask     :dword
extern achvNoSave  :dword
extern numPlayers  :dword
extern netMode     :dword
extern onlineBanT  :dword
extern sfxOn       :dword               ; ui.asm：无头必须静音（PlaySoundA 真实出声）

.data?
    rlReq     byte 64 dup(?)            ; 请求帧暂存
    rlSnap    byte SNAP_TOTAL + MAX_PLAYERS*KEY_PER*4 + 8 dup(?)  ; 应答帧暂存（SNAP+电平+余量）
    rlGot     dword ?                    ; Read/WriteFile 传输字节数
    rlHIn     dword ?                    ; stdin 管道句柄
    rlHOut    dword ?                    ; stdout 管道句柄

.code

; ------------------------------------------------------------
; SetActFromReq —— 把请求帧里 6 个 dword 电平抄进 inputTable
; esi=按键源(req+8 或 req+32)；输入槽恒 0/1。
; ------------------------------------------------------------
SetSlot0 macro
    lea esi, rlReq + 8
    lea edi, inputTable
    mov ecx, KEY_PER
    rep movsd
endm
SetSlot1 macro
    lea esi, rlReq + 32
    lea edi, inputTable
    add edi, 24                         ; 1*KEY_PER 个 dword
    mov ecx, KEY_PER
    rep movsd
endm

; ------------------------------------------------------------
; BuildSnap —— 组 SNAP 帧，返回长度于 eax（恒写 rlSnap）
; 布局（tools/rl_env.py SNAP_HDR 字段名按序）：
;  [0]magic [1]gTick [2]rngMatch [3]mapIndex [4]matchOver
;  [5]roundsPlayed [6]maxRounds [7]pickupType [8]pickupX
;  [9]pickupY [10]pickupTimer [11]botMask [12]rngState
;  [13]保留
;  + tanks[4] 原样 + bullets[MAX_BULLETS] 原样 + mapData 原样
; ------------------------------------------------------------
BuildSnap proc stdcall uses edi esi ecx
    lea edi, rlSnap
    mov dword ptr [edi+0*4], RL_MAGIC
    mov eax, gTick
    mov dword ptr [edi+1*4], eax
    mov eax, rngMatch
    mov dword ptr [edi+2*4], eax
    mov eax, mapIndex
    mov dword ptr [edi+3*4], eax
    mov eax, matchOver
    mov dword ptr [edi+4*4], eax
    mov eax, roundsPlayed
    mov dword ptr [edi+5*4], eax
    mov eax, maxRounds
    mov dword ptr [edi+6*4], eax
    mov eax, pickupType
    mov dword ptr [edi+7*4], eax
    mov eax, pickupX
    mov dword ptr [edi+8*4], eax
    mov eax, pickupY
    mov dword ptr [edi+9*4], eax
    mov eax, pickupTimer
    mov dword ptr [edi+10*4], eax
    mov eax, botMask
    mov dword ptr [edi+11*4], eax
    mov eax, rngState
    mov dword ptr [edi+12*4], eax
    mov dword ptr [edi+13*4], 0
    add edi, SNAP_HDR
    lea esi, tanks
    mov ecx, 4 * (SIZEOF TANK / 4)
    rep movsd
    lea esi, bullets
    mov ecx, MAX_BULLETS * (SIZEOF BULLET / 4)
    rep movsd
    lea esi, mapData
    mov ecx, (COLS * ROWS + 3) / 4       ; 589B 不整除 4：向上取整多拷 3B（尾字节随后被电平区覆盖，Python 按 COLS*ROWS 截读）
    rep movsd
    ; 会话47C：帧尾拼 inputTable 4槽×6 dword（96B）——STEP 应答里即"本 tick
    ; 实际生效电平"（bot 槽=BotThink 覆写值，即行为克隆标签）。rlhost 管道帧
    ; 与 rlrec UDP 帧从此逐字节同构。META[0] 仍报 SNAP_TOTAL，Python 侧帧长
    ; = snap_total + MAX_PLAYERS*KEY_PER*4。
    mov eax, SNAP_TOTAL
    lea edi, rlSnap
    add edi, eax
    lea esi, inputTable
    mov ecx, MAX_PLAYERS * KEY_PER
    rep movsd
    add eax, MAX_PLAYERS * KEY_PER * 4
    ret
BuildSnap endp

; ------------------------------------------------------------
; BuildMeta —— META 帧 64 dword（rl_env.py META_NAMES 按序对表）。
; 成员偏移用"局部假实例取地址差"，结构一改偏移自动跟随。
; ------------------------------------------------------------
META_TF macro fld, n
    lea eax, t.fld
    sub eax, ecx
    mov dword ptr [edi + n*4], eax
endm
META_BF macro fld, n
    lea eax, b.fld
    sub eax, edx
    mov dword ptr [edi + n*4], eax
endm

BuildMeta proc stdcall uses ecx edx eax edi
    local t: TANK
    local b: BULLET
    lea edi, rlSnap
    lea ecx, t
    lea edx, b
    ; [0..5] 尺寸与区段偏移：tanks@SNAP_HDR，bullets/map 依次顺排
    mov dword ptr [edi+0*4], SNAP_TOTAL
    mov eax, SIZEOF TANK
    mov dword ptr [edi+1*4], eax
    mov eax, SIZEOF BULLET
    mov dword ptr [edi+2*4], eax
    mov dword ptr [edi+3*4], SNAP_HDR
    mov dword ptr [edi+4*4], SNAP_HDR + 4*SIZEOF TANK
    mov dword ptr [edi+5*4], SNAP_HDR + 4*SIZEOF TANK + MAX_BULLETS*SIZEOF BULLET
    ; [6..20] 地图与规则常量
    mov dword ptr [edi+6*4], COLS
    mov dword ptr [edi+7*4], ROWS
    mov dword ptr [edi+8*4], CELL
    mov dword ptr [edi+9*4], MAP_W
    mov dword ptr [edi+10*4], MAP_H
    mov dword ptr [edi+11*4], MAX_BULLETS
    mov dword ptr [edi+12*4], MAX_PLAYERS
    mov dword ptr [edi+13*4], KEY_PER
    mov dword ptr [edi+14*4], TILE_EMPTY
    mov dword ptr [edi+15*4], TILE_BRICK
    mov dword ptr [edi+16*4], TILE_STEEL
    mov dword ptr [edi+17*4], TILE_WATER
    mov dword ptr [edi+18*4], TILE_ICE
    mov dword ptr [edi+19*4], TILE_DIRT
    mov dword ptr [edi+20*4], TANK_HP
    ; [21..49] TANK 成员偏移
    META_TF x, 21
    META_TF y, 22
    META_TF subpxX, 23
    META_TF subpxY, 24
    META_TF dir, 25
    META_TF hp, 26
    META_TF alive, 27
    META_TF fireCd, 28
    META_TF slide, 29
    META_TF sdir, 30
    META_TF score, 31
    META_TF skill, 32
    META_TF effOn, 33
    META_TF shieldT, 34
    META_TF effT, 35
    META_TF wallPass, 36
    META_TF swapBul, 37
    META_TF aimT, 38
    META_TF aimSkill, 39
    META_TF lastCell, 40
    META_TF phantomX, 41
    META_TF phantomY, 42
    META_TF phantomUses, 43
    META_TF lives, 44
    META_TF respawnT, 45
    META_TF protT, 46
    META_TF spawnX, 47
    META_TF spawnY, 48
    META_TF spawnDir, 49
    ; [50..60] BULLET 成员偏移
    META_BF x, 50
    META_BF y, 51
    META_BF vx, 52
    META_BF vy, 53
    META_BF owner, 54
    META_BF active, 55
    META_BF bounces, 56
    META_BF age, 57
    META_BF subpxX, 58
    META_BF subpxY, 59
    META_BF fireAng, 60
    mov dword ptr [edi+61*4], RL_METAVER
    mov dword ptr [edi+62*4], BULLET_FP        ; 弹速模长（16.16 定点，vx/vy 归一用）
    mov dword ptr [edi+63*4], FIX_ONE          ; 65536：定点换算基准
    ret
BuildMeta endp

; ------------------------------------------------------------
; RlHostMain —— 主循环。任何 stdio 故障即退出（父进程已死）。
; 句柄/计数一律走静态变量：SetSlot* 宏与 GameUpdate 会随意覆写
; esi/edi/ecx（GameUpdate 只保 ebx/esi/edi，ecx 从不承诺保留）。
; ------------------------------------------------------------
RlHostMain proc
    invoke GetStdHandle, STD_OUTPUT_HANDLE
    mov rlHOut, eax
    invoke GetStdHandle, STD_INPUT_HANDLE
    mov rlHIn, eax
    mov sfxOn, 0                        ; 无头静音
    mov achvNoSave, 1                   ; 永不落成就盘
RLH_Loop:
    invoke ReadFile, rlHIn, offset rlReq, 64, offset rlGot, NULL
    mov eax, rlGot
    cmp eax, 64
    jb RLH_Done                         ; EOF/半帧：Python 走了
    movzx eax, byte ptr rlReq
    .if eax == 4                        ; META：单独 256B 应答
        invoke BuildMeta
        invoke WriteFile, rlHOut, offset rlSnap, 64*4, offset rlGot, NULL
        mov eax, rlGot
        cmp eax, 64*4
        jb RLH_Done
        jmp RLH_Loop
    .elseif eax == 1                    ; RESET
        mov eax, dword ptr rlReq + 4
        mov rngSeedOvr, eax
        mov ecx, dword ptr rlReq + 1    ; 会话50：flags bit2=激进陪练开关
        and ecx, 4                      ;   （GUI/selftest 不经此路，恒 0=不变）
        mov botAggro, ecx
        mov numPlayers, 2
        mov netMode, 0
        mov onlineBanT, 0
        invoke GameInit
        mov gTick, 0                    ; 主机复位相位：同 seed 全可复现
        mov eax, dword ptr rlReq + 1    ; flags
        and eax, 3
        .if eax != 0                    ; bit1 优先：换位（bit1 与 bit0 同置时也走换位）
            .if eax & 2
                mov botMask, 1          ; slot0=启发式 bot，slot1=主机（BC 采集）
            .else
                mov botMask, 0          ; 双手动（自博弈评估）
            .endif
        .else
            mov botMask, 2              ; 默认 slot1=启发式陪练
        .endif
        invoke BuildSnap
        jmp RLH_Send
    .elseif eax == 2                    ; STEP
        mov ebx, dword ptr rlReq + 4
        .if ebx > 240
            mov ebx, 240
        .elseif ebx < 0
            xor ebx, ebx
        .endif
        ; 先写槽（botMask 位由 BotThink 每 tick 覆写；策略槽无人覆写）
        SetSlot0
        mov eax, dword ptr rlReq + 1
        and eax, 3
        .if eax != 0
            SetSlot1                    ; bit0=双手动 / bit1=换位：slot1 均为主机槽
        .endif
        test ebx, ebx
        jz RLH_TickDone
    RLH_Tick1:
        invoke GameUpdate
        dec ebx
        jnz RLH_Tick1
    RLH_TickDone:
        invoke BuildSnap
        jmp RLH_Send
    .else                               ; PING/未知 → 也回 SNAP
        invoke BuildSnap
    RLH_Send:
        mov ebx, eax                    ; SNAP_TOTAL
        invoke WriteFile, rlHOut, offset rlSnap, ebx, offset rlGot, NULL
        mov eax, rlGot
        cmp eax, ebx
        jb RLH_Done                     ; 管道断了
    .endif
    jmp RLH_Loop
RLH_Done:
    ret
RlHostMain endp

; ============================================================
;  附：实时对战推流录制器（会话47 服务端需求）
;  `tankwar.exe rlrec [ip:port]` 正常开窗口打游戏，每逻辑 tick
;  把 SNAP 快照 + 四槽 inputTable 电平打包成一枚 UDP 数据报推给
;  采集服务（默认 127.0.0.1:51777，tools/rl_server.py 接收）。
;  帧 = [rlSnap SNAP_TOTAL 字节][inputTable 4×6 dword 96 字节]，
;  单帧 ~3.6KB @60pps，回环/局域网皆可。人类对局数据由此进训练
;  管线（行为克隆/风格评估），与 rlhost 帧同源同偏移。
; ============================================================
.data?
    rlrcSock  dd ?
    rlrcAddr  sockaddr_in <>
    rlrcBuf   byte SNAP_TOTAL + 8 + MAX_PLAYERS*KEY_PER*4 dup(?)
    rlrcIp    dd ?
    rlrcPort  dd ?
    wsaRc     WSADATA <>

.data
    public rlRecOn
    rlRecOn   dd 0
    recDfltSpec db "127.0.0.1:51777", 0

; net.asm 真实现（exe 链路；ParseIp 输出 ip=网络序 dword、port=主机序，
; 与 ui 手输 IP 通路完全同一语义——会话36 T46 已重点校过）
ParseIp PROTO stdcall :DWORD,:DWORD,:DWORD

.code

; ------------------------------------------------------------
; RlRecInit(pSpec) —— pSpec=0 用默认 127.0.0.1:51777。
; 任何一步失败只让 rlRecOn 保持 0，游戏本体照常（录不上不碍玩）。
; ------------------------------------------------------------
RlRecInit proc stdcall uses ebx pSpec:DWORD
    mov ebx, pSpec
    .if ebx == 0
        mov ebx, OFFSET recDfltSpec
    .endif
    invoke ParseIp, ebx, addr rlrcIp, addr rlrcPort
    .if eax == 0
        ; 自定义地址写错：回退默认回环，不让用户白跑一局没数据
        mov ebx, OFFSET recDfltSpec
        invoke ParseIp, ebx, addr rlrcIp, addr rlrcPort
        .if eax == 0
            ret
        .endif
    .endif
    invoke WSAStartup, 0202h, addr wsaRc
    .if eax != 0
        ret
    .endif
    invoke socket, AF_INET, SOCK_DGRAM, IPPROTO_UDP
    .if eax == -1
        ret
    .endif
    mov rlrcSock, eax
    mov rlrcAddr.sin_family, AF_INET
    invoke htons, rlrcPort
    mov word ptr rlrcAddr.sin_port, ax
    mov eax, rlrcIp
    mov rlrcAddr.sin_addr, eax
    mov rlRecOn, 1
    ret
RlRecInit endp

; ------------------------------------------------------------
; RlRecPump —— 一帧推送。GameUpdate 之后由 WinMain tick 调用。
; ------------------------------------------------------------
RlRecPump proc stdcall uses esi edi ecx ebx
    mov eax, rlRecOn
    test eax, eax
    jz RP_Done
    invoke BuildSnap                      ; 会话47C：帧=SNAP+电平 已在 BuildSnap 一体组好
    mov ebx, eax                          ; ebx = 整帧长（SNAP_TOTAL+96）
    lea edi, rlrcBuf
    mov esi, OFFSET rlSnap
    add eax, 3
    shr eax, 2
    mov ecx, eax
    rep movsd                             ; 向上取整多的 3B 落在缓冲余量，sendto 只发 ebx
    invoke sendto, rlrcSock, OFFSET rlrcBuf,
             ebx, 0,
             addr rlrcAddr, SIZEOF sockaddr_in
RP_Done:
    ret
RlRecPump endp

end
