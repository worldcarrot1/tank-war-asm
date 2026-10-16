; ============================================================
; game.asm —— 游戏逻辑核心（GAME_DESIGN v2 / 里程碑 M1）
; 职责：
;   - 字符画对战地图解析（ARENA1..5，运行时随机选图）
;   - 砖墙 2x2 子块破坏（brickMask 每格 4 bit）
;   - 反弹子弹物理：钢/砖/屏幕边界反弹，水/冰/空地穿过
;   - 水域挡坦克、冰面滑行 6~10 tick
;   - 本地双坦克（P1: WASD+空格 / P2: 方向键+Enter）
; 确定性约定（联机地形事件依赖）：
;   - 子弹每 tick 固定顺序：age -> X 轴(边界->地形) -> Y 轴(边界->地形) -> 坦克命中
;   - 地形四角采样顺序固定：TL, TR, BR, BL，命中即返回
;   - 坦克命中遍历顺序固定：slot 0..MAX_PLAYERS-1
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

GameUpdate PROTO                   ; 同模块前向声明（自测助手先用后定义）
TileAtPx  PROTO :DWORD,:DWORD      ; 同模块前向声明

; ---- 输入快照（本模块定义，input.asm / ui.asm 写入）----
public keyTable
public inputTable
public inputRestart
extern numPlayers :dword               ; ui.asm（当前玩家数 2..4）

; ---- 游戏状态（本模块定义，gfx.asm / net.asm 读取）----
public tanks
public bullets
public mapData
public mapIndex
public SpawnBullet
public GameInit
public GameUpdate
public fireHappened
public seqSelf
public SelfTestRun
public InitKeyDefaults

.data
    tanks       TANK MAX_PLAYERS dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)
    spawnX      dd 4 dup (0)         ; 出生点像素坐标（字符画 'S'）
    spawnY      dd 4 dup (0)
    spawnCount  dd 0
    mapIndex    dd 0                 ; 当前 ARENA 编号
    keyTable    dd MAX_PLAYERS*5 dup (0)   ; [slot*5+动作] VK 码: 0上1下2左3右4开火
    inputTable  dd MAX_PLAYERS*5 dup (0)   ; [slot*5+动作] 每 tick 快照 0/1
    inputRestart dd 0                      ; R 重开（固定键）
    roundOver   dd 0                 ; 回合结束定格中
    roundTimer  dd 0                 ; 定格剩余 tick
    roundScored dd 0                 ; 本回合已判分
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick P1 是否开火（发包 flag 用）
    rngState    dd 0                 ; xorshift32 状态

; ---- 字符画对战地图（20x15 字符/张，编译期嵌入）----
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  S 出生点
ARENA1 db "###############################"
       db "#S..b...#.-.........-.#...b..S#"
       db "#.#~#.#-b#b.#.###.#.b#b-#.#~#.#"
       db "#.#........-.......-........#.#"
       db "#.#####.#.#.#.#.#.#.#.#.#####.#"
       db "#...........~.#.#.~...........#"
       db "#.#.##b.#.##b##-##b##.#.b##.#.#"
       db "#.#..-~.#.~.........~.#.~-..#.#"
       db "#-#.b.#.#.#b#.###.#b#.#.#.b.#-#"
       db "#...~.....................~...#"
       db "#.#b###~#.#.b.#b#.b.#.#~###b#.#"
       db "#.......#.............#.......#"
       db "#.#.#.#.#.###.#.#.###.#.#.#.#.#"
       db "#........-...........-........#"
       db "#.b.#.#.#.#.#.###.#.#.#.#.#.b.#"
       db "#.............................#"
       db "#.#.##b.#.#####.#####.#.b##.#.#"
       db "#S...-...................-...S#"
       db "###############################"
       db "###############################"

ARENA2 db "###############################"
       db "#S..#.....................#..S#"
       db "#.b-#.#.#.#.#.###.#.#.#.#.#-b.#"
       db "#.#...#.....#.....#.....#...#.#"
       db "#.#.b.#.#####.###.#####.#.b.#.#"
       db "#...~~.....-.......-.....~~...#"
       db "#.#.#.b####.#######.####b.#.#.#"
       db "#.#.........................#.#"
       db "#-#.###.b####.#.#.####b.###.#-#"
       db "#-............#.#............-#"
       db "#.###.#.#.#.###.###.#.#.#.###.#"
       db "#.....b........-........b.....#"
       db "#~###.#.#####-#b#-#####.#.###~#"
       db "#.~...#.................#...~.#"
       db "#.b.#.b.#.###.###.###.#.b.#.b.#"
       db "#.#...b.~-.-#.....#-.-~.b...#.#"
       db "#.#.#.b.###.#.#.#.#.###.b.#.#.#"
       db "#S....~.................~....S#"
       db "##b#b#####################b#b##"
       db "###############################"

ARENA3 db "###############################"
       db "#S....-.......-.-.......-....S#"
       db "#.#.#.#.#b#.###.###.#b#.#.#.#.#"
       db "#......-..#.........#..-......#"
       db "#.#.#.#.#.#.#.###.#.#.#.#.#.#.#"
       db "#.....~.....~.~.~.~.....~.....#"
       db "#.#.###.#.###.b.b.###.#.###.#.#"
       db "#.......-.~.........~.-.......#"
       db "#.#.#.###.#.#.###.#.#.###.#.#.#"
       db "#...b....~#.........#~....b...#"
       db "#.#.#.#.#.#~#.b.b.#~#.#.#.#.#.#"
       db "#.#........-#-...-#-........#.#"
       db "#.#######.#.#.#.#.#.#.#######.#"
       db "#......-..#...#.#...#..-......#"
       db "#-#.b.b.#.#.#.###.#.#.#.b.b.#-#"
       db "#...#.#.................#.#...#"
       db "#.###.#.#bb.###.###.bb#.#.###.#"
       db "#S...........................S#"
       db "###bb#b#####b#####b#####b#bb###"
       db "###############################"

ARENA4 db "###############################"
       db "#S..~..........-..........~..S#"
       db "#.#.#.#.#.#.#.#b#.#.#.#.#.#.#.#"
       db "#.#........~#.....#~........#.#"
       db "#-#-###b#.b.#.###.#.b.#b###-#-#"
       db "#.........-.........-.........#"
       db "#.#.#.b.#.#.b.#.#.b.#.#.b.#.#.#"
       db "#.......#...#.....#...#.......#"
       db "#.#.###.#.#~b.###.b~#.#.###.#.#"
       db "#..-.......................-..#"
       db "#.#.#.#.#.#.##b#b##.#.#.#.#.#.#"
       db "#...-.....................-...#"
       db "#.#.#.###.#.###.###.#.###.#.#.#"
       db "#......~......#-#......~......#"
       db "#.#.#.b.#.b.#.#.#.#.b.#.b.#.#.#"
       db "#.....#...#...#.#...#...#.....#"
       db "#.#-#.b.#.#.#.#.#.#.#.#.b.#-#.#"
       db "#S~......~..#.....#..~......~S#"
       db "###b##b#################b##b###"
       db "###############################"

ARENA5 db "###############################"
       db "#S...........................S#"
       db "#.#.#~###.#b#.###.#b#.###~#.#.#"
       db "#.........#.-.....-.#.........#"
       db "#~#.#~####b.###.###.b####~#.#~#"
       db "#...#....-..#.....#..-....#...#"
       db "#.b.#.#.#.#b#-###-#b#.#.#.#.b.#"
       db "#-..#...-.....#.#.....-...#..-#"
       db "#.#.#.#.#.###.b.b.###.#.#.#.#.#"
       db "#.......-.....#.#.....-.......#"
       db "#####.#.#.#.#.#.#.#.#.#.#.#####"
       db "#.....#...#.........#...#.....#"
       db "#.#.#.#.#.#.#######.#.#.#.#.#.#"
       db "#.#.........-.....-.........#.#"
       db "#.#.#.###.#.b.#.#.b.#.###.#.#.#"
       db "#.#.........#.....#.........#.#"
       db "#~##b.#.b.b.#.b#b.#.b.b.#.b##~#"
       db "#S.......~..~..-..~..~.......S#"
       db "######b######b###b######b######"
       db "###############################"

arenaTable dd ARENA1, ARENA2, ARENA3, ARENA4, ARENA5
    logName     db "selftest.log", 0
    selftestArg db "selftest"
    nlStr       db 13, 10
    logHandle   dd 0
    written     dd 0
    logVal      dd 0
    logBuf      db 64 dup (0)
    saveMap     db COLS*ROWS dup (0)
    nbRow       dd ?
    nbCol       dd ?
    nbIdx       dd ?
    nbDir       dd ?
    stT1  db "T1_P1_X_ROW13(expect112)="
    stT2  db "T2_ACTIVE_AFTER_FIRE="
    stT3  db "T3_ACTIVE_AFTER_620TICKS="
    stT4  db "T4_MAP_UNCHANGED(expect1)="
    stT5  db "T5_NOT_ON_WATER(expect1)="
    stT6  db "T6_SLIDE_ENGAGED(expect6-10)="
    stT7  db "T7_P2_X(expect120)="
    stT8  db "T8_BULLETS_AFTER_15FIRE(expect<=10)="
    stT9a db "T9_P2_DEAD_AT_TICK="
    stT9b db "T9_P2_ALIVE(expect0)="
    stT9c db "T9_P2_HP(expect0)="
    stT10 db "T10_P1_SCORE(expect1)="

.code

; ------------------------------------------------------------
; RngNext —— xorshift32：x^=x<<13; x^=x>>17; x^=x<<5
; 返回 eax = 32 位随机数
; ------------------------------------------------------------
RngNext proc
    mov eax, rngState
    .if eax == 0
        mov eax, 2463534242       ; 防全零锁死
    .endif
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov rngState, eax
    ret
RngNext endp

; ------------------------------------------------------------
; RngBelow —— 返回 eax = [0, limit) 的随机整数
; ------------------------------------------------------------
RngBelow proc limit: dword
    invoke RngNext
    xor edx, edx
    div limit
    mov eax, edx
    ret
RngBelow endp

; ------------------------------------------------------------
; ParseArena —— 字符画 -> mapData / brickMask / 出生点
; 入参：pArena = 300 字节字符画首址
; ------------------------------------------------------------
ParseArena proc uses ebx esi edi ebp pArena: dword
    mov esi, pArena
    xor ebx, ebx                 ; i = 线性格子序号
    xor ebp, ebp                 ; row
RowLoop2:
    xor edi, edi                 ; col
ColLoop2:
    movzx eax, byte ptr [esi+ebx]
    mov dl, TILE_EMPTY
    .if al == '#'
        mov dl, TILE_STEEL
    .elseif al == 'b'
        mov dl, TILE_BRICK
    .elseif al == '~'
        mov dl, TILE_WATER
    .elseif al == '-'
        mov dl, TILE_ICE
    .endif                       ; '.' 与 'S' 均落为空地
    mov mapData[ebx], dl
    ; 出生点记录（最多 4 个，顺序 = 图中 S 出现顺序）
    .if al == 'S'
        mov eax, spawnCount
        .if eax < 4
            mov ecx, edi
            imul ecx, ecx, CELL
            mov spawnX[eax*4], ecx
            mov ecx, ebp
            imul ecx, ecx, CELL
            mov spawnY[eax*4], ecx
            inc spawnCount
        .endif
    .endif
    inc ebx
    inc edi
    .if edi < COLS
        jmp ColLoop2
    .endif
    inc ebp
    .if ebp < ROWS
        jmp RowLoop2
    .endif
    ret
ParseArena endp

; ------------------------------------------------------------
; ResetTanks -- reset all tank slots, place tank0/tank1 at spawns,
; clear bullet pool (shared by GameInit and SelfTest)
; ------------------------------------------------------------
ResetTanks proc uses ebx esi edi
    lea esi, tanks
    xor ebx, ebx
RTLoop:
    mov (TANK ptr [esi]).alive, 0
    mov (TANK ptr [esi]).hp, TANK_HP
    mov (TANK ptr [esi]).fireCd, 0
    mov (TANK ptr [esi]).slide, 0
    mov (TANK ptr [esi]).sdir, 0
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp RTLoop
    .endif
    ; 按 numPlayers 激活坦克：2P=出生点0,3(对角) 3P=0,1,2 4P=0,1,2,3
    xor ebx, ebx
RT_Spawn:
    .if ebx >= numPlayers
        jmp RT_SpawnDone
    .endif
    mov esi, ebx
    .if numPlayers == 2 && ebx == 1
        mov esi, 3
    .endif
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edi, eax
    mov eax, esi
    mov eax, spawnX[eax*4]
    mov (TANK ptr [edi]).x, eax
    mov eax, esi
    mov eax, spawnY[eax*4]
    mov (TANK ptr [edi]).y, eax
    mov (TANK ptr [edi]).dir, DIR_DOWN
    mov (TANK ptr [edi]).alive, 1
    .if esi >= 2
        mov (TANK ptr [edi]).dir, DIR_UP      ; 下半出生点朝上
    .endif
    inc ebx
    jmp RT_Spawn
RT_SpawnDone:
    ; 清空弹池
    xor eax, eax
    mov ecx, MAX_BULLETS*(SIZEOF BULLET)/4
    lea edi, bullets
RTClearB:
    mov [edi], eax
    add edi, 4
    loop RTClearB
    mov roundOver, 0
    mov roundTimer, 0
    mov roundScored, 0
    mov seqSelf, 0
    mov fireHappened, 0
    ret
ResetTanks endp

; ------------------------------------------------------------
; OpenLog / LogStr / LogNum / CloseLog -- selftest log file helpers
; ------------------------------------------------------------
OpenLog proc
    invoke CreateFileA, offset logName, GENERIC_WRITE, 0, NULL,
           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    mov logHandle, eax
    ret
OpenLog endp

CloseLog proc
    invoke CloseHandle, logHandle
    ret
CloseLog endp

LogStr proc pStr: dword, len: dword
    invoke WriteFile, logHandle, pStr, len, addr written, NULL
    ret
LogStr endp

LogNum proc num: dword
    mov eax, num
    mov edi, offset logBuf
    add edi, 60
    mov byte ptr [edi], 0
    .if eax == 0
        dec edi
        mov byte ptr [edi], '0'
    .endif
    mov ecx, 10
LNLoop:
    .if eax != 0
        xor edx, edx
        div ecx
        add dl, '0'
        dec edi
        mov [edi], dl
        jmp LNLoop
    .endif
    mov eax, offset logBuf + 60
    sub eax, edi
    invoke WriteFile, logHandle, edi, eax, addr written, NULL
    invoke WriteFile, logHandle, offset nlStr, 2, addr written, NULL
    ret
LogNum endp

; ------------------------------------------------------------
; AdvanceTicks -- run GameUpdate n times (selftest driver)
; ------------------------------------------------------------
AdvanceTicks proc uses ebx n: dword
    mov ebx, n
ATLoop:
    invoke GameUpdate
    dec ebx
    .if ebx != 0
        jmp ATLoop
    .endif
    ret
AdvanceTicks endp

; ------------------------------------------------------------
; FindOpenNeighbor -- 找某格四邻中第一个可通行格（空地/冰）
; 入参：cellIdx；返回 eax = 方向码 0上 1右 2下 3左，nbIdx = 邻居格索引
; ------------------------------------------------------------
FindOpenNeighbor proc uses ebx ecx edx cellIdx: dword
    mov eax, cellIdx
    xor edx, edx
    mov ebx, COLS
    div ebx
    mov nbRow, eax
    mov nbCol, edx
    mov nbDir, 99
    mov nbIdx, 99
    ; 上
    mov eax, nbRow
    .if eax > 0
        dec eax
        imul eax, eax, COLS
        add eax, nbCol
        mov ecx, eax
        movzx eax, mapData[ecx]
        .if eax == TILE_EMPTY || eax == TILE_ICE
            mov nbDir, 0
            mov nbIdx, ecx
        .endif
    .endif
    ; 右
    .if nbDir == 99
        mov eax, nbCol
        .if eax < COLS-1
            mov eax, nbRow
            imul eax, eax, COLS
            add eax, nbCol
            inc eax
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE
                mov nbDir, 1
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    ; 下
    .if nbDir == 99
        mov eax, nbRow
        .if eax < ROWS-1
            mov eax, nbRow
            inc eax
            imul eax, eax, COLS
            add eax, nbCol
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE
                mov nbDir, 2
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    ; 左
    .if nbDir == 99
        mov eax, nbCol
        .if eax > 0
            mov eax, nbRow
            imul eax, eax, COLS
            add eax, nbCol
            dec eax
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE
                mov nbDir, 3
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    mov eax, nbDir
    ret
FindOpenNeighbor endp

; ------------------------------------------------------------
; SetDirInput -- 按方向码设置 P1 输入（99 = 全部清零）
; ------------------------------------------------------------
SetDirInput proc dir: dword
    mov inputTable[0], 0
    mov inputTable[4], 0
    mov inputTable[8], 0
    mov inputTable[12], 0
    mov eax, dir
    .if eax == 0
        mov inputTable[0], 1
    .elseif eax == 1
        mov inputTable[12], 1
    .elseif eax == 2
        mov inputTable[4], 1
    .elseif eax == 3
        mov inputTable[8], 1
    .endif
    ret
SetDirInput endp

; ------------------------------------------------------------
; InitKeyDefaults -- 默认键位表（设置界面可覆盖）
; P1 WASD+空格  P2 方向键+Enter  P3 IJKL+U  P4 TFGH+B
; 动作顺序：0上 1下 2左 3右 4开火
; ------------------------------------------------------------
InitKeyDefaults proc
    mov keyTable[0],  VK_W
    mov keyTable[4],  VK_S
    mov keyTable[8],  VK_A
    mov keyTable[12], VK_D
    mov keyTable[16], VK_SPACE
    mov keyTable[20], VK_UP
    mov keyTable[24], VK_DOWN
    mov keyTable[28], VK_LEFT
    mov keyTable[32], VK_RIGHT
    mov keyTable[36], VK_RETURN
    mov keyTable[40], VK_I
    mov keyTable[44], VK_K
    mov keyTable[48], VK_J
    mov keyTable[52], VK_L
    mov keyTable[56], VK_U
    mov keyTable[60], VK_T
    mov keyTable[64], VK_G
    mov keyTable[68], VK_F
    mov keyTable[72], VK_H
    mov keyTable[76], VK_B
    ret
InitKeyDefaults endp

; ------------------------------------------------------------
; CountOwnBullets -- number of active bullets owned by ownerIdx
; ------------------------------------------------------------
CountOwnBullets proc uses ebx esi ownerIdx: dword
    xor eax, eax
    xor ecx, ecx
    mov esi, offset bullets
    mov ebx, ownerIdx
CB2Loop:
    .if ecx >= MAX_BULLETS
        jmp CB2Done
    .endif
    cmp (BULLET ptr [esi]).active, 0
    je CB2Skip
    cmp (BULLET ptr [esi]).owner, ebx
    jne CB2Skip
    inc eax
CB2Skip:
    add esi, SIZEOF BULLET
    inc ecx
    jmp CB2Loop
CB2Done:
    ret
CountOwnBullets endp

; ------------------------------------------------------------
; SelfTestRun -- M1 headless acceptance test (run with: tankwar selftest)
; Deterministic: fixed ARENA1, simulated inputs, results -> selftest.log
; ------------------------------------------------------------
SelfTestRun proc uses ebx esi edi
    ; 固定 ARENA1 保证确定性
    mov rngState, 1
    mov spawnCount, 0
    invoke ParseArena, offset ARENA1
    call ResetTanks
    ; 地图快照（验证墙体不可摧毁）
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    rep movsb
    call OpenLog

    ; T1: P1 沿第 13 行走廊右移 40 tick（32 -> 112）
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    invoke SetDirInput, 1
    invoke AdvanceTicks, 40
    invoke SetDirInput, 99
    invoke LogStr, offset stT1, 25
    invoke LogNum, tanks[0*SIZEOF TANK].x          ; expect 112

    ; T2: 开火 -> 一颗弹在飞
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT2, 21
    invoke LogNum, logVal                          ; expect 1

    ; T3: 620 tick 后弹全部消亡（反弹耗尽或超时）
    invoke AdvanceTicks, 620
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT3, 25
    invoke LogNum, logVal                          ; expect 0

    ; T4: 墙体不可摧毁 —— 轰一炮再跑 900 tick，地图逐字节不变
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    invoke AdvanceTicks, 900
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    repe cmpsb
    mov logVal, 0
    .if ZERO?
        mov logVal, 1
    .endif
    invoke LogStr, offset stT4, 26
    invoke LogNum, logVal                          ; expect 1

    ; T5: 水域挡坦克 —— 找第一个 '~'，从开放邻居向水推进 30 tick，
    ;     坦克中心格必须不是水
    xor esi, esi
T5Find:
    .if esi >= COLS*ROWS
        mov logVal, 99
        invoke LogStr, offset stT5, 25
        invoke LogNum, logVal
        ; 直接落入 T6 段
    .endif
    cmp mapData[esi], TILE_WATER
    je T5Found
    inc esi
    jmp T5Find
T5Found:
    invoke FindOpenNeighbor, esi
    mov ebx, eax                                   ; dirCode（邻居相对水格的方向）
    mov eax, nbIdx
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, edx
    imul ecx, ecx, CELL
    mov tanks[0*SIZEOF TANK].x, ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    invoke SetDirInput, ebx                        ; 朝水推进
    invoke AdvanceTicks, 30
    invoke SetDirInput, 99                         ; 清输入
    mov eax, tanks[0*SIZEOF TANK].x
    add eax, CELL/2
    mov ecx, tanks[0*SIZEOF TANK].y
    add ecx, CELL/2
    invoke TileAtPx, eax, ecx
    mov logVal, 1
    .if eax == TILE_WATER
        mov logVal, 0                              ; 坦克中心在水上 = 失败
    .endif
    invoke LogStr, offset stT5, 25
    invoke LogNum, logVal                          ; expect 1

    ; T6: 冰面滑行 —— 站上第一个 '-'，向开放邻居方向走 1 tick，
    ;     slide 应被置为 6..10
    xor esi, esi
T6Find:
    .if esi >= COLS*ROWS
        mov logVal, 99
        invoke LogStr, offset stT6, 29
        invoke LogNum, logVal
        jmp T7Start
    .endif
    cmp mapData[esi], TILE_ICE
    je T6Found
    inc esi
    jmp T6Find
T6Found:
    invoke FindOpenNeighbor, esi
    mov ebx, eax
    mov eax, esi                       ; 传送目标是冰面格本身
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, edx
    imul ecx, ecx, CELL
    mov tanks[0*SIZEOF TANK].x, ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    invoke SetDirInput, ebx
    invoke GameUpdate
    invoke SetDirInput, 99
    invoke LogStr, offset stT6, 29
    invoke LogNum, tanks[0*SIZEOF TANK].slide      ; expect 6..10

    ; T7: P2 方向键 —— 第 13 行走廊左移 20 tick（160 -> 120）
T7Start:
    call ResetTanks
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputTable[28], 1
    invoke AdvanceTicks, 20
    mov inputTable[28], 0
    invoke LogStr, offset stT7, 19
    invoke LogNum, tanks[1*SIZEOF TANK].x          ; expect 120

    ; T8: 每坦同屏 <=10 发（15 次快速开火 -> 场上 10 颗）
    call ResetTanks
    mov ebx, 15
T8Loop:
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    dec ebx
    .if ebx != 0
        jmp T8Loop
    .endif
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT8, 36
    invoke LogNum, logVal                          ; expect 10

    ; T9: 反弹/直射击杀 —— 第 13 行同走廊，3 发命中判负
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputTable[16], 1
    xor esi, esi
T9Loop:
    .if esi >= 300
        jmp T9Done
    .endif
    invoke GameUpdate
    inc esi
    cmp tanks[1*SIZEOF TANK].alive, 0
    je T9Done
    jmp T9Loop
T9Done:
    mov inputTable[16], 0
    invoke LogStr, offset stT9a, 19
    invoke LogNum, esi                             ; kill tick (<300)
    invoke LogStr, offset stT9b, 21
    invoke LogNum, tanks[1*SIZEOF TANK].alive      ; expect 0
    invoke LogStr, offset stT9c, 18
    invoke LogNum, tanks[1*SIZEOF TANK].hp         ; expect 0
    invoke AdvanceTicks, 100                       ; 等定格结束（90 tick）开新一轮
    invoke LogStr, offset stT10, 23
    invoke LogNum, tanks[0*SIZEOF TANK].score      ; expect 1

    call CloseLog
    ret
SelfTestRun endp

; ------------------------------------------------------------
; GameInit —— 随机选图解析 + 重置坦克/子弹
; tank0 = 出生点0（左上，朝下），tank1 = 出生点3（右下，朝上）
; ------------------------------------------------------------
GameInit proc uses ebx esi edi
    ; xorshift32 seed (first time only)
    .if rngState == 0
        invoke GetTickCount
        mov rngState, eax
    .endif
    ; pick a random arena
    invoke RngBelow, ARENA_COUNT
    mov mapIndex, eax
    mov spawnCount, 0
    mov ecx, arenaTable[eax*4]
    invoke ParseArena, ecx
    call ResetTanks
    call InitKeyDefaults
    mov tanks[0*SIZEOF TANK].score, 0
    mov tanks[1*SIZEOF TANK].score, 0
    mov tanks[2*SIZEOF TANK].score, 0
    mov tanks[3*SIZEOF TANK].score, 0
    ret
GameInit endp

; ------------------------------------------------------------
; TileAtPx —— 取像素坐标所在格子的类型
; 入参：px, py；返回 eax = 格子类型（越界按钢墙）
; ------------------------------------------------------------
TileAtPx proc uses ebx px: dword, py: dword
    mov eax, px
    mov ebx, CELL
    xor edx, edx
    div ebx                          ; eax = 列
    mov ecx, eax
    mov eax, py
    xor edx, edx
    div ebx                          ; eax = 行
    .if ecx >= COLS || eax >= ROWS
        mov eax, TILE_STEEL
        ret
    .endif
    mov ebx, COLS
    imul eax, ebx
    add eax, ecx
    movzx eax, mapData[eax]
    ret
TileAtPx endp

; ------------------------------------------------------------
; SpawnBullet —— 按坦克朝向生成一颗子弹（§3：同屏每坦 <=10 发）
; 入参：ownerIdx = 玩家编号；弹池满 / 该坦弹满 / 坦克死亡则忽略
; ------------------------------------------------------------
SpawnBullet proc uses ebx esi edi ownerIdx: dword
    local ptank:dword
    mov edi, ownerIdx

    ; 统计该坦克同屏弹数（顺序固定遍历）
    xor eax, eax                     ; count
    xor ecx, ecx
    mov esi, offset bullets
CountLoop:
    .if ecx >= MAX_BULLETS
        jmp CountDone
    .endif
    cmp (BULLET ptr [esi]).active, 0
    je CountSkip
    cmp (BULLET ptr [esi]).owner, edi
    jne CountSkip
    inc eax
CountSkip:
    add esi, SIZEOF BULLET
    inc ecx
    jmp CountLoop
CountDone:
    .if eax >= MAX_PER_TANK
        ret                          ; 池满禁射
    .endif

    ; 坦克指针
    mov eax, edi
    mov ebx, SIZEOF TANK
    imul ebx, eax
    add ebx, offset tanks
    mov ptank, ebx
    mov eax, (TANK ptr [ebx]).alive
    .if eax == 0
        ret
    .endif

    ; 找空闲弹槽
    mov esi, offset bullets
    xor ecx, ecx
FindSlot:
    cmp (BULLET ptr [esi]).active, 0
    je SlotFound
    add esi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp FindSlot
    .endif
    ret                              ; 弹池满

SlotFound:
    ; 速度向量由朝向决定（vx/vy 只取 0 / ±BULLET_SPEED）
    mov eax, (TANK ptr [ebx]).dir
    xor edx, edx                     ; vx 候选
    xor ecx, ecx                     ; vy 候选
    .if eax == DIR_UP
        mov ecx, -BULLET_SPEED
    .elseif eax == DIR_RIGHT
        mov edx, BULLET_SPEED
    .elseif eax == DIR_DOWN
        mov ecx, BULLET_SPEED
    .else
        mov edx, -BULLET_SPEED
    .endif
    mov (BULLET ptr [esi]).vx, edx
    mov (BULLET ptr [esi]).vy, ecx
    ; 位置：坦克中心，弹体 8x8
    mov eax, (TANK ptr [ebx]).x
    add eax, (CELL - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).x, eax
    mov eax, (TANK ptr [ebx]).y
    add eax, (CELL - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).y, eax
    mov (BULLET ptr [esi]).owner, edi
    mov (BULLET ptr [esi]).active, 1
    mov (BULLET ptr [esi]).bounces, 0
    mov (BULLET ptr [esi]).age, 0
    ret
SpawnBullet endp

; ------------------------------------------------------------
; BounceOne —— 记一次反弹；反弹数 >= 上限则销毁子弹
; 入参：bp = 子弹指针
; ------------------------------------------------------------
BounceOne proc pb: dword
    mov eax, pb
    inc (BULLET ptr [eax]).bounces
    mov eax, (BULLET ptr [eax]).bounces
    .if eax >= BULLET_MAX_BOUNCE
        mov edx, pb
        mov (BULLET ptr [edx]).active, 0
    .endif
    ret
BounceOne endp

; ------------------------------------------------------------
; BulletWallHit -- 8x8 bullet vs terrain, 4-corner sampling
; in: pb = bullet ptr
; ret eax: 0=pass(water/ice/empty); 1=wall bounce (steel OR brick:
;          walls are INDESTRUCTIBLE per design change 2026-10-16)
; corner order fixed: TL, TR, BR, BL (deterministic for netplay)
; ------------------------------------------------------------
BulletWallHit proc uses ebx esi edi pb: dword
    local bx0:dword, by0:dword
    mov ebx, pb
    mov eax, (BULLET ptr [ebx]).x
    mov bx0, eax
    mov eax, (BULLET ptr [ebx]).y
    mov by0, eax

    xor esi, esi                     ; corner: 0=TL 1=TR 2=BR 3=BL
CornerLoop:
    mov eax, bx0
    mov edx, by0
    .if esi == 1 || esi == 2
        add eax, BULLET_SIZE_PX - 1
    .endif
    .if esi == 2 || esi == 3
        add edx, BULLET_SIZE_PX - 1
    .endif
    invoke TileAtPx, eax, edx
    .if eax == TILE_STEEL || eax == TILE_BRICK
        mov eax, 1
        jmp WHDone
    .endif                           ; water/ice/empty: pass through
    inc esi
    .if esi < 4
        jmp CornerLoop
    .endif
    xor eax, eax
WHDone:
    ret
BulletWallHit endp

; ------------------------------------------------------------
; MoveTank —— 坦克移动（水/钢/砖实心，冰可通行）
; 冰面：位移成功且中心格是冰 -> 刷新滑行 tick（6..10）与滑行方向
; ------------------------------------------------------------
MoveTank proc ownerIdx: dword, wantDir: dword
    local nx:dword, ny:dword, solid:dword, ptank:dword, dirL:dword
    ; ptank = &tanks[ownerIdx]（跨 invoke 保存，用局部变量存指针）
    mov eax, ownerIdx
    mov ecx, SIZEOF TANK
    imul ecx, eax
    add ecx, offset tanks
    mov ptank, ecx
    mov eax, wantDir
    mov dirL, eax

    mov ecx, ptank
    mov edx, dirL
    mov (TANK ptr [ecx]).dir, edx            ; 转向即时生效

    ; 计算新坐标
    mov eax, (TANK ptr [ecx]).x
    mov nx, eax
    mov eax, (TANK ptr [ecx]).y
    mov ny, eax
    mov eax, dirL
    .if eax == DIR_UP
        sub ny, TANK_SPEED
    .elseif eax == DIR_DOWN
        add ny, TANK_SPEED
    .elseif eax == DIR_LEFT
        sub nx, TANK_SPEED
    .else
        add nx, TANK_SPEED
    .endif

    ; 迎风面中心点外 1px 采样
    mov solid, 0
    mov eax, dirL
    .if eax == DIR_UP
        mov eax, nx
        add eax, CELL/2
        mov ecx, ny
        dec ecx
        invoke TileAtPx, eax, ecx
    .elseif eax == DIR_DOWN
        mov eax, nx
        add eax, CELL/2
        mov ecx, ny
        add ecx, CELL
        invoke TileAtPx, eax, ecx
    .elseif eax == DIR_LEFT
        mov eax, nx
        dec eax
        mov ecx, ny
        add ecx, CELL/2
        invoke TileAtPx, eax, ecx
    .else
        mov eax, nx
        add eax, CELL
        mov ecx, ny
        add ecx, CELL/2
        invoke TileAtPx, eax, ecx
    .endif
    ; 钢/砖/水 实心；冰/空地可通行
    .if eax == TILE_STEEL || eax == TILE_BRICK || eax == TILE_WATER
        mov solid, 1
    .endif

    mov ecx, ptank
    .if solid == 0
        mov edx, nx
        mov (TANK ptr [ecx]).x, edx
        mov edx, ny
        mov (TANK ptr [ecx]).y, edx
        ; 冰面判定：坦克中心格
        mov eax, (TANK ptr [ecx]).x
        add eax, CELL/2
        mov edx, (TANK ptr [ecx]).y
        add edx, CELL/2
        invoke TileAtPx, eax, edx
        .if eax == TILE_ICE
            invoke RngBelow, ICE_SLIDE_RNG   ; 0..4
            add eax, ICE_SLIDE_MIN           ; 6..10 tick
            mov ecx, ptank
            mov edx, dirL
            mov (TANK ptr [ecx]).sdir, edx
            mov (TANK ptr [ecx]).slide, eax
        .else
            mov ecx, ptank
            mov (TANK ptr [ecx]).slide, 0
        .endif
    .else
        mov (TANK ptr [ecx]).slide, 0        ; 撞墙立即停滑
    .endif
    ret
MoveTank endp

; ------------------------------------------------------------
; GameUpdate —— 推进一个逻辑 tick
; ------------------------------------------------------------
GameUpdate proc uses ebx esi edi
    local dirWanted:dword

    ; ---- 任一坦克死亡时按 R 重新开始 ----
    xor ecx, ecx                       ; 存活数
    xor edx, edx
GUR_Count:
    .if edx >= numPlayers
        jmp GUR_CountDone
    .endif
    mov eax, edx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ebx, (TANK ptr [eax]).alive
    add ecx, ebx
    inc edx
    jmp GUR_Count
GUR_CountDone:
    .if ecx < numPlayers && inputRestart != 0
        invoke GameInit
        ret
    .endif

    ; ---- 各玩家槽位：移动 / 冰面滑行 / 开火 ----
    mov fireHappened, 0
    xor ebx, ebx                       ; slot（跨 invoke 保持）
GU_Slot:
    .if ebx >= numPlayers
        jmp GU_SlotsDone
    .endif
    mov esi, ebx
    imul esi, esi, 20                  ; esi = slot*5*4（输入表字节偏移）
    ; 方向选择
    mov dirWanted, -1
    mov eax, inputTable[esi]
    .if eax != 0
        mov dirWanted, DIR_UP
    .else
        mov eax, inputTable[esi+4]
        .if eax != 0
            mov dirWanted, DIR_DOWN
        .else
            mov eax, inputTable[esi+8]
            .if eax != 0
                mov dirWanted, DIR_LEFT
            .else
                mov eax, inputTable[esi+12]
                .if eax != 0
                    mov dirWanted, DIR_RIGHT
                .endif
            .endif
        .endif
    .endif
    mov eax, dirWanted
    .if eax != -1
        invoke MoveTank, ebx, eax
    .else
        ; 无输入 -> 冰面滑行
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax
        mov eax, (TANK ptr [edx]).slide
        .if eax > 0
            dec (TANK ptr [edx]).slide
            mov eax, (TANK ptr [edx]).sdir
            invoke MoveTank, ebx, eax
        .endif
    .endif
    ; 开火（冷却 20 tick）
    mov eax, inputTable[esi+16]
    .if eax != 0
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax
        mov eax, (TANK ptr [edx]).fireCd
        .if eax == 0
            mov eax, (TANK ptr [edx]).alive
            .if eax != 0
                invoke SpawnBullet, ebx
                mov eax, ebx
                imul eax, eax, SIZEOF TANK
                add eax, offset tanks
                mov edx, eax
                mov (TANK ptr [edx]).fireCd, FIRE_CD
                .if ebx == 0
                    mov fireHappened, 1
                .endif
            .endif
        .endif
    .endif
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edx, eax
    mov eax, (TANK ptr [edx]).fireCd
    .if eax > 0
        dec (TANK ptr [edx]).fireCd
    .endif
    inc ebx
    jmp GU_Slot
GU_SlotsDone:

    ; ---- 子弹更新（edi = &bullets[ebx]，遍历顺序固定）----
    ; 每 tick 顺序：age -> X 轴(边界->地形) -> Y 轴(边界->地形) -> 坦克命中
    xor ebx, ebx
    mov edi, offset bullets
BulletTick:
    mov eax, (BULLET ptr [edi]).active
    .if eax != 0
        ; 0) 寿命
        inc (BULLET ptr [edi]).age
        mov eax, (BULLET ptr [edi]).age
        .if eax >= BULLET_LIFE
            mov (BULLET ptr [edi]).active, 0
            jmp BulletNext
        .endif
        ; 1) X 轴
        mov eax, (BULLET ptr [edi]).vx
        .if eax != 0
            add (BULLET ptr [edi]).x, eax
            ; 屏幕边界反弹
            mov eax, (BULLET ptr [edi]).x
            .if eax < 0
                mov (BULLET ptr [edi]).x, 0
                neg (BULLET ptr [edi]).vx
                invoke BounceOne, edi
            .elseif eax > MAP_W - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).x, MAP_W - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vx
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi
                .if eax != 0            ; 1=钢 2=砖(已清子块)
                    mov eax, (BULLET ptr [edi]).vx
                    sub (BULLET ptr [edi]).x, eax   ; 回退
                    neg (BULLET ptr [edi]).vx       ; 反弹
                    invoke BounceOne, edi
                .endif
            .endif
            mov eax, (BULLET ptr [edi]).active
            .if eax == 0
                jmp BulletNext          ; 反弹次数耗尽
            .endif
        .endif
        ; 2) Y 轴
        mov eax, (BULLET ptr [edi]).vy
        .if eax != 0
            add (BULLET ptr [edi]).y, eax
            mov eax, (BULLET ptr [edi]).y
            .if eax < 0
                mov (BULLET ptr [edi]).y, 0
                neg (BULLET ptr [edi]).vy
                invoke BounceOne, edi
            .elseif eax > MAP_H - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).y, MAP_H - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vy
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi
                .if eax != 0
                    mov eax, (BULLET ptr [edi]).vy
                    sub (BULLET ptr [edi]).y, eax
                    neg (BULLET ptr [edi]).vy
                    invoke BounceOne, edi
                .endif
            .endif
            mov eax, (BULLET ptr [edi]).active
            .if eax == 0
                jmp BulletNext
            .endif
        .endif
        ; 3) 命中坦克：跳过 owner 与死者，slot 0..3 顺序固定
        ;    自己的弹打自己不结算（FFA：其他任何人的弹都伤你）
        xor esi, esi
TankHitLoop:
        .if esi >= MAX_PLAYERS
            jmp TankHitDone
        .endif
        mov eax, (BULLET ptr [edi]).owner
        .if eax == esi
            jmp TankNext2
        .endif
        mov eax, esi
        imul eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax                    ; edx = &tanks[esi]（此段无 invoke）
        mov eax, (TANK ptr [edx]).alive
        .if eax == 0
            jmp TankNext2
        .endif
        ; AABB：弹体 8x8 (x,y,+8,+8) vs 坦克 32x32
        mov eax, (TANK ptr [edx]).x
        add eax, CELL
        mov ecx, (BULLET ptr [edi]).x
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).x
        mov ecx, (BULLET ptr [edi]).x
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).y
        add eax, CELL
        mov ecx, (BULLET ptr [edi]).y
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).y
        mov ecx, (BULLET ptr [edi]).y
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        ; 命中：扣血、销毁子弹
        dec (TANK ptr [edx]).hp
        mov (BULLET ptr [edi]).active, 0
        mov eax, (TANK ptr [edx]).hp
        .if eax <= 0
            mov (TANK ptr [edx]).alive, 0
        .endif
        jmp BulletNext
TankNext2:
        inc esi
        jmp TankHitLoop
TankHitDone:
BulletNext:
    .endif
    add edi, SIZEOF BULLET
    inc ebx
    .if ebx < MAX_BULLETS
        jmp BulletTick
    .endif

    ; ---- 回合计分：只剩 1 辆存活 且 已毁坦克的子弹全部消失 ----
    ; 满足 -> 存活者 +1 分并定格 ROUND_PAUSE_TICKS；全灭 -> 不加分只定格
    .if roundOver != 0
        dec roundTimer
        .if roundTimer == 0
            call ResetTanks             ; 开新一轮（不清比分）
        .endif
        jmp GU_Done
    .endif
    ; 存活统计（slot 0..3 顺序固定）
    xor eax, eax                        ; eax = 存活数
    xor esi, esi                        ; esi = 幸存者槽位
    xor ebx, ebx
SC_Alive:
    .if ebx >= MAX_PLAYERS
        jmp SC_AliveDone
    .endif
    mov edx, ebx
    imul edx, edx, SIZEOF TANK
    add edx, offset tanks
    mov ecx, (TANK ptr [edx]).alive
    .if ecx != 0
        inc eax
        mov esi, ebx
    .endif
    inc ebx
    jmp SC_Alive
SC_AliveDone:
    .if eax > 1
        jmp GU_Done                     ; 多车存活：不判分
    .endif
    ; 已毁坦克的子弹是否全部消失（弹序固定）
    xor ebx, ebx
SC_Bul:
    .if ebx >= MAX_BULLETS
        jmp SC_BulDone
    .endif
    mov edx, ebx
    shl edx, 5                          ; * SIZEOF BULLET(32)
    add edx, offset bullets
    mov ecx, (BULLET ptr [edx]).active
    .if ecx != 0
        mov ecx, (BULLET ptr [edx]).owner
        imul ecx, ecx, SIZEOF TANK
        add ecx, offset tanks
        mov edx, (TANK ptr [ecx]).alive
        .if edx == 0
            jmp GU_Done                 ; 亡者的弹还在飞：不判分
        .endif
    .endif
    inc ebx
    jmp SC_Bul
SC_BulDone:
    ; 条件成立：幸存者加分（同归于尽不加）
    .if eax == 1 && roundScored == 0
        mov edx, esi
        imul edx, edx, SIZEOF TANK
        add edx, offset tanks
        inc (TANK ptr [edx]).score
    .endif
    mov roundScored, 1
    mov roundOver, 1
    mov roundTimer, ROUND_PAUSE_TICKS
GU_Done:
    ret
GameUpdate endp

end
