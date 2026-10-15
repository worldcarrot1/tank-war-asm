; ============================================================
; game.asm —— 游戏逻辑核心
; 职责：维护 tanks[2] / bullets[MAX_BULLETS] / mapData，
;       每 tick 推进：移动 -> 开火 -> 子弹飞行 -> 碰撞 -> 胜负
;
; 本机状态完全自治，对方状态由 net.asm 收包后直接覆盖写入
 tanks[PLAYER_PEER]（状态同步模型，见 docs/PROTOCOL.md）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include windows.inc
include kernel32.inc
includelib kernel32.lib

include ..\inc\game.inc

; ---- 来自 input.asm 的输入快照 ----
extern inputUp      :dword
extern inputDown    :dword
extern inputLeft    :dword
extern inputRight   :dword
extern inputFire    :dword

; ---- 对外导出的游戏状态（gfx.asm / net.asm 读取）----
public tanks
public bullets
public mapData
; net.asm 收到对方开火时调用 SpawnBullet
public SpawnBullet
public fireHappened

.data
    tanks       TANK 2 dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)   ; 地图数组，gfx/net 模块引用
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick 是否开火（发包 flag 用）

.code

; ------------------------------------------------------------
; GameInit —— 硬编码测试地图 + 初始坦克位置
; 阶段 2 再改成从文件/网络上加载地图
; ------------------------------------------------------------
GameInit proc
    ; 地图：四周钢墙围一圈，中间摆几段砖墙
    ; （用行字符串思想，这里先手写填充循环，具体关卡后续再调）
    xor esi, esi
FillLoop:
    mov edi, esi
    xor edx, edx
    mov eax, esi
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
    ; 中间摆一段砖墙
    mov edi, ROWS/2
    imul edi, COLS
    add edi, 6
    mov ecx, 8
BrickRow:
    mov mapData[edi], TILE_BRICK
    inc edi
    loop BrickRow

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
; SpawnBullet —— 在指定玩家坦克位置生成一颗子弹
; 入参：eax = 玩家编号。找不到空闲槽位则忽略。
; GameUpdate（本端开火）和 net.asm（对方开火）都调用它。
; ------------------------------------------------------------
SpawnBullet proc ownerIdx: dword
    xor ecx, ecx
FindSlot:
    cmp bullets[ecx*SIZEOF BULLET].active, 0
    je SlotFound
    inc ecx
    .if ecx < MAX_BULLETS
        jmp FindSlot
    .endif
    ret                              ; 没有空位，丢弃
SlotFound:
    mov eax, ownerIdx
    mov bullets[ecx*SIZEOF BULLET].owner, eax
    mov edx, tanks[eax*SIZEOF TANK].x
    mov bullets[ecx*SIZEOF BULLET].x, edx
    mov edx, tanks[eax*SIZEOF TANK].y
    mov bullets[ecx*SIZEOF BULLET].y, edx
    mov edx, tanks[eax*SIZEOF TANK].dir
    mov bullets[ecx*SIZEOF BULLET].dir, edx
    mov bullets[ecx*SIZEOF BULLET].active, 1
    ret
SpawnBullet endp

; ------------------------------------------------------------
; MoveTank —— 按输入尝试移动一辆坦克，并做地图碰撞
; 入参：eax = 玩家编号, ebx = 输入方向（-1 表示无移动输入）
; ------------------------------------------------------------
MoveTank proc ownerIdx: dword, wantDir: dword
    local nx:dword, ny:dword
    mov eax, ownerIdx
    ; 转向即时生效
    mov edx, wantDir
    mov tanks[eax*SIZEOF TANK].dir, edx
    ; 计算位移增量
    .if edx == DIR_UP
        mov edx, -TANK_SPEED
        add tanks[eax*SIZEOF TANK].y, edx
    .elseif edx == DIR_DOWN
        mov edx, TANK_SPEED
        add tanks[eax*SIZEOF TANK].y, edx
    .elseif edx == DIR_LEFT
        mov edx, -TANK_SPEED
        add tanks[eax*SIZEOF TANK].x, edx
    .elseif edx == DIR_RIGHT
        mov edx, TANK_SPEED
        add tanks[eax*SIZEOF TANK].x, edx
    .endif
    ; 越界回退（粗粒度碰撞，撞墙检测阶段 2 再细化）
    mov eax, ownerIdx
    mov edx, tanks[eax*SIZEOF TANK].x
    .if edx < CELL
        mov tanks[eax*SIZEOF TANK].x, CELL
    .endif
    mov edx, tanks[eax*SIZEOF TANK].y
    .if edx < CELL
        mov tanks[eax*SIZEOF TANK].y, CELL
    .endif
    mov edx, tanks[eax*SIZEOF TANK].x
    .if edx > WND_W - CELL*2
        mov tanks[eax*SIZEOF TANK].x, WND_W - CELL*2
    .endif
    mov edx, tanks[eax*SIZEOF TANK].y
    .if edx > WND_H - CELL*2
        mov tanks[eax*SIZEOF TANK].y, WND_H - CELL*2
    .endif
    ret
MoveTank endp

; ------------------------------------------------------------
; GameUpdate —— 推进一个逻辑 tick
; ------------------------------------------------------------
GameUpdate proc
    local dirWanted:dword

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

    ; ---- 子弹飞行 + 出界销毁 ----
    xor ecx, ecx
BulletTick:
    .if bullets[ecx*SIZEOF BULLET].active != 0
        mov eax, bullets[ecx*SIZEOF BULLET].dir
        .if eax == DIR_UP
            sub bullets[ecx*SIZEOF BULLET].y, BULLET_SPEED
        .elseif eax == DIR_DOWN
            add bullets[ecx*SIZEOF BULLET].y, BULLET_SPEED
        .elseif eax == DIR_LEFT
            sub bullets[ecx*SIZEOF BULLET].x, BULLET_SPEED
        .else
            add bullets[ecx*SIZEOF BULLET].x, BULLET_SPEED
        .endif
        ; 简化：出界即销毁；命中坦克/墙的阶段 2 实现
        mov eax, bullets[ecx*SIZEOF BULLET].x
        .if eax < 0 || eax > WND_W
            mov bullets[ecx*SIZEOF BULLET].active, 0
        .endif
        mov eax, bullets[ecx*SIZEOF BULLET].y
        .if eax < 0 || eax > WND_H
            mov bullets[ecx*SIZEOF BULLET].active, 0
        .endif
    .endif
    inc ecx
    .if ecx < MAX_BULLETS
        jmp BulletTick
    .endif
    ret
GameUpdate endp

end
