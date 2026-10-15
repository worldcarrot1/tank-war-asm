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

; ---- 输入快照（本模块定义，input.asm 写入）----
public inputUp
public inputDown
public inputLeft
public inputRight
public inputFire
public inputRestart
public input2Up
public input2Down
public input2Left
public input2Right
public input2Fire

; ---- 游戏状态（本模块定义，gfx.asm / net.asm 读取）----
public tanks
public bullets
public mapData
public brickMask
public mapIndex
public SpawnBullet
public GameInit
public GameUpdate
public fireHappened
public seqSelf
public SelfTestRun

.data
    tanks       TANK MAX_PLAYERS dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)
    brickMask   db COLS*ROWS dup(0)  ; 砖格子块占用位（每格 4 bit）
    spawnX      dd 4 dup (0)         ; 出生点像素坐标（字符画 'S'）
    spawnY      dd 4 dup (0)
    spawnCount  dd 0
    mapIndex    dd 0                 ; 当前 ARENA 编号
    inputUp      dd 0
    inputDown    dd 0
    inputLeft    dd 0
    inputRight   dd 0
    inputFire    dd 0
    inputRestart dd 0
    input2Up     dd 0                ; P2（方向键 + Enter）
    input2Down   dd 0
    input2Left   dd 0
    input2Right  dd 0
    input2Fire   dd 0
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick P1 是否开火（发包 flag 用）
    rngState    dd 0                 ; xorshift32 状态

; ---- 字符画对战地图（20x15 字符/张，编译期嵌入）----
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  S 出生点
ARENA1 db "####################"
       db "#S.b............b.S#"
       db "#..................#"
       db "#..##..........##..#"
       db "#..#............#..#"
       db "#.....b--##--b.....#"
       db "#......~.##.~......#"
       db "#.##............##.#"
       db "#.##...b....b...##.#"
       db "#......#....#......#"
       db "#..b............b..#"
       db "#......-....-......#"
       db "#..................#"
       db "#S.b............b.S#"
       db "####################"
ARENA2 db "####################"
       db "#S..-..........-..S#"
       db "#....#........#....#"
       db "#..b.#..~~~~..#.b..#"
       db "#....#........#....#"
       db "#.##............##.#"
       db "#.........--.......#"
       db "#..~~...b##b...~~..#"
       db "#.........--.......#"
       db "#.##............##.#"
       db "#....#........#....#"
       db "#..b.#..~~~~..#.b..#"
       db "#....#........#....#"
       db "#S..-..........-..S#"
       db "####################"
ARENA3 db "####################"
       db "#S.b............b.S#"
       db "#..................#"
       db "#...##........##...#"
       db "#...#..........#...#"
       db "#...#...-..-...#...#"
       db "#.......~~~~.......#"
       db "#..b...~.##.~...b..#"
       db "#.......~~~~.......#"
       db "#...#...-..-...#...#"
       db "#...#..........#...#"
       db "#...##........##...#"
       db "#..................#"
       db "#S.b............b.S#"
       db "####################"
ARENA4 db "####################"
       db "#S.b..--....--..b.S#"
       db "#..................#"
       db "#.bb..#.~~~~.#..bb.#"
       db "#.....#......#.....#"
       db "#..#..#.-bb-.#..#..#"
       db "#..#.....##.....#..#"
       db "#..#............#..#"
       db "#..#.....##.....#..#"
       db "#..#..#.-bb-.#..#..#"
       db "#.....#......#.....#"
       db "#.bb..#.~~~~.#..bb.#"
       db "#..................#"
       db "#S.b..--....--..b.S#"
       db "####################"
ARENA5 db "####################"
       db "#S.b......#.....b.S#"
       db "#..b............b..#"
       db "#.....b......b.....#"
       db "#.##............##.#"
       db "#.##...######...##.#"
       db "#......#....#......#"
       db "#......#.--.#......#"
       db "#......#....#......#"
       db "#.##...######...##.#"
       db "#.##............##.#"
       db "#.....b......b.....#"
       db "#..b............b..#"
       db "#S.b......#.....b.S#"
       db "####################"

arenaTable dd ARENA1, ARENA2, ARENA3, ARENA4, ARENA5
    logName     db "selftest.log", 0
    selftestArg db "selftest"
    nlStr       db 13, 10
    logHandle   dd 0
    written     dd 0
    logVal      dd 0
    logBuf      db 64 dup (0)
    stT1  db "T1_P1_X="
    stT2  db "T2_ACTIVE_AFTER_FIRE="
    stT3  db "T3_ACTIVE_AFTER_620TICKS="
    stT4a db "T4_BRICK36_EMPTY_AT_TICK="
    stT4b db "T4_BRICK36_TILE="
    stT4c db "T4_BRICK36_MASK="
    stT4d db "T4_ACTIVE_AFTER_DRAIN="
    stT5  db "T5_TANK_BOTTOM_ABOVE_WATER(expect<192)="
    stT6  db "T6_SLIDE_DX_5TICKS(expect>0)="
    stT7  db "T7_P2_Y(expect<416)="
    stT8  db "T8_BULLETS_AFTER_15FIRE(expect<=10)="
    stT9a db "T9_P2_DEAD_AT_TICK="
    stT9b db "T9_P2_ALIVE(expect0)="
    stT9c db "T9_P2_HP(expect0)="

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
    .if dl == TILE_BRICK
        mov byte ptr brickMask[ebx], BRICK_FULL
    .else
        mov byte ptr brickMask[ebx], 0
    .endif
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
    ; tank0 = spawn 0 (top-left, facing down)
    mov eax, spawnX[0]
    mov tanks[0*SIZEOF TANK].x, eax
    mov eax, spawnY[0]
    mov tanks[0*SIZEOF TANK].y, eax
    mov tanks[0*SIZEOF TANK].dir, DIR_DOWN
    mov tanks[0*SIZEOF TANK].alive, 1
    ; tank1 = spawn 3 (opposite corner, facing up)
    mov ebx, 3
    .if spawnCount < 4
        mov ebx, 1
    .endif
    mov eax, spawnX[ebx*4]
    mov tanks[1*SIZEOF TANK].x, eax
    mov eax, spawnY[ebx*4]
    mov tanks[1*SIZEOF TANK].y, eax
    mov tanks[1*SIZEOF TANK].dir, DIR_UP
    mov tanks[1*SIZEOF TANK].alive, 1
    ; clear bullet pool
    xor eax, eax
    mov ecx, MAX_BULLETS*(SIZEOF BULLET)/4
    lea edi, bullets
RTClearB:
    mov [edi], eax
    add edi, 4
    loop RTClearB
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
    ; fixed map for determinism
    mov rngState, 1
    mov spawnCount, 0
    invoke ParseArena, offset ARENA1
    call ResetTanks
    call OpenLog

    ; T1: P1 movement (simulated inputRight, 40 ticks)
    mov inputRight, 1
    invoke AdvanceTicks, 40
    mov inputRight, 0
    invoke LogStr, offset stT1, 8
    invoke LogNum, tanks[0*SIZEOF TANK].x          ; expect 112

    ; T2: P1 fire -> one bullet in flight
    mov inputFire, 1
    invoke GameUpdate
    mov inputFire, 0
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT2, 21
    invoke LogNum, logVal                             ; expect 1

    ; T3: bullet lifetime -- 620 ticks later none active
    invoke AdvanceTicks, 620
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT3, 25
    invoke LogNum, logVal                             ; expect 0

    ; T4: brick eat-through (ARENA1 cell 36 = row1 col16)
    mov tanks[0*SIZEOF TANK].x, 512
    mov tanks[0*SIZEOF TANK].y, 64
    mov tanks[0*SIZEOF TANK].dir, DIR_UP
    mov inputFire, 1
    invoke GameUpdate
    mov inputFire, 0
    xor esi, esi
T4Loop:
    .if esi >= 400
        jmp T4Done
    .endif
    invoke GameUpdate
    inc esi
    cmp mapData[36], TILE_EMPTY
    jne T4Loop
T4Done:
    invoke LogStr, offset stT4a, 25
    invoke LogNum, esi                             ; ticks until hole
    movzx eax, mapData[36]
    mov logVal, eax
    invoke LogStr, offset stT4b, 16
    invoke LogNum, logVal                             ; expect 0 (empty)
    movzx eax, brickMask[36]
    mov logVal, eax
    invoke LogStr, offset stT4c, 16
    invoke LogNum, logVal                             ; expect 0 (4 bits gone)
    invoke AdvanceTicks, 640
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT4d, 22
    invoke LogNum, logVal                             ; expect 0

    ; T5: water blocks tank (tank bottom must stay < 192)
    mov tanks[0*SIZEOF TANK].x, 224
    mov tanks[0*SIZEOF TANK].y, 128
    mov inputDown, 1
    invoke AdvanceTicks, 30
    mov inputDown, 0
    mov eax, tanks[0*SIZEOF TANK].y
    add eax, CELL
    mov logVal, eax
    invoke LogStr, offset stT5, 39
    invoke LogNum, logVal                             ; expect 158 (<192)

    ; T6: ice slide (1 input tick then coast 5 ticks, dx>0)
    mov tanks[0*SIZEOF TANK].x, 224
    mov tanks[0*SIZEOF TANK].y, 352
    mov inputRight, 1
    invoke GameUpdate
    mov inputRight, 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov ebx, eax
    invoke AdvanceTicks, 5
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, ebx
    mov logVal, eax
    invoke LogStr, offset stT6, 29
    invoke LogNum, logVal                             ; expect 8..20

    ; T7: P2 movement (arrow keys drive tank1)
    call ResetTanks
    mov input2Up, 1
    invoke AdvanceTicks, 20
    mov input2Up, 0
    invoke LogStr, offset stT7, 20
    invoke LogNum, tanks[1*SIZEOF TANK].y          ; expect 416-40=376

    ; T8: per-tank 10-bullet cap (15 rapid fires -> 10 alive)
    call ResetTanks
    mov ebx, 15
T8Loop:
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputFire, 1
    invoke GameUpdate
    mov inputFire, 0
    dec ebx
    .if ebx != 0
        jmp T8Loop
    .endif
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT8, 36
    invoke LogNum, logVal                             ; expect 10

    ; T9: kill via fire (3 hits needed) -- both on empty row2
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 64
    mov tanks[0*SIZEOF TANK].y, 64
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov tanks[1*SIZEOF TANK].x, 288
    mov tanks[1*SIZEOF TANK].y, 64
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputFire, 1
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
    mov inputFire, 0
    invoke LogStr, offset stT9a, 19
    invoke LogNum, esi                             ; kill tick (<300)
    invoke LogStr, offset stT9b, 21
    invoke LogNum, tanks[1*SIZEOF TANK].alive      ; expect 0
    invoke LogStr, offset stT9c, 18
    invoke LogNum, tanks[1*SIZEOF TANK].hp         ; expect 0

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
; ClearBrickBit -- clear sub-block bitIdx of cell cellIdx;
; when all 4 bits empty the tile becomes empty (bullet passes next time)
; ------------------------------------------------------------
ClearBrickBit proc cellIdx: dword, bitIdx: dword
    mov eax, 1
    mov ecx, bitIdx
    shl eax, cl                     ; eax = sub-block bitmask
    mov edx, cellIdx
    mov cl, brickMask[edx]
    not al
    and cl, al                      ; clear the bit
    mov brickMask[edx], cl
    .if cl == 0
        mov mapData[edx], TILE_EMPTY
    .endif
    ret
ClearBrickBit endp

; ------------------------------------------------------------
; BulletWallHit -- 8x8 bullet vs terrain, 4-corner sampling
; in: pb = bullet ptr, axis = 0(X move) / 1(Y move)
; ret eax: 0=pass; 1=steel bounce; 2=brick hit (sub-blocks cleared, bounce)
; brick rules:
;   - a corner whose own sub-block is already shot open passes through
;   - on hit: clear the sub-blocks swept by the leading edge (<=2 bits)
;   - whole cell empty -> tile becomes empty
; corner order fixed: TL, TR, BR, BL (deterministic for netplay)
; ------------------------------------------------------------
BulletWallHit proc uses ebx esi edi pb: dword, axis: dword
    local bx0:dword, by0:dword, cxL:dword, cyL:dword
    local cellIdx:dword, fx:dword, fy:dword
    mov ebx, pb
    mov eax, (BULLET ptr [ebx]).x
    mov bx0, eax
    mov eax, (BULLET ptr [ebx]).y
    mov by0, eax

    xor esi, esi                     ; corner: 0=TL 1=TR 2=BR 3=BL
CornerLoop:
    ; corner pixel coords -> cxL / cyL
    mov eax, bx0
    mov edx, by0
    .if esi == 1 || esi == 2
        add eax, BULLET_SIZE_PX - 1
    .endif
    .if esi == 2 || esi == 3
        add edx, BULLET_SIZE_PX - 1
    .endif
    mov cxL, eax
    mov cyL, edx
    invoke TileAtPx, eax, edx
    .if eax == TILE_STEEL
        mov eax, 1
        jmp WHDone
    .elseif eax == TILE_BRICK
        ; corner cell index
        mov eax, cxL
        shr eax, 5                   ; /CELL(32) -> col
        mov ecx, eax
        mov eax, cyL
        shr eax, 5                   ; row
        imul eax, eax, COLS
        add eax, ecx
        mov cellIdx, eax
        ; corner's own sub-block bit = row2*2 + col2
        mov eax, cyL
        and eax, CELL-1
        shr eax, 4
        lea eax, [eax+eax]
        mov ecx, eax
        mov eax, cxL
        and eax, CELL-1
        shr eax, 4
        add eax, ecx                 ; bit
        mov edx, cellIdx
        mov dh, brickMask[edx]       ; dh = mask byte
        mov cl, al
        mov al, 1
        shl al, cl                   ; corner bit mask
        and al, dh
        .if al == 0
            jmp WHPass               ; this sub-block already open -> pass
        .endif
        ; leading-edge coordinate
        .if axis == 0
            mov eax, (BULLET ptr [ebx]).vx
            .if eax > 0
                mov eax, bx0
                add eax, BULLET_SIZE_PX - 1
            .else
                mov eax, bx0
            .endif
            mov fx, eax              ; leading x -> sub-col
        .else
            mov eax, (BULLET ptr [ebx]).vy
            .if eax > 0
                mov eax, by0
                add eax, BULLET_SIZE_PX - 1
            .else
                mov eax, by0
            .endif
            mov fy, eax              ; leading y -> sub-row
        .endif
        ; clear sub-blocks swept by the leading edge (2 ends, <=2 bits)
        .if axis == 0
            mov eax, fx
            and eax, CELL-1
            shr eax, 4
            mov ecx, eax             ; col2
            mov eax, by0
            and eax, CELL-1
            shr eax, 4
            lea eax, [eax+eax]
            add eax, ecx             ; bit1 = rowA*2+col2
            invoke ClearBrickBit, cellIdx, eax
            mov eax, fx
            and eax, CELL-1
            shr eax, 4
            mov ecx, eax
            mov eax, by0
            add eax, BULLET_SIZE_PX - 1
            and eax, CELL-1
            shr eax, 4
            lea eax, [eax+eax]
            add eax, ecx             ; bit2 = rowB*2+col2
            invoke ClearBrickBit, cellIdx, eax
        .else
            mov eax, fy
            and eax, CELL-1
            shr eax, 4
            lea eax, [eax+eax]
            mov ecx, eax             ; row2*2
            mov eax, bx0
            and eax, CELL-1
            shr eax, 4
            add eax, ecx             ; bit1 = row2*2+colA
            invoke ClearBrickBit, cellIdx, eax
            mov eax, fy
            and eax, CELL-1
            shr eax, 4
            lea eax, [eax+eax]
            mov ecx, eax
            mov eax, bx0
            add eax, BULLET_SIZE_PX - 1
            and eax, CELL-1
            shr eax, 4
            add eax, ecx             ; bit2 = row2*2+colB
            invoke ClearBrickBit, cellIdx, eax
        .endif
        mov eax, 2
        jmp WHDone
    .endif                           ; water/ice/empty: pass through
WHPass:
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
    mov eax, tanks[0*SIZEOF TANK].alive
    .if eax != 0
        mov eax, tanks[1*SIZEOF TANK].alive
    .endif
    .if eax == 0 && inputRestart != 0
        invoke GameInit
        ret
    .endif

    ; ---- P1（WASD）：输入优先，无输入则冰面滑行 ----
    mov dirWanted, -1
    .if inputUp != 0
        mov dirWanted, DIR_UP
    .elseif inputDown != 0
        mov dirWanted, DIR_DOWN
    .elseif inputLeft != 0
        mov dirWanted, DIR_LEFT
    .elseif inputRight != 0
        mov dirWanted, DIR_RIGHT
    .endif
    mov eax, dirWanted
    .if eax != -1
        invoke MoveTank, 0, eax
    .elseif tanks[0*SIZEOF TANK].slide > 0
        dec tanks[0*SIZEOF TANK].slide
        mov eax, tanks[0*SIZEOF TANK].sdir
        invoke MoveTank, 0, eax
    .endif

    ; ---- P2（方向键）：本地对练第二坦克 ----
    mov dirWanted, -1
    .if input2Up != 0
        mov dirWanted, DIR_UP
    .elseif input2Down != 0
        mov dirWanted, DIR_DOWN
    .elseif input2Left != 0
        mov dirWanted, DIR_LEFT
    .elseif input2Right != 0
        mov dirWanted, DIR_RIGHT
    .endif
    mov eax, dirWanted
    .if eax != -1
        invoke MoveTank, 1, eax
    .elseif tanks[1*SIZEOF TANK].slide > 0
        dec tanks[1*SIZEOF TANK].slide
        mov eax, tanks[1*SIZEOF TANK].sdir
        invoke MoveTank, 1, eax
    .endif

    ; ---- 开火（P1 空格 / P2 Enter，冷却 20 tick）----
    mov fireHappened, 0
    .if tanks[0*SIZEOF TANK].fireCd == 0 && inputFire != 0 && tanks[0*SIZEOF TANK].alive != 0
        invoke SpawnBullet, 0
        mov tanks[0*SIZEOF TANK].fireCd, FIRE_CD
        mov fireHappened, 1
    .endif
    .if tanks[0*SIZEOF TANK].fireCd > 0
        dec tanks[0*SIZEOF TANK].fireCd
    .endif
    .if tanks[1*SIZEOF TANK].fireCd == 0 && input2Fire != 0 && tanks[1*SIZEOF TANK].alive != 0
        invoke SpawnBullet, 1
        mov tanks[1*SIZEOF TANK].fireCd, FIRE_CD
    .endif
    .if tanks[1*SIZEOF TANK].fireCd > 0
        dec tanks[1*SIZEOF TANK].fireCd
    .endif

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
            .elseif eax > WND_W - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).x, WND_W - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vx
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi, 0
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
            .elseif eax > WND_H - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).y, WND_H - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vy
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi, 1
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
    ret
GameUpdate endp

end
