; ============================================================
; game.asm —— 游戏逻辑核心
; 职责：维护 tanks[2] / bullets[MAX_BULLETS] / mapData，
;       每 tick 推进：移动 -> 开火 -> 子弹飞行 -> 碰撞 -> 胜负
;
; 本机状态完全自治，对方状态由 net.asm 收包后直接覆盖写入
; tanks[PLAYER_PEER]（状态同步模型，见 docs/PROTOCOL.md）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

; ---- 输入快照（本模块定义，input.asm 写入）----
public inputUp
public inputDown
public inputLeft
public inputRight
public inputFire
public inputRestart

; ---- 游戏状态（本模块定义，gfx.asm / net.asm 读取）----
public tanks
public bullets
public mapData
public SpawnBullet
public GameInit
public GameUpdate
public fireHappened
public seqSelf

.data
    tanks       TANK 2 dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)   ; 地图数组，gfx/net 模块引用
    inputUp      dd 0
    inputDown    dd 0
    inputLeft    dd 0
    inputRight   dd 0
    inputFire    dd 0
    inputRestart dd 0
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick 是否开火（发包 flag 用）

.code

; ------------------------------------------------------------
; GameInit —— 硬编码测试地图 + 初始坦克位置
; 阶段 2 再改成从文件/网络上加载地图
; ------------------------------------------------------------
GameInit proc
    ; 地图：四周钢墙围一圈，中间空地
    xor esi, esi
FillLoop:
    mov eax, esi
    xor edx, edx
    mov ebx, COLS
    div ebx                          ; eax=行 edx=列
    .if edx == 0 || edx == COLS-1 || eax == 0 || eax == ROWS-1
        mov mapData[esi], TILE_STEEL
    .else
        mov mapData[esi], TILE_EMPTY
    .endif
    inc esi
    .if esi < COLS*ROWS
        jmp FillLoop
    .endif

    ; 中段横砖墙：第 ROWS/2 行，第 6..13 列
    mov edi, (ROWS/2)*COLS + 6
    mov ecx, 8
BrickRow:
    mov mapData[edi], TILE_BRICK
    inc edi
    loop BrickRow
    ; 两段竖砖墙：第 4、15 列，第 4..10 行
    mov ecx, 7
    mov edi, 4*COLS + 4
VBrick1:
    mov mapData[edi], TILE_BRICK
    add edi, COLS
    loop VBrick1
    mov ecx, 7
    mov edi, 4*COLS + 15
VBrick2:
    mov mapData[edi], TILE_BRICK
    add edi, COLS
    loop VBrick2

    ; 己方坦克：左下角，朝上
    mov tanks[PLAYER_SELF*SIZEOF TANK].x, CELL*2
    mov tanks[PLAYER_SELF*SIZEOF TANK].y, CELL*(ROWS-2)
    mov tanks[PLAYER_SELF*SIZEOF TANK].dir, DIR_UP
    mov tanks[PLAYER_SELF*SIZEOF TANK].hp, TANK_HP
    mov tanks[PLAYER_SELF*SIZEOF TANK].alive, 1
    mov tanks[PLAYER_SELF*SIZEOF TANK].fireCd, 0

    ; 对方坦克：右上角，朝下（等待联机后由对方数据覆盖）
    mov tanks[PLAYER_PEER*SIZEOF TANK].x, CELL*(COLS-3)
    mov tanks[PLAYER_PEER*SIZEOF TANK].y, CELL*1
    mov tanks[PLAYER_PEER*SIZEOF TANK].dir, DIR_DOWN
    mov tanks[PLAYER_PEER*SIZEOF TANK].hp, TANK_HP
    mov tanks[PLAYER_PEER*SIZEOF TANK].alive, 1
    mov tanks[PLAYER_PEER*SIZEOF TANK].fireCd, 0

    ; 清空子弹池
    xor eax, eax
    mov ecx, MAX_BULLETS*SIZEOF BULLET
    lea edi, bullets
ClearBullets:
    mov [edi], eax
    add edi, 4
    loop ClearBullets

    mov seqSelf, 0
    mov fireHappened, 0
    ret
GameInit endp

; ------------------------------------------------------------
; TileAtPx —— 取像素坐标所在格子的类型
; 入参：px=像素x, py=像素y；返回 eax = 格子类型（越界按钢墙）
; ------------------------------------------------------------
TileAtPx proc uses ebx px: dword, py: dword
    mov eax, px
    mov ebx, CELL
    xor edx, edx
    div ebx                          ; eax = 列
    mov ecx, eax                     ; 暂存列
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
; ClearTileAtPx —— 把像素坐标所在格子改回空地（砖块被打掉）
; ------------------------------------------------------------
ClearTileAtPx proc uses ebx esi px: dword, py: dword
    mov eax, px
    mov ebx, CELL
    xor edx, edx
    div ebx                          ; eax = 列
    mov esi, eax
    mov eax, py
    xor edx, edx
    div ebx                          ; eax = 行
    mov ecx, COLS
    imul eax, ecx
    add eax, esi
    mov mapData[eax], TILE_EMPTY
    ret
ClearTileAtPx endp

; ------------------------------------------------------------
; SpawnBullet —— 在指定玩家坦克位置生成一颗子弹
; 入参：ownerIdx = 玩家编号。找不到空闲槽位则忽略。
; GameUpdate（本端开火）和 net.asm（对方开火）都调用它。
; ------------------------------------------------------------
SpawnBullet proc uses ebx esi ownerIdx: dword
    mov esi, offset bullets              ; esi = &bullets[ecx]
    xor ecx, ecx
FindSlot:
    cmp (BULLET ptr [esi]).active, 0
    je SlotFound
    add esi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp FindSlot
    .endif
    ret                              ; 没有空位，丢弃
SlotFound:
    mov eax, ownerIdx
    mov ebx, SIZEOF TANK
    imul ebx, eax
    add ebx, offset tanks                ; ebx = &tanks[ownerIdx]
    mov (BULLET ptr [esi]).owner, eax
    mov edx, (TANK ptr [ebx]).x
    mov (BULLET ptr [esi]).x, edx
    mov edx, (TANK ptr [ebx]).y
    mov (BULLET ptr [esi]).y, edx
    mov edx, (TANK ptr [ebx]).dir
    mov (BULLET ptr [esi]).dir, edx
    mov (BULLET ptr [esi]).active, 1
    ret
SpawnBullet endp

; ------------------------------------------------------------
; MoveTank —— 按输入移动一辆坦克（转向即时生效，撞墙不动）
; 检查逻辑：先按方向算出新位置 nx/ny，采样新位置「迎风面」
; 中心点外 1 像素处是否为实心格子，实心则不位移。
; （地图四周边界全是钢墙，越界防护由碰撞天然完成）
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

    ; 迎风面中心点外 1px 采样（与子弹中心同款算法）
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
    .if eax != TILE_EMPTY
        mov solid, 1
    .endif

    mov ecx, ptank
    .if solid == 0
        mov edx, nx
        mov (TANK ptr [ecx]).x, edx
        mov edx, ny
        mov (TANK ptr [ecx]).y, edx
    .endif
    ret
MoveTank endp

; ------------------------------------------------------------
; GameUpdate —— 推进一个逻辑 tick
; ------------------------------------------------------------
GameUpdate proc uses ebx esi edi
    local dirWanted:dword

    ; ---- 己方死亡时按 R 重新开始 ----
    .if tanks[PLAYER_SELF*SIZEOF TANK].alive == 0 && inputRestart != 0
        call GameInit
        ret
    .endif

    ; ---- 己方坦克：按输入选方向 ----
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
    .if dirWanted != -1
        invoke MoveTank, PLAYER_SELF, dirWanted
    .endif

    ; ---- 开火 ----
    mov fireHappened, 0
    .if tanks[PLAYER_SELF*SIZEOF TANK].fireCd == 0 && inputFire != 0
        invoke SpawnBullet, PLAYER_SELF
        mov tanks[PLAYER_SELF*SIZEOF TANK].fireCd, 20  ; 约 0.33s 冷却
        mov fireHappened, 1
    .endif
    .if tanks[PLAYER_SELF*SIZEOF TANK].fireCd > 0
        dec tanks[PLAYER_SELF*SIZEOF TANK].fireCd
    .endif

    ; ---- 子弹：飞行 + 撞墙 + 命中坦克 ----
    ; edi = &bullets[ebx]，ebx = 槽位号（edi/ebx 跨 invoke 保持）
    xor ebx, ebx
    mov edi, offset bullets
BulletTick:
    mov eax, (BULLET ptr [edi]).active
    .if eax != 0
        ; 1) 位移
        mov eax, (BULLET ptr [edi]).dir
        .if eax == DIR_UP
            sub (BULLET ptr [edi]).y, BULLET_SPEED
        .elseif eax == DIR_DOWN
            add (BULLET ptr [edi]).y, BULLET_SPEED
        .elseif eax == DIR_LEFT
            sub (BULLET ptr [edi]).x, BULLET_SPEED
        .else
            add (BULLET ptr [edi]).x, BULLET_SPEED
        .endif

        ; 2) 撞墙检测：子弹中心点所在格子
        mov eax, (BULLET ptr [edi]).x
        add eax, CELL/2
        mov ecx, (BULLET ptr [edi]).y
        add ecx, CELL/2
        invoke TileAtPx, eax, ecx
        .if eax != TILE_EMPTY
            .if eax == TILE_BRICK
                mov eax, (BULLET ptr [edi]).x
                add eax, CELL/2
                mov ecx, (BULLET ptr [edi]).y
                add ecx, CELL/2
                invoke ClearTileAtPx, eax, ecx   ; 砖墙被打掉
            .endif
            mov (BULLET ptr [edi]).active, 0
            jmp BulletNext
        .endif

        ; 3) 命中坦克检测：只检测 owner 的对手
        ;    edx = &目标坦克（此段无 invoke，edx 一直有效）
        mov eax, (BULLET ptr [edi]).owner
        xor eax, 1
        mov esi, eax
        mov eax, SIZEOF TANK
        imul eax, esi
        add eax, offset tanks
        mov edx, eax
        mov eax, (TANK ptr [edx]).alive
        .if eax != 0
            ; 子弹 8x8 矩形（中心对齐格子中心） vs 坦克 32x32 AABB
            mov eax, (TANK ptr [edx]).x
            add eax, CELL                     ; 坦克右边界
            mov ecx, (BULLET ptr [edi]).x
            add ecx, CELL/2 - 4               ; 子弹左
            .if ecx >= eax                    ; 子弹左 >= 坦克右 -> 未命中
                jmp NoHit
            .endif
            mov eax, (TANK ptr [edx]).x
            mov ecx, (BULLET ptr [edi]).x
            add ecx, CELL/2 + 4               ; 子弹右
            .if ecx <= eax                    ; 子弹右 <= 坦克左 -> 未命中
                jmp NoHit
            .endif
            mov eax, (TANK ptr [edx]).y
            add eax, CELL                     ; 坦克下边界
            mov ecx, (BULLET ptr [edi]).y
            add ecx, CELL/2 - 4               ; 子弹上
            .if ecx >= eax
                jmp NoHit
            .endif
            mov eax, (TANK ptr [edx]).y
            mov ecx, (BULLET ptr [edi]).y
            add ecx, CELL/2 + 4               ; 子弹下
            .if ecx <= eax
                jmp NoHit
            .endif
            ; 命中：扣血、销毁子弹
            dec (TANK ptr [edx]).hp
            mov (BULLET ptr [edi]).active, 0
            mov eax, (TANK ptr [edx]).hp
            .if eax <= 0
                mov (TANK ptr [edx]).alive, 0
            .endif
NoHit:
        .endif
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
