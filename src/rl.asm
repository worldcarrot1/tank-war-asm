; ============================================================
; rl.asm —— 会话47：RL 训练环境导出层（tankwar_rl.dll）
; 把游戏逻辑当 gym 环境喂给 Python：
;   RL_Reset(seed)        新开一局（seed 注入 rng 双流，确定性可复现）
;   RL_SetAct(slot,...)   写某槽 6 键输入电平（策略槽用）
;   RL_Tick(n)            无头推进 n 个逻辑 tick（含人机槽 BotThink）
;   RL_Ptrs(buf)          输出全局数据地址+地图常量（ctypes 直接读）
;   RL_Meta(buf)          输出 TANK/BULLET 字段偏移（防结构漂移）
; 布局约定：slot0=RL 策略，slot1=现有启发式 bot 陪练（botMask=2）。
; 桩依赖见 rl_stub.asm。导出名去修饰走 rl.def。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

; ---- 同工程模块接口 ----
GameInit    PROTO
GameUpdate  PROTO
BotReset    PROTO
extern tanks       :TANK
extern bullets     :BULLET
extern mapData     :byte
extern mapIndex    :dword
extern inputTable  :dword
extern gTick       :dword
extern rngMatch    :dword
extern rngSeedOvr  :dword
extern pickupType  :dword
extern pickupX     :dword
extern pickupY     :dword
extern pickupTimer :dword
extern matchOver   :dword
extern roundsPlayed:dword
extern maxRounds   :dword
extern botMask     :dword
extern achvNoSave  :dword
extern netMode     :dword
extern numPlayers  :dword
extern onlineBanT  :dword

.code

; ------------------------------------------------------------
; RL_Reset(seed) —— 重开一局。seed!=0 注入确定性；0=时间播种。
; 返回 rngMatch 实际值（Python 侧记录复现种子）。
; ------------------------------------------------------------
RL_Reset proc stdcall seed:DWORD
    mov eax, seed
    mov rngSeedOvr, eax
    mov achvNoSave, 1                  ; 训练进程永不写成就档
    mov numPlayers, 2
    mov netMode, 0
    mov onlineBanT, 0
    invoke GameInit
    mov botMask, 2                     ; GameInit 后统一置位：slot1=启发式陪练
    mov eax, rngMatch
    ret
RL_Reset endp

; ------------------------------------------------------------
; RL_SetAct(slot, fwd, back, ccw, cw, fire, skill)
; 写 inputTable[slot*KEY_PER + 0..5]，0/1 电平（真人同通道）。
; ------------------------------------------------------------
RL_SetAct proc stdcall uses ebx esi pSlot:DWORD, pf:DWORD, pb:DWORD, pccw:DWORD, pcw:DWORD, pfire:DWORD, psk:DWORD
    lea esi, inputTable
    mov eax, pSlot
    imul eax, eax, KEY_PER
    lea esi, [esi + eax*4]
    mov eax, pf
    mov [esi+0], eax
    mov eax, pb
    mov [esi+4], eax
    mov eax, pccw
    mov [esi+8], eax
    mov eax, pcw
    mov [esi+12], eax
    mov eax, pfire
    mov [esi+16], eax
    mov eax, psk
    mov [esi+20], eax
    ret
RL_SetAct endp

; ------------------------------------------------------------
; RL_Tick(n) —— 推进 n 个 tick；返回 gTick。
; ------------------------------------------------------------
RL_Tick proc stdcall n:DWORD
    mov ecx, n
    test ecx, ecx
    jle RT_Done
RT_Loop:
    invoke GameUpdate
    dec ecx
    jg RT_Loop
RT_Done:
    mov eax, gTick
    ret
RL_Tick endp

; ------------------------------------------------------------
; RL_Ptrs(buf) —— 填 32 个 dword：前 16 个为数据地址，后 16 个为常量。
; 顺序（与 tools/rl_env.py 表对齐，只增不改）：
;  [0]tanks [1]bullets [2]mapData [3]mapIndex [4]inputTable [5]gTick
;  [6]rngMatch [7]pickupType [8]pickupX [9]pickupY [10]pickupTimer
;  [11]matchOver [12]roundsPlayed [13]maxRounds [14]botMask [15]gTick别名
;  [16]COLS [17]ROWS [18]CELL [19]MAP_W [20]MAP_H [21]MAX_BULLETS
;  [22]MAX_PLAYERS [23]KEY_PER [24]TILE_EMPTY [25]TILE_BRICK [26]TILE_STEEL
;  [27]TILE_WATER [28]TILE_ICE [29]TILE_DIRT [30]TANK_HP [31]VERSION(1)
; ------------------------------------------------------------
RL_Ptrs proc stdcall uses edi buf:DWORD
    mov edi, buf
    mov dword ptr [edi+0*4], OFFSET tanks
    mov dword ptr [edi+1*4], OFFSET bullets
    mov dword ptr [edi+2*4], OFFSET mapData
    mov dword ptr [edi+3*4], OFFSET mapIndex
    mov dword ptr [edi+4*4], OFFSET inputTable
    mov dword ptr [edi+5*4], OFFSET gTick
    mov dword ptr [edi+6*4], OFFSET rngMatch
    mov dword ptr [edi+7*4], OFFSET pickupType
    mov dword ptr [edi+8*4], OFFSET pickupX
    mov dword ptr [edi+9*4], OFFSET pickupY
    mov dword ptr [edi+10*4], OFFSET pickupTimer
    mov dword ptr [edi+11*4], OFFSET matchOver
    mov dword ptr [edi+12*4], OFFSET roundsPlayed
    mov dword ptr [edi+13*4], OFFSET maxRounds
    mov dword ptr [edi+14*4], OFFSET botMask
    mov dword ptr [edi+15*4], OFFSET gTick
    mov dword ptr [edi+16*4], COLS
    mov dword ptr [edi+17*4], ROWS
    mov dword ptr [edi+18*4], CELL
    mov dword ptr [edi+19*4], MAP_W
    mov dword ptr [edi+20*4], MAP_H
    mov dword ptr [edi+21*4], MAX_BULLETS
    mov dword ptr [edi+22*4], MAX_PLAYERS
    mov dword ptr [edi+23*4], KEY_PER
    mov dword ptr [edi+24*4], TILE_EMPTY
    mov dword ptr [edi+25*4], TILE_BRICK
    mov dword ptr [edi+26*4], TILE_STEEL
    mov dword ptr [edi+27*4], TILE_WATER
    mov dword ptr [edi+28*4], TILE_ICE
    mov dword ptr [edi+29*4], TILE_DIRT
    mov dword ptr [edi+30*4], TANK_HP
    mov dword ptr [edi+31*4], 1
    ret
RL_Ptrs endp

; ------------------------------------------------------------
; RL_Meta(buf) —— 用"局部假实例取成员地址差"导出真实偏移，
; 结构一改 Python 立刻对得上，手写表永不失同步。
; 顺序（tools/rl_env.py 对齐）：
;  [0]SIZEOF TANK [1]SIZEOF BULLET
;  TANK 依次: x y subpxX subpxY dir hp alive fireCd slide sdir score
;             skill effOn shieldT effT wallPass swapBul aimT aimSkill
;             lastCell phantomX phantomY phantomUses lives respawnT protT
;             spawnX spawnY spawnDir        （[2]..[30]）
;  BULLET 依次: x y vx vy owner active bounces age subpxX subpxY fireAng
;             （[31]..[41]）
; ------------------------------------------------------------
META_T macro fld, n
    lea eax, t.fld
    sub eax, ecx
    mov dword ptr [edi + n*4], eax
endm
META_B macro fld, n
    lea eax, b.fld
    sub eax, edx
    mov dword ptr [edi + n*4], eax
endm

RL_Meta proc stdcall uses ecx edx eax edi buf:DWORD
    local t: TANK
    local b: BULLET
    lea ecx, t
    lea edx, b
    mov edi, buf
    mov eax, SIZEOF TANK
    mov [edi+0], eax
    mov eax, SIZEOF BULLET
    mov [edi+4], eax
    META_T x, 2
    META_T y, 3
    META_T subpxX, 4
    META_T subpxY, 5
    META_T dir, 6
    META_T hp, 7
    META_T alive, 8
    META_T fireCd, 9
    META_T slide, 10
    META_T sdir, 11
    META_T score, 12
    META_T skill, 13
    META_T effOn, 14
    META_T shieldT, 15
    META_T effT, 16
    META_T wallPass, 17
    META_T swapBul, 18
    META_T aimT, 19
    META_T aimSkill, 20
    META_T lastCell, 21
    META_T phantomX, 22
    META_T phantomY, 23
    META_T phantomUses, 24
    META_T lives, 25
    META_T respawnT, 26
    META_T protT, 27
    META_T spawnX, 28
    META_T spawnY, 29
    META_T spawnDir, 30
    META_B x, 31
    META_B y, 32
    META_B vx, 33
    META_B vy, 34
    META_B owner, 35
    META_B active, 36
    META_B bounces, 37
    META_B age, 38
    META_B subpxX, 39
    META_B subpxY, 40
    META_B fireAng, 41
    ret
RL_Meta endp

end
