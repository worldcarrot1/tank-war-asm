; ============================================================
; bot.asm —— 会话38 黑色超强人机 / 会话39 升级为"对战补位黑人机"
; 职责：
;   - botMask 位 i=1 -> 槽 i 由 AI 接管：BotThink 每 tick 在 GameUpdate
;     槽循环之前把"AI 输入"写进 inputTable 的 6 个通道，与键盘同路数，
;     不碰任何游戏结算逻辑（伤害/技能/胜负全部走原管线）。
;     会话39：由单一 botMode（固定槽1）改为位掩码——人数选择页可用
;     黑人机补位（真人占低位槽），1人+2机 / 2人+1机 等任意组合皆可。
;   - 强化数值在 game.inc（BOT_*）：命数与玩家相等（会话42 拉平）/ 奇 tick 速度 4（均速 3.0）/
;     转向 4°/tick / 开火冷却 12 tick。
; 算法（全整数确定性；机与机状态按槽位完全隔离，无 rng；
;     会话44：目标/驾驶由"硬优先级规则链"升级为效用评分 argmax，
;     移植 Wesnoth 微 AI candidate-action 思路：威胁场+加法多项打分+
;     迟滞防抖；无威胁时打分胜者=旧规则导航源，逐 tick 行为等价）：
;   1 目标（会话44 BotTgtScore）：效用 argmax=真人24000+视线6000-距离
;     40/oct-目标盾1500+反击威胁发射者5000；在位者+4000 迟滞防乒乓
;   2 速度估计：目标中心 4-tick 环形采样(8 槽/机)，>=3 点算 256 倍速；
;     跳变 >150px 判重生/传送 -> 环清空
;   3 提前量：travel=octDist*10/27(<=200)，预瞄点=目标+速度*travel
;   4 视线 LOS：连线 ~6px 采样 1x1 探 WallRectsHit（砖/钢挡）
;   5 弹幕规避（会话39）：走廊窗口 170->240px；取"最近威胁弹"定自然
;     垂线侧，BotClear 探通畅、不通换对侧；规避期每 4 tick 复扫刷新；
;     统计在窗敌弹数 bThreatN 供冰盾择时；会话44：同时把"正被哪条
;     接近中敌弹威胁"经 uTX/uTY/uTD/uTW 短名单喂给 BotUtu 威胁场
;   6 寻路（会话39）：每 8 tick（错峰）无条件重算 BFS
;     （31x19：砖/钢阻断、水看驭水效果），本机格取回退方向 -> 航点=
;     下一格中心；目标换人/自身死亡即刻作废路径；被完全封死（无路）则直冲
;     + 穿墙术兜底
;   7 驾驶（会话44 BotUtu）：17 候选朝向(22°步进)效用 argmax——
;     T1=1280*cos(候选,主航向源[LOS预瞄/否则BFS航点/无路目标中心])，
;     T2=Σ接近中敌弹 1560*cos(候选,车->弹12tick后位)*距离权重(越近越大)，
;     T5=250*cos(候选,上次最优朝向) 迟滞锚防震荡；胜者=纯T1最优则细化
;     回精确方位（保会话42 回归与开火误差<=4）。带速仍走距离带：
;     有 LOS 近退(<130)/中距非对称压进(32tick:24进8退)/远追(>320)全速；
;     无 LOS/bBlk 推进；卡死（"想前进"却零位移 x5——意图在安全门前取，
;     会话42 修复贴墙冻结真凶）保留 30 tick 侧向绕行；空手时道具
;     ≤260px 直奔去抢
;   8 开火（会话39）：LOS+误差<=4（会话42 放宽）且目标后 216px 无钢/砖/图缘兜底
;     （弹反弹不可拆墙，近墙回弹自杀——T49B 实案，拆墙炮废除）
;   9 技能：激光/反射激光两段式，会话44 择时（有 LOS 等 >120px 放长
;     光束；无 LOS ≤300px 穿墙狙，不再一段即按）；冰盾=受威胁/双弹以上/
;     有视线且贴身<160 且盾不在身；加速=距离>180 且未生效；穿墙=看不到
;     且无路（封死才穿）或连卡；驭水=断视且卡住；地雷/换位/定格不用
;     （自爆/机制风险）
; 确定性：只用 gTick 与本地状态；自检 T48（单槽）/T49（多槽+寻路）。
; md5 锁：BotThink 仅在 botMask!=0 被调用；botMask 常规/联机局恒 0。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

; ---- 跨模块引用 ----
extern tanks        :TANK            ; game.asm
extern bullets      :BULLET          ; game.asm
extern inputTable   :dword           ; game.asm（AI 写这里）
extern gTick        :dword           ; game.asm
extern numPlayers   :dword           ; ui.asm
extern mapData      :byte            ; game.asm（BFS 通行判定）
extern pickupType   :dword           ; game.asm
extern pickupX      :dword           ; game.asm
extern pickupY      :dword           ; game.asm
extern cosTBL       :dword           ; game.asm（x1024）
extern sinTBL       :dword           ; game.asm
WallRectsHit PROTO :DWORD,:DWORD,:DWORD,:DWORD   ; game.asm
TankBlocked  PROTO :DWORD,:DWORD                 ; game.asm
extern rlBotMask :dword          ; 会话47：位 i=1 -> 槽 i 走 NN（rlbot.asm）
RlBotThink   PROTO :DWORD
RlBotReset   PROTO

; ---- 公开符号 ----
public botMask                       ; 位 i = 槽 i 由人机接管（会话39）
public botAggro                      ; 会话50：激进化开关（rlhost 注入）
public BotThink                      ; game.asm GameUpdate 每 tick 调用
public BotLos                        ; 视线判定（T48 直测）
public BotAimDxDy                    ; 360 搜索最优朝向角（T48 直测）
public BotReset                      ; 4 槽状态全复位（T49 阶段间卫生）
public botTrEn                       ; 会话46：main.asm CLI "bottrace" 置 1

; ------------------------------------------------------------
; BotSt —— 单机状态包（49 dword）。字段顺序与下方"暂存区"严格一致，
; BotLoadState/BotStoreState 以 SIZEOF BotSt 整块 rep movsd。
; ------------------------------------------------------------
BotSt STRUCT
    bsiTgtIdx   dd ?
    bsiTgtX     dd ?
    bsiTgtY     dd ?
    bsiVelX     dd ?
    bsiVelY     dd ?
    bsiRx       dd 8 dup(?)
    bsiRy       dd 8 dup(?)
    bsiHIdx     dd ?
    bsiHN       dd ?
    bsiPredX    dd ?
    bsiPredY    dd ?
    bsiDct      dd ?
    bsiLos      dd ?
    bsiAimA     dd ?
    bsiErrDeg   dd ?
    bsiCX       dd ?
    bsiCY       dd ?
    bsiNavA     dd ?
    bsiDrive    dd ?
    bsiEvadeT   dd ?
    bsiEvadeA   dd ?
    bsiEvadeNat dd ?
    bsiStuck    dd ?
    bsiDetourT  dd ?
    bsiDetourSide dd ?
    bsiLastX    dd ?
    bsiLastY    dd ?
    bsiPrevFwd  dd ?
    bsiAimCd    dd ?
    bsiPrevAim  dd ?
    bsiThreatN  dd ?
    bsiPathOk   dd ?
    bsiWpX      dd ?
    bsiWpY      dd ?
    bsiEvadeOwn dd ?
    bsiBlk      dd ?     ; 会话42：正前探墙被安全门摘油门的粘滞位（1=改走 BFS 航点）
    bsiUtuNav   dd ?     ; 会话44：上一次效用最优朝向（BotUtu 迟滞锚，防逐 tick 换向震荡）
    bsiPtrX     dd ?     ; 会话46：巡逻点 x（全场无活目标时的行进目标）
    bsiPtrY     dd ?     ; 会话46：巡逻点 y
    bsiPtrT     dd ?     ; 会话46：巡逻点有效 tick（0=过期需重挑）
    bsiPatrol   dd ?     ; 会话46：巡逻模式标志（1=本 tick 无真目标：禁开火/禁技能）
    bsiEscT     dd ?     ; 会话46：倒车脱困剩余 tick（凹袋全向卡死终极兜底）
    bsiEscA     dd ?     ; 会话46：倒车朝向快照（起脱时 dir+180±24，不再逐 tick 重算）
    bsiEscArm   dd ?     ; 会话46：连续绕行重挂次数（满 4 升格倒车）
    bsiEvHold   dd ?     ; 会话46：己弹"远去"罚站 tick 数（上限 12，防无限续期钉死）
    bsiTurnD    dd ?     ; 会话46B：转向锁当前方向（0=无 +1=顺 -1=逆）
    bsiTurnH    dd ?     ; 会话46B：换向冷却 tick（同向 6 tick 内禁反向，治摇头）
    bsiThreatSrc dd ?    ; 会话44：最近威胁弹的 owner 槽（反击择敌用；-1=无）
BotSt ENDS

.data
    botMask     dd 0                 ; 位图（ui.asm/命令行置位；net 清）
    bState      dd (SIZEOF BotSt/4)*4 dup(?)   ; 4 槽状态（BotSt 镜像，勿用结构数组初始化语法）

    ; ---- 会话50b：启发式陪练激进化开关（rlhost RESET flags bit2 注入；
    ;      0=现状位级不变，selftest 与 GUI 全程 0）——误差上限 6°+视线闸
    ;      三级抢救（直视/靶心/盲射走廊）。必须放在暂存区 OFFSET bTgtIdx
    ;      之前：BotLoadState/BotStoreState 以 SIZEOF BotSt 整块 rep movsd，
    ;      插进镜像区会被每 tick 状态包回填清零（bisect 实案）。----
    botAggro    dd 0

    ; ---- 本 tick 活动槽暂存区（与 BotSt 一一对应，勿调换顺序）----
    bTgtIdx     dd -1
    bTgtX       dd 0
    bTgtY       dd 0
    bVelX       dd 0
    bVelY       dd 0
    bRX         dd 8 dup(0)
    bRY         dd 8 dup(0)
    bHIdx       dd 0
    bHN         dd 0
    bPredX      dd 0
    bPredY      dd 0
    bDct        dd 0
    bLos        dd 0
    bAimA       dd 0
    bErrDeg     dd 0
    bCX         dd 0
    bCY         dd 0
    bNavA       dd 0
    bDrive      dd 0
    bEvadeT     dd 0
    bEvadeA     dd 0
    bEvadeNat   dd 0
    bStuck      dd 0
    bDetourT    dd 0
    bDetourSide dd 0
    bLastX      dd 0
    bLastY      dd 0
    bPrevForward dd 0
    bAimCd      dd 0
    bPrevAim    dd 0
    bThreatN    dd 0
    bPathOk     dd 0
    bWpX        dd 0
    bWpY        dd 0
    bEvadeOwn   dd 0     ; 会话39：最近威胁弹为自家弹（1=远去追击 2=反弹接近）
    bBlk        dd 0     ; 会话42：探墙粘滞位（安全门置1/探通清零；1=LOS追逐改走航点）
    bUtuNav     dd 0     ; 会话44：上次效用最优朝向（BotUtu 迟滞锚）
    bPtrX       dd 0     ; 会话46：巡逻点 x（镜像四连字段，勿与结构错位）
    bPtrY       dd 0     ; 会话46：巡逻点 y
    bPtrT       dd 0     ; 会话46：巡逻点剩余 tick
    bPatrol     dd 0     ; 会话46：巡逻标志
    bEscT       dd 0     ; 会话46：倒车脱困剩余 tick
    bEscA       dd 0     ; 会话46：倒车朝向快照
    bEscArm     dd 0     ; 会话46：绕行连挂计数
    bEvHold     dd 0     ; 会话46：己弹远去罚站计数
    bTurnD      dd 0     ; 会话46B：转向锁方向 0/+1顺/-1逆
    bTurnH      dd 0     ; 会话46B：换向冷却剩余 tick
    bThreatSrc  dd -1    ; 会话44：最近威胁弹 owner（BotThreat 每次扫描刷新）
    ; ---- 调度辅助（不属于 BotSt，勿上移）----
    bSlot       dd 0                 ; 本 tick 活动槽
    bLastTick   dd 0FFFFFFFFh        ; gTick 连续性（首帧必触发复位）


    ; ---- BFS 工作区（调用内自洽，跨槽无需保存）----
    bDist     dd COLS*ROWS dup(0)    ; 距目标格步数（-1=未达）
    bQueue    dd COLS*ROWS dup(0)
    bDirA     db COLS*ROWS dup(0)    ; 每格"向目标迈一步"方向 0..3/255
    bDXB      dd -1, 1, 0, 0         ; 方向增量：0左 1右 2上 3下
    bDYB      dd 0, 0, -1, 1

    ; ---- 会话44 BotUtu 威胁短名单 / BotTgtScore 输出（调用内自洽）----
    uTX       dd 8 dup(0)            ; 弹 12tick 后位置->本车 的方向 x（px）
    uTY       dd 8 dup(0)
    uTD       dd 8 dup(0)            ; 该方向长度（oct，下限 16，防除零）
    uTW       dd 8 dup(0)            ; 权重 260-弹距（越近越大）
    uTN       dd 0
    tsX       dd 0                   ; BotTgtScore 输出：候选中心
    tsY       dd 0
    btgScr    dd 0                   ; BotTgtScore 打分累加器（局部栈同名易混，用静态）
    bPtrN     dd 0                   ; 会话46：巡逻换点序号（确定性起点 = 序号*337 mod 格数）
    ; ---- 会话46 bot-trace 仪表（CLI "bottrace" 置 botTrEn=1；常规局/自检恒 0，
    ;      不开文件不写行，行为零变化，不影响 md5 基线）。每 tick 一行 CSV ->
    ;      CWD\tankwar_bottrace.csv，用于定位贴墙冻结的决策分支。 ----
    botTrEn   dd 0                  ; "tankwar bot bottrace" 命中由 start 段扫描置 1
    botTrHv   dd 0
    botTrPos  dd 0
    botTrWrn  dd 0
    botTrTmp  db 16 dup(0)
    botTrBuf  db 640 dup(0)
    szBotTr   db "tankwar_bottrace.csv", 0
    szBotTrHdr db "tick,slot,x,y,dir,navA,aimA,drive,prevF,blk,stk,det,esc,los,dct,pathOK,wpX,wpY,tgtIdx,tgtX,tgtY,evT,evOwn,evA,skill,effOn,fireCd,inF,inB,inCCW,inCW,inFire,inSk,patrol,evh,alive,aggro", 10
botTrHdrLen = $ - offset szBotTrHdr

.code
; ------------------------------------------------------------
; BotReset —— 4 槽状态全复位（tick 不连续/新一局首帧）
; ------------------------------------------------------------
BotReset proc
    local s: dword
    mov s, 0
BR_L:
    mov ecx, s
    imul ecx, ecx, SIZEOF BotSt
    lea edi, bState
    add edi, ecx
    mov dword ptr [edi], -1          ; tgtIdx=-1
    add edi, 4
    mov ecx, (SIZEOF BotSt - 4)/4
    xor eax, eax
    cld
    rep stosd
    mov dword ptr [edi-4], -1        ; 会话44：threatSrc=-1（结构末字段）
    inc s
    mov eax, s
    cmp eax, MAX_PLAYERS
    jb BR_L
    invoke RlBotReset                  ; 会话47：NN 槽 EMA/回合缓存同复（掩码0时无行为差）
    ret
BotReset endp

; ------------------------------------------------------------
; BotLoadState / BotStoreState —— bSlot 状态包 <-> 暂存区
; ------------------------------------------------------------
BotLoadState proc
    cld
    mov ecx, bSlot
    imul ecx, ecx, SIZEOF BotSt
    lea esi, bState
    add esi, ecx
    mov edi, OFFSET bTgtIdx
    mov ecx, SIZEOF BotSt/4
    rep movsd
    ret
BotLoadState endp

BotStoreState proc
    cld
    mov ecx, bSlot
    imul ecx, ecx, SIZEOF BotSt
    lea esi, bTgtIdx
    mov edi, OFFSET bState
    add edi, ecx
    mov ecx, SIZEOF BotSt/4
    rep movsd
    ret
BotStoreState endp

; ------------------------------------------------------------
; BotSelfTank —— 助手：eax = 本槽坦克地址（只毁 eax）
; ------------------------------------------------------------
BotSelfTank proc
    mov eax, bSlot
    imul eax, eax, SIZEOF TANK
    add eax, OFFSET tanks
    ret
BotSelfTank endp

; ------------------------------------------------------------
; BotAimDxDy —— 360 度 argmax：dot = cos(a)*dx + sin(a)*dy 最大者
; 平局取更小角；定点表取整使峰值常比理想角小 1°（sin89==sin90），
; 3° 死区吸收，无碍。返回 eax=0..359。
; ------------------------------------------------------------
BotAimDxDy proc uses ebx esi edi, pDx: dword, pDy: dword
    local bestV: dword, bestA: dword
    mov bestV, 80000000h
    mov bestA, 0
    xor ecx, ecx
BAD_Loop:
    mov eax, cosTBL[ecx*4]
    imul eax, pDx
    mov edx, sinTBL[ecx*4]
    imul edx, pDy
    add eax, edx
    cmp eax, bestV
    jle BAD_Skip
    mov bestV, eax
    mov bestA, ecx
BAD_Skip:
    inc ecx
    cmp ecx, ANGLE_SPAN
    jb BAD_Loop
    mov eax, bestA
    ret
BotAimDxDy endp

; ------------------------------------------------------------
; BotLos —— 线段视线（不含两端点）：每 ~6px 一个 1x1 探针打墙。
; 返回 eax=1 通 / 0 挡；近距（跨度 <8px）直接算通。
; ------------------------------------------------------------
BotLos proc uses ebx esi edi, pX0: dword, pY0: dword, pX1: dword, pY1: dword
    local lx: dword, ly: dword, stp: dword, cnt: dword
    mov eax, pX1
    sub eax, pX0
    mov lx, eax
    mov eax, pY1
    sub eax, pY0
    mov ly, eax
    ; m = max(|lx|,|ly|)
    mov eax, lx
    test eax, eax
    jns BTL_A1
    neg eax
BTL_A1:
    mov ecx, ly
    test ecx, ecx
    jns BTL_A2
    neg ecx
BTL_A2:
    cmp eax, ecx
    jae BTL_A3
    mov eax, ecx
BTL_A3:
    cmp eax, 8
    jb BTL_Clear
    ; stp = (m+5)/6，至少 2
    add eax, 5
    xor edx, edx
    mov ecx, 6
    div ecx
    mov stp, eax
    cmp eax, 2
    jae BTL_Loop
    mov stp, 2
BTL_Loop:
    mov cnt, 1
BTL_Sample:
    ; x = pX0 + lx*cnt/stp（有符号：imul + cdq + idiv）
    mov eax, lx
    imul eax, cnt
    cdq
    idiv stp
    add eax, pX0
    mov esi, eax
    mov eax, ly
    imul eax, cnt
    cdq
    idiv stp
    add eax, pY0
    mov edi, eax
    invoke WallRectsHit, esi, edi, 1, 1
    test eax, eax
    jnz BTL_Blocked
    inc cnt
    mov eax, cnt
    cmp eax, stp
    jb BTL_Sample
BTL_Clear:
    mov eax, 1
    ret
BTL_Blocked:
    xor eax, eax
    ret
BotLos endp

; ------------------------------------------------------------
; BotAggroCorr —— 会话50b：激进档盲射走廊判定（仅 botAggro≠0 调用）
;   自车中心沿 bAimA 采 5 点（36..180px），任一出图/钢/砖 => eax=0
;   （出弹即回弹自撞）；全通 => eax=1（子弹至少飞 180px，靠回弹
;   拐弯击杀或逼走位）。治"陪练惜弹"主卡点：远距隔墙无视线时
;   旧档整局静默、零击杀信号（trace 实测 los 闸拒 91% tick）。
; ------------------------------------------------------------
BotAggroCorr proc uses ebx esi edi
    local sx: dword, sy: dword, px: dword, py: dword, n: dword
    mov eax, bAimA
    mov ecx, cosTBL[eax*4]
    imul ecx, ecx, 36
    sar ecx, TRIG_SHIFT
    mov sx, ecx
    mov ecx, sinTBL[eax*4]
    imul ecx, ecx, 36
    sar ecx, TRIG_SHIFT
    mov sy, ecx
    mov eax, bCX
    mov px, eax
    mov eax, bCY
    mov py, eax
    mov n, 5
BAC_Loop:
    mov eax, py
    add eax, sy
    mov py, eax
    test eax, eax
    js BAC_Bad
    cmp eax, MAP_H
    jae BAC_Bad
    shr eax, 5
    imul eax, eax, COLS
    mov ecx, eax
    mov eax, px
    add eax, sx
    mov px, eax
    test eax, eax
    js BAC_Bad
    cmp eax, MAP_W
    jae BAC_Bad
    shr eax, 5
    add ecx, eax
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BAC_Bad
    cmp eax, TILE_BRICK
    je BAC_Bad
    dec n
    jnz BAC_Loop
    mov eax, 1
    ret
BAC_Bad:
    xor eax, eax
    ret
BotAggroCorr endp

; ------------------------------------------------------------
; BotClear —— 自车 top-left 朝 pA 方向平移 24px 后是否无阻挡
; 返回 eax=1 通畅 / 0 被挡（与前进安全门同一坐标语义）
; ------------------------------------------------------------
BotClear proc uses ebx esi edi, pA: dword
    local px: dword, py: dword
    call BotSelfTank
    mov esi, eax
    mov ecx, pA
    mov eax, cosTBL[ecx*4]
    imul eax, eax, 24
    sar eax, TRIG_SHIFT
    add eax, (TANK ptr [esi]).x
    mov px, eax
    mov eax, sinTBL[ecx*4]
    imul eax, eax, 24
    sar eax, TRIG_SHIFT
    add eax, (TANK ptr [esi]).y
    mov py, eax
    invoke TankBlocked, px, py
    test eax, eax
    jnz BC_Blk
    mov eax, 1
    ret
BC_Blk:
    xor eax, eax
    ret
BotClear endp

; ------------------------------------------------------------
; BotThreat —— 敌弹走廊扫描（会话39 强化）：遍历全部敌弹统计
; bThreatN，并对"最近威胁弹"决策规避方向：
;   接近 dot>0、走廊 |cross|<=14*(|vpx|+|vpy|)、窗口 240px；
;   自然侧 = 弹航向 +90（cross>0）/ +270；BotClear 不通 -> 对侧。
;   命中威胁 -> bEvadeA + bEvadeT=28（会话42：容得下转完 90°）。游标每轮由 ebx 重算，
;   esi/edi 仅作几何暂存（不再兼任迭代游标）。
; ------------------------------------------------------------
BotThreat proc uses ebx esi edi
    local rx: dword, ry: dword, vpx: dword, vpy: dword, crossd: dword
    local haveT: dword, bestR: dword, bVX: dword, bVY: dword, bCr: dword
    local ownOut: dword
    local dotV: dword
    mov bThreatN, 0
    mov bEvadeOwn, 0
    mov bThreatSrc, -1               ; 会话44：记录最近威胁弹 owner（反击择敌）
    mov haveT, 0
    mov bestR, 1000000
    xor ebx, ebx
BT_Th:
    cmp ebx, MAX_BULLETS
    jae BT_ThEnd
    mov edi, OFFSET bullets
    mov eax, ebx
    imul eax, eax, SIZEOF BULLET
    add edi, eax
    cmp (BULLET ptr [edi]).active, 0
    je BT_ThNext
    mov eax, (BULLET ptr [edi]).owner
    cmp eax, bSlot
    je BT_ThOwn
    mov ownOut, 0
    jmp BT_ThGeom                      ; 别人的弹：需"接近中"才躲
BT_ThOwn:
    ; 会话39：己弹一律进走廊判定——出膛弹看似远去，但本机均速 3.0 高于
    ; 弹速 2.7，沿射击线直追必"自撞"（TankHitLoop 仅 age<=1 宽限射手）；
    ; 反弹己弹回杀同理。走廊窄者侧闪即可让行，弹过即恢复追击。
    mov ownOut, 1
BT_ThGeom:
    mov eax, (BULLET ptr [edi]).x
    add eax, BULLET_SIZE_PX/2
    mov ecx, bCX
    sub ecx, eax
    mov rx, ecx
    mov eax, (BULLET ptr [edi]).y
    add eax, BULLET_SIZE_PX/2
    mov ecx, bCY
    sub ecx, eax
    mov ry, ecx
    mov eax, rx
    test eax, eax
    jns BT_ThX
    neg eax
BT_ThX:
    cmp eax, 240                       ; 窗口 170 -> 240（会话39）
    ja BT_ThNext
    mov ecx, eax
    mov eax, ry
    test eax, eax
    jns BT_ThY
    neg eax
BT_ThY:
    cmp eax, 240
    ja BT_ThNext
    mov eax, (BULLET ptr [edi]).vx
    sar eax, FIX_SHIFT
    mov vpx, eax
    mov eax, (BULLET ptr [edi]).vy
    sar eax, FIX_SHIFT
    mov vpy, eax
    .if vpx == 0 && vpy == 0
        jmp BT_ThNext
    .endif
    ; dot = v·r（>0 = 接近中；己弹 ownOut 免此筛，见上）
    mov eax, vpx
    imul eax, rx
    mov edx, vpy
    imul edx, ry
    add eax, edx
    mov dotV, eax
    cmp ownOut, 0
    jne BT_ThCross
    test eax, eax
    jle BT_ThNext
BT_ThCross:
    ; cross = vpx*ry - vpy*rx
    mov eax, vpx
    imul eax, ry
    mov edx, vpy
    imul edx, rx
    sub eax, edx
    mov crossd, eax
    mov esi, eax
    test esi, esi
    jns BT_ThC
    neg esi
BT_ThC:
    ; 走廊宽 14px：|cross| <= 14*(|vpx|+|vpy|)
    mov edx, vpx
    test edx, edx
    jns BT_ThV1
    neg edx
BT_ThV1:
    mov ecx, vpy
    test ecx, ecx
    jns BT_ThV2
    neg ecx
BT_ThV2:
    add edx, ecx
    imul edx, edx, 14
    cmp esi, edx
    ja BT_ThNext
    ; —— 威胁成立 ——
    inc bThreatN
    .if haveT == 0
        mov eax, rx
        test eax, eax
        jns BT_D1
        neg eax
BT_D1:
        mov ecx, ry
        test ecx, ecx
        jns BT_D2
        neg ecx
BT_D2:
        add eax, ecx                 ; 曼哈顿距
        cmp eax, bestR
        jae BT_ThNext
        mov bestR, eax
        mov haveT, 1
        mov eax, (BULLET ptr [edi]).owner   ; 会话44：记下开火者槽，供反击择敌
        mov bThreatSrc, eax
        mov eax, vpx
        mov bVX, eax
        mov eax, vpy
        mov bVY, eax
        mov eax, crossd
        mov bCr, eax
        mov eax, ownOut
        .if eax != 0
            mov eax, dotV
            test eax, eax
            jg BTEO_App
            mov bEvadeOwn, 1           ; 己弹远去：本车同向直追必自撞（弹 vx<=2.7<车速）
            jmp BTEO_Dn
BTEO_App:
            mov bEvadeOwn, 2           ; 己弹反弹接近
BTEO_Dn:
        .else
            mov bEvHold, 0             ; 会话46：敌方威胁不罚站，清零连停计数
        .endif
    .endif
BT_ThNext:
    inc ebx
    jmp BT_Th
BT_ThEnd:
    cmp haveT, 0
    je BT_ThZero
    mov eax, bEvadeOwn
    .if eax == 0                       ; 会话46：有威胁但非己弹 -> 同清计数
        mov bEvHold, 0
    .endif
    ; 自然规避侧
    invoke BotAimDxDy, bVX, bVY
    cmp bCr, 0
    jle BT_ThNeg
    add eax, 90
    jmp BT_ThWrap
BT_ThNeg:
    add eax, 270
BT_ThWrap:
    cmp eax, ANGLE_SPAN
    jb BT_ThSet1
    sub eax, ANGLE_SPAN
BT_ThSet1:
    mov bEvadeNat, eax
    mov bEvadeA, eax                   ; 默认=自然侧
    mov bEvadeT, 28                    ; 会话42：20→28（转 90° 需 4°/tick×23tick，
                                       ; 旧窗口不够转完，躲弹永远"闪一半"）
    ; 通畅性：自然侧被堵 -> 换对侧（都堵则保持自然侧，交给冰盾）
    invoke BotClear, bEvadeNat
    test eax, eax
    jnz BT_ThNone
    mov eax, bEvadeNat
    add eax, 180
    cmp eax, ANGLE_SPAN
    jb BT_ThAlt
    sub eax, ANGLE_SPAN
BT_ThAlt:
    mov bEvadeA, eax
BT_ThNone:
    ret
BT_ThZero:                             ; 会话46：真无威胁才清零罚站计数（旧版挂在
    mov bEvHold, 0                     ;  BT_ThNone 出口，但"规避侧通畅 jnz BT_ThNone"
    ret                                ;  也必经此处，每 4tick 复扫把 evHold 误清 0，
                                       ;  上限 12 永远积不满——40tick 罚站案复现）
BotThreat endp

; ------------------------------------------------------------
; BotTgtScore —— 会话44：目标效用打分（加法多项整数权重，Wesnoth
; candidate-action evaluator 的移植）。入 ebx=候选槽（存活），
; 出 eax=分值；tsX/tsY=候选中心。
;   真人 +24000（永远优先打真人）；无视线 -6000（能打 > 追不上）；
;   距离每 oct px 扣 40（近距优先但远程仍值得）；目标挂盾 -1500
;   （不浪费弹，盾过期自然回填）；其弹正是我最近威胁 +5000（反击
;   "打我的人"——局面响应的最直观体现）。
; ------------------------------------------------------------
BotTgtScore proc uses esi edi
    local dxv: dword, dyv: dword, dd_: dword
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    lea esi, tanks
    add esi, eax
    mov eax, (TANK ptr [esi]).x
    add eax, TANK_SIZE/2
    mov tsX, eax
    mov edx, (TANK ptr [esi]).y
    add edx, TANK_SIZE/2
    mov tsY, edx
    sub eax, bCX
    mov dxv, eax
    mov edx, tsY
    sub edx, bCY
    mov dyv, edx
    mov eax, dxv
    test eax, eax
    jns BTS1
    neg eax
BTS1:
    mov ecx, dyv
    test ecx, ecx
    jns BTS2
    neg ecx
BTS2:
    cmp eax, ecx
    jae BTS3
    xchg eax, ecx
BTS3:
    shr ecx, 1
    add eax, ecx
    mov dd_, eax                     ; oct 距
    mov btgScr, 24000
    bt botMask, ebx
    jnc BTS4
    mov btgScr, 0                    ; 候选是机：无真人加成
BTS4:
    mov eax, dd_
    imul eax, eax, 40
    sub btgScr, eax
    invoke BotLos, bCX, bCY, tsX, tsY
    test eax, eax
    jnz BTS5
    sub btgScr, 6000
BTS5:
    mov eax, (TANK ptr [esi]).effOn
    and eax, EFF_SHIELD
    .if eax != 0
        sub btgScr, 1500
    .endif
    cmp bEvadeT, 0
    je BTS6
    cmp ebx, bThreatSrc
    jne BTS6
    add btgScr, 5000                 ; 反击优先
BTS6:
    mov eax, btgScr
    ret
BotTgtScore endp

; ------------------------------------------------------------
; BotUtu —— 会话44：驾驶朝向效用 argmax（候选动作打分）。
; 17 候选朝向 A∈{0,22,...,352}：
;   T1 = 1280*cos(A,主航向)：有LOS且正前通畅→预瞄点；无LOS/bBlk→BFS
;        航点；无路→目标中心（直推，安全门兜底）
;   T2 = Σ弹 1560*cos(A,车->敌弹12tick后位)*(260-d)/260：只算"接近中"
;        敌弹，越近权重越大 —— 侧移躲弹同时不彻底放弃瞄准线
;   T5 = 250*cos(A, bUtuNav)：迟滞锚，防逐 tick 换向震荡
; 若胜者==纯T1最优（威胁/迟滞未改变判断）→返回精确方位，与会话42
; 行为完全等价（T48E/T49B 回归保险）。eax=朝向，顺带写 bUtuNav。
; ------------------------------------------------------------
BotUtu proc uses ebx esi edi
    local dx1: dword, dy1: dword, dt1: dword
    local hA: dword, curS: dword, bestS: dword, bestA: dword
    local t1S: dword, t1Best: dword, t1A: dword
    local cA: dword, sA: dword, jj: dword
    local rx: dword, ry: dword, vpx: dword, vpy: dword, dd_: dword
    ; ---- 1) 敌弹短名单（接近中 & oct<=260，上限 8）----
    mov uTN, 0
    xor ebx, ebx
UU_Th:
    cmp ebx, MAX_BULLETS
    jae UU_ThDone
    mov edi, OFFSET bullets
    mov eax, ebx
    imul eax, eax, SIZEOF BULLET
    add edi, eax
    cmp (BULLET ptr [edi]).active, 0
    je UU_ThNext
    mov eax, (BULLET ptr [edi]).owner
    cmp eax, bSlot
    je UU_ThNext                     ; 己弹让线归 BotThreat（含停步语义）
    mov eax, (BULLET ptr [edi]).x
    add eax, BULLET_SIZE_PX/2
    mov ecx, bCX
    sub ecx, eax
    mov rx, ecx
    mov eax, (BULLET ptr [edi]).y
    add eax, BULLET_SIZE_PX/2
    mov ecx, bCY
    sub ecx, eax
    mov ry, ecx
    mov eax, rx
    test eax, eax
    jns UU_D1
    neg eax
UU_D1:
    mov ecx, ry
    test ecx, ecx
    jns UU_D2
    neg ecx
UU_D2:
    cmp eax, ecx
    jae UU_D3
    xchg eax, ecx
UU_D3:
    shr ecx, 1
    add eax, ecx
    cmp eax, 260
    ja UU_ThNext
    mov dd_, eax                     ; d=oct(车->弹)
    mov edx, (BULLET ptr [edi]).vx
    sar edx, FIX_SHIFT
    mov vpx, edx
    mov edx, (BULLET ptr [edi]).vy
    sar edx, FIX_SHIFT
    mov vpy, edx
    mov eax, vpx
    imul eax, rx
    mov edx, vpy
    imul edx, ry
    add eax, edx
    jle UU_ThNext                    ; 远离中的敌弹不计
    ; 未来位方向 = (车-弹) - v*12
    mov edx, vpx
    imul edx, edx, 12
    sub rx, edx
    mov edx, vpy
    imul edx, edx, 12
    sub ry, edx
    mov ecx, uTN
    cmp ecx, 8
    jae UU_ThNext
    mov eax, rx
    mov uTX[ecx*4], eax
    mov eax, ry
    mov uTY[ecx*4], eax
    mov eax, rx
    test eax, eax
    jns UU_E1
    neg eax
UU_E1:
    mov edx, ry
    test edx, edx
    jns UU_E2
    neg edx
UU_E2:
    cmp eax, edx
    jae UU_E3
    xchg eax, edx
UU_E3:
    shr edx, 1
    add eax, edx
    cmp eax, 16
    jae UU_E4
    mov eax, 16                      ; 防除零
UU_E4:
    mov uTD[ecx*4], eax
    mov edx, 260
    sub edx, dd_
    mov uTW[ecx*4], edx
    inc uTN
UU_ThNext:
    inc ebx
    jmp UU_Th
UU_ThDone:
    ; ---- 2) 主航向源 ----
    cmp bLos, 0
    je UU_NoLos
    cmp bBlk, 0
    jne UU_NoLos
    mov eax, bPredX
    sub eax, bCX
    mov dx1, eax
    mov eax, bPredY
    sub eax, bCY
    mov dy1, eax
    mov eax, bDct
    jmp UU_Dt1
UU_NoLos:
    cmp bPathOk, 0
    je UU_Direct
    mov eax, bWpX
    sub eax, bCX
    mov dx1, eax
    mov eax, bWpY
    sub eax, bCY
    mov dy1, eax
    test eax, eax
    jns UU_F1
    neg eax
UU_F1:
    mov ecx, dx1
    test ecx, ecx
    jns UU_F2
    neg ecx
UU_F2:
    cmp eax, ecx
    jae UU_F3
    xchg eax, ecx
UU_F3:
    shr ecx, 1
    add eax, ecx
    jmp UU_Dt1
UU_Direct:
    mov eax, bTgtX
    sub eax, bCX
    mov dx1, eax
    mov eax, bTgtY
    sub eax, bCY
    mov dy1, eax
    mov eax, bDct
UU_Dt1:
    cmp eax, 16
    jae UU_Dt2
    mov eax, 16
UU_Dt2:
    mov dt1, eax
    cmp uTN, 0
    jne UU_Scan
    invoke BotAimDxDy, dx1, dy1      ; 无威胁：精确方位=旧版行为
    jmp UU_Set
UU_Scan:
    mov bestS, -1000000000
    mov t1Best, -1000000000
    mov bestA, 0
    mov t1A, 0
    mov hA, 0
UU_H:
    mov ecx, hA
    mov eax, cosTBL[ecx*4]
    mov cA, eax
    mov eax, sinTBL[ecx*4]
    mov sA, eax
    mov eax, cA
    imul eax, dx1
    mov edx, sA
    imul edx, dy1
    add eax, edx
    cdq
    idiv dt1
    imul eax, eax, 1280
    sar eax, 10
    mov t1S, eax
    cmp eax, t1Best
    jle UU_H1
    mov t1Best, eax
    mov ecx, hA
    mov t1A, ecx
UU_H1:
    mov eax, t1S
    mov curS, eax
    mov jj, 0
UU_T2:
    mov ecx, jj
    cmp ecx, uTN
    jae UU_T3
    mov eax, uTX[ecx*4]
    imul eax, cA
    mov edx, uTY[ecx*4]
    imul edx, sA
    add eax, edx
    cdq
    idiv uTD[ecx*4]
    imul eax, uTW[ecx*4]
    imul eax, eax, 3
    sar eax, 9
    add curS, eax
    inc jj
    jmp UU_T2
UU_T3:
    mov ecx, bUtuNav
    mov eax, cA
    imul eax, cosTBL[ecx*4]
    mov edx, sA
    imul edx, sinTBL[ecx*4]
    add eax, edx
    sar eax, 10
    imul eax, eax, 250
    sar eax, 10
    add curS, eax
    mov eax, curS
    cmp eax, bestS
    jle UU_HN
    mov bestS, eax
    mov ecx, hA
    mov bestA, ecx
UU_HN:
    mov eax, hA
    add eax, 22
    cmp eax, 360
    jae UU_End
    mov hA, eax
    jmp UU_H
UU_End:
    mov eax, bestA
    cmp eax, t1A
    jne UU_Set
    invoke BotAimDxDy, dx1, dy1      ; 胜者=纯T1最优→细化回精确方位
UU_Set:
    mov bUtuNav, eax
    ret
BotUtu endp

; ------------------------------------------------------------
; BotBfs —— 自目标格 4 邻域洪水（会话39）。写 bPathOk/bWpX/bWpY。
; 通行：EMPTY/ICE/DIRT；WATER 仅当自车 EFF_WATER；BRICK/STEEL 阻断
; （砖由"拆墙炮"逐步打开，下轮 BFS 自然穿洞）。
; bDirA[nb]：从 nb 迈向 cur（=朝目标）的方向 0左1右2上3下。
; ------------------------------------------------------------
BotBfs proc uses ebx esi edi
    local tcx: dword, tcy: dword, qh: dword, qt: dword
    local cur: dword, ccy: dword, ccx: dword, nextd: dword
    local waterOk: dword, bcx: dword, bcy: dword, tcell: dword, bcell: dword
    call BotSelfTank
    mov esi, eax
    mov eax, (TANK ptr [esi]).effOn
    and eax, EFF_WATER
    mov waterOk, eax
    mov eax, bTgtX
    shr eax, 5
    mov tcx, eax
    mov eax, bTgtY
    shr eax, 5
    mov tcy, eax
    imul eax, eax, COLS
    add eax, tcx
    mov tcell, eax
    cld
    mov edi, OFFSET bDist
    mov eax, -1
    mov ecx, COLS*ROWS
    rep stosd
    mov edi, OFFSET bDirA
    mov al, -1
    mov ecx, COLS*ROWS
    rep stosb
    mov ecx, tcell
    mov bDist[ecx*4], 0
    mov bQueue, ecx
    mov qh, 0
    mov qt, 1
BB_Loop:
    mov eax, qh
    cmp eax, qt
    jae BB_Done
    mov ecx, eax
    mov eax, bQueue[ecx*4]
    mov cur, eax
    inc qh
    ; cur -> cy/cx
    mov eax, cur
    xor edx, edx
    mov ecx, COLS
    div ecx                            ; 商=cy 余=cx
    mov ccy, eax
    mov ccx, edx
    ; nextd = dist[cur]+1
    mov edx, cur
    mov eax, bDist[edx*4]
    inc eax
    mov nextd, eax
    ; ---- 左 nb=cur-1 回向=右(1) ----
    mov ecx, ccx
    test ecx, ecx
    jz BB_R
    mov ecx, cur
    dec ecx
    mov eax, bDist[ecx*4]
    cmp eax, -1
    jne BB_R
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BB_R
    cmp eax, TILE_BRICK
    je BB_R
    cmp eax, TILE_WATER
    jne BB_Lok
    cmp waterOk, 0
    je BB_R
BB_Lok:
    mov eax, nextd
    mov bDist[ecx*4], eax
    mov byte ptr bDirA[ecx], 1
    mov eax, qt
    mov bQueue[eax*4], ecx
    inc qt
    ; ---- 右 nb=cur+1 回向=左(0) ----
BB_R:
    mov ecx, ccx
    cmp ecx, COLS - 1
    jae BB_U
    mov ecx, cur
    inc ecx
    mov eax, bDist[ecx*4]
    cmp eax, -1
    jne BB_U
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BB_U
    cmp eax, TILE_BRICK
    je BB_U
    cmp eax, TILE_WATER
    jne BB_Rok
    cmp waterOk, 0
    je BB_U
BB_Rok:
    mov eax, nextd
    mov bDist[ecx*4], eax
    mov byte ptr bDirA[ecx], 0
    mov eax, qt
    mov bQueue[eax*4], ecx
    inc qt
    ; ---- 上 nb=cur-COLS 回向=下(3) ----
BB_U:
    mov ecx, ccy
    test ecx, ecx
    jz BB_D
    mov ecx, cur
    sub ecx, COLS
    mov eax, bDist[ecx*4]
    cmp eax, -1
    jne BB_D
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BB_D
    cmp eax, TILE_BRICK
    je BB_D
    cmp eax, TILE_WATER
    jne BB_Uok
    cmp waterOk, 0
    je BB_D
BB_Uok:
    mov eax, nextd
    mov bDist[ecx*4], eax
    mov byte ptr bDirA[ecx], 3
    mov eax, qt
    mov bQueue[eax*4], ecx
    inc qt
    ; ---- 下 nb=cur+COLS 回向=上(2) ----
BB_D:
    mov ecx, ccy
    cmp ecx, ROWS - 1
    jae BB_Loop
    mov ecx, cur
    add ecx, COLS
    mov eax, bDist[ecx*4]
    cmp eax, -1
    jne BB_Loop
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BB_Loop
    cmp eax, TILE_BRICK
    je BB_Loop
    cmp eax, TILE_WATER
    jne BB_Dok
    cmp waterOk, 0
    je BB_Loop
BB_Dok:
    mov eax, nextd
    mov bDist[ecx*4], eax
    mov byte ptr bDirA[ecx], 2
    mov eax, qt
    mov bQueue[eax*4], ecx
    inc qt
    jmp BB_Loop
BB_Done:
    mov bPathOk, 0
    mov eax, bCX
    shr eax, 5
    mov bcx, eax
    mov eax, bCY
    shr eax, 5
    mov bcy, eax
    imul eax, eax, COLS
    add eax, bcx
    mov bcell, eax
    mov ecx, eax
    mov eax, bDist[ecx*4]
    cmp eax, -1
    je BB_End                          ; 完全封死：无路
    cmp eax, 0
    je BB_End                          ; 已同格：直瞄即可
    movzx edx, byte ptr bDirA[ecx]
    cmp edx, 255
    je BB_End
    mov bPathOk, 1
    ; 航点 = 下一步格中心
    mov eax, bDXB[edx*4]
    add eax, bcx
    shl eax, 5
    add eax, 16
    mov bWpX, eax
    mov eax, bDYB[edx*4]
    add eax, bcy
    shl eax, 5
    add eax, 16
    mov bWpY, eax
BB_End:
    ret
BotBfs endp

; ------------------------------------------------------------
; BotThinkSlot —— 单槽一 tick 的完整决策（内部只用暂存区）。
; 由 BotThink 对每个 bot 槽 invoke。esi=自车 edi=通道基址，
; 由宏 RL 在跨"可能毁指针"的调用后重建。
; ------------------------------------------------------------
RL macro
    call BotSelfTank
    mov esi, eax
    mov edi, bSlot
    imul edi, edi, KEY_PER*4
endm

BotThinkSlot proc uses ebx esi edi, pS: dword
    local t1: dword, t2: dword, t3: dword
    local u1: dword, u2: dword, u3: dword, u0: dword
    local ppx: dword, ppy: dword
    local hIdxT: dword, aIdxT: dword, hTx: dword, hTy: dword
    local aTx: dword, aTy: dword
    local grabbed: dword

    mov eax, pS
    mov bSlot, eax
    call BotLoadState

    ; ---- 本 tick 六通道清零（覆盖键盘残留；技能按压天然单 tick 边沿）----
    RL
    mov inputTable[edi], 0
    mov inputTable[edi+4], 0
    mov inputTable[edi+8], 0
    mov inputTable[edi+12], 0
    mov inputTable[edi+16], 0
    mov inputTable[edi+20], 0
    cmp (TANK ptr [esi]).alive, 0
    je BT_Dead

    ; ---- 卡死检测（上 tick 按前进却零位移）----
    mov eax, (TANK ptr [esi]).x
    mov t1, eax
    mov edx, (TANK ptr [esi]).y
    mov t2, edx
    sub eax, bLastX
    test eax, eax
    jns BT_Sk1
    neg eax
BT_Sk1:
    mov t3, eax
    mov eax, edx
    sub eax, bLastY
    test eax, eax
    jns BT_Sk2
    neg eax
BT_Sk2:
    add eax, t3
    .if eax == 0 && bPrevForward != 0
        inc bStuck
        cmp bStuck, 5
        jb BT_SkGo
        mov bStuck, 0
        mov eax, bEscArm
        cmp eax, 3                       ; 会话46：第 4 次连挂 -> 绕行已证明逃不出
        jbe BT_SkDet                     ;  （凹袋全向贴墙），升格倒车脱困
        mov bEscArm, 0
        mov bEscT, 24
        mov eax, (TANK ptr [esi]).dir
        add eax, 180                     ; 倒车朝向=进路反向；隔轮 ±24° 侧摆
        cmp eax, ANGLE_SPAN
        jb BT_SkEs1
        sub eax, ANGLE_SPAN
BT_SkEs1:
        cmp bDetourSide, 0
        je BT_SkEsP
        sub eax, 24
        cmp eax, 0
        jns BT_SkEs2
        add eax, ANGLE_SPAN
        jmp BT_SkEs2
BT_SkEsP:
        add eax, 24
        cmp eax, ANGLE_SPAN
        jb BT_SkEs2
        sub eax, ANGLE_SPAN
BT_SkEs2:
        mov bEscA, eax
        mov eax, bDetourSide
        xor eax, 1
        mov bDetourSide, eax
        jmp BT_SkGo
BT_SkDet:
        inc bEscArm
        mov bDetourT, 30
        mov eax, bDetourSide
        xor eax, 1
        mov bDetourSide, eax
    .else
        mov bStuck, 0
        mov bEscArm, 0                   ; 会话46：走动了即清零连挂计数
    .endif
BT_SkGo:
    mov eax, t1
    mov bLastX, eax
    mov eax, t2
    mov bLastY, eax

    ; ---- 自车中心 ----
    add eax, TANK_SIZE/2
    mov bCY, eax
    mov eax, t1
    add eax, TANK_SIZE/2
    mov bCX, eax

    ; ---- 选目标（会话44：效用打分 argmax+迟滞。真人重加成天然优先；
    ;      在位者 +4000 迟滞=只被"真正更好 4000 分"的对手抢走，防乒乓；
    ;      威胁发射者 +5000=反击"打我的人"）----
    xor ebx, ebx
    mov u1, -1000000000
    mov hIdxT, -1
BT_Tgt:
    cmp ebx, numPlayers
    jae BT_TgtEnd
    cmp ebx, bSlot
    je BT_TgtNext
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    mov ecx, OFFSET tanks
    add ecx, eax
    cmp (TANK ptr [ecx]).alive, 0
    je BT_TgtNext
    invoke BotTgtScore
    cmp ebx, bTgtIdx
    jne BT_TgtCmp
    add eax, 4000                      ; 在位者迟滞加成
BT_TgtCmp:
    cmp eax, u1
    jle BT_TgtNext
    mov u1, eax
    mov hIdxT, ebx
    mov eax, tsX
    mov hTx, eax
    mov eax, tsY
    mov hTy, eax
BT_TgtNext:
    inc ebx
    jmp BT_Tgt
BT_TgtEnd:
    cmp hIdxT, -1
    je BT_Patrol                       ; 会话46：无活目标改巡逻（旧版此路直跳 BT_Out
    mov bPatrol, 0                     ;  = 六通道全零，打死真人一瞬车原地石化数百
    mov eax, hIdxT                     ;  tick，正是用户所报"走到死角卡着不动"）
    mov ecx, hTx
    mov edx, hTy
BT_TgtSet:
    ; 会话39：目标换人 => 旧路径/航点/卡死计数即刻作废（防陈旧航点带车撞墙）
    cmp eax, bTgtIdx
    jne BT_TgtPurge
BT_TgtW:
    mov bTgtX, ecx
    mov bTgtY, edx
    jmp BT_TgtGo
BT_TgtPurge:
    mov bTgtIdx, eax
    mov bPathOk, 0
    mov bWpX, 0
    mov bWpY, 0
    mov bStuck, 0
    mov bDetourT, 0
    mov bBlk, 0                      ; 会话42：换目标清探墙粘滞
    jmp BT_TgtW
BT_Patrol:
    ; ---- 会话46 巡逻模式：全灭对手后的"观战等待期"不再冻结。确定性换点：
    ;      起点格 = (换点序号*337) mod 总格数（337 与 31、19 互质，步进遍历
    ;      全盘），非空格顺移 337 重试至多 64 次，全败退图心近似格。行进、
    ;      转向、BFS、绕行全套复用；巡逻期禁开火（流弹会误杀刚复活的玩家）、
    ;      禁技能。 ----
    mov eax, bPtrT
    .if eax > 0
        dec eax
        mov bPtrT, eax
        mov edx, bPtrX
        sub edx, bCX
        jns BT_Pt1
        neg edx
BT_Pt1:
        mov ecx, bPtrY
        sub ecx, bCY
        jns BT_Pt2
        neg ecx
BT_Pt2:
        add edx, ecx
        cmp edx, 40
        jae BT_PtUse                   ; 未到点（曼哈顿距离>=40）：继续走
    .endif
    inc bPtrN                          ; 过期/已到 -> 换点
    mov eax, bPtrN
    imul eax, eax, 337
    xor edx, edx
    mov ecx, COLS * ROWS
    div ecx                            ; edx = 起点格号
    mov u2, 64                         ; 剩余尝试数
    xor ebx, ebx                       ; ebx=1 => 已找到空格
BT_PtTry:
    movzx eax, byte ptr mapData[edx]
    cmp eax, TILE_EMPTY
    jne BT_PtNext
    mov ebx, 1
    jmp BT_PtGot
BT_PtNext:
    add edx, 337
    cmp edx, COLS * ROWS
    jb BT_PtIn
    sub edx, COLS * ROWS               ; 337<589 单次回绕充分
BT_PtIn:
    dec u2
    jnz BT_PtTry
BT_PtGot:
    test ebx, ebx
    jne BT_PtCell
    mov edx, (ROWS/2)*COLS + (COLS/2)  ; 全败：取图心格（纵是墙亦有行进姿态）
BT_PtCell:
    mov eax, edx                       ; 格号 -> 中心像素
    xor edx, edx
    mov ecx, COLS
    div ecx                            ; eax=row, edx=col
    imul edx, edx, CELL
    add edx, CELL/2
    mov bPtrX, edx
    imul eax, eax, CELL
    add eax, CELL/2
    mov bPtrY, eax
    mov bPtrT, 240
BT_PtUse:
    mov bPatrol, 1
    mov eax, bPtrX
    mov bTgtX, eax
    mov eax, bPtrY
    mov bTgtY, eax
    jmp BT_TgtGo

BT_TgtGo:
    ; bDct = oct(bTgtX-bCX, bTgtY-bCY)
    mov eax, bTgtX
    sub eax, bCX
    test eax, eax
    jns BT_O1
    neg eax
BT_O1:
    mov ecx, bTgtY
    sub ecx, bCY
    test ecx, ecx
    jns BT_O2
    neg ecx
BT_O2:
    cmp eax, ecx
    jae BT_O3
    xchg eax, ecx
BT_O3:
    shr ecx, 1
    add eax, ecx
    mov bDct, eax

    ; ---- 速度估计：4-tick 采样目标中心入环 ----
    mov eax, gTick
    and eax, 3
    .if eax == 0
        .if bHN != 0
            mov ebx, bHIdx
            dec ebx
            and ebx, 7
            mov eax, bTgtX
            sub eax, bRX[ebx*4]
            test eax, eax
            jns BT_Tl1
            neg eax
BT_Tl1:
            mov t1, eax
            mov eax, bTgtY
            sub eax, bRY[ebx*4]
            test eax, eax
            jns BT_Tl2
            neg eax
BT_Tl2:
            add eax, t1
            cmp eax, 150
            jbe BT_TlGo
            mov bHN, 0
            mov bHIdx, 0
BT_TlGo:
        .endif
        mov ebx, bHIdx
        mov eax, bTgtX
        mov bRX[ebx*4], eax
        mov eax, bTgtY
        mov bRY[ebx*4], eax
        inc ebx
        and ebx, 7
        mov bHIdx, ebx
        mov eax, bHN
        cmp eax, 8
        jae BT_Sv1
        inc eax
        mov bHN, eax
BT_Sv1:
    .endif
    ; vel = (newest-oldest)*256/span
    mov eax, bHN
    cmp eax, 3
    jb BT_VZero
    mov ecx, bHIdx
    sub ecx, eax
    and ecx, 7
    mov edx, bHIdx
    dec edx
    and edx, 7
    mov eax, bRX[ecx*4]
    mov u1, eax
    mov eax, bRY[ecx*4]
    mov u2, eax
    mov eax, bRX[edx*4]
    sub eax, u1
    imul eax, 256
    mov u3, eax
    mov ebx, bHN
    dec ebx
    imul ebx, ebx, 4
    mov eax, u3
    cdq
    idiv ebx
    mov bVelX, eax
    ; idiv 已毁 edx：重取 newest 索引
    mov edx, bHIdx
    dec edx
    and edx, 7
    mov eax, bRY[edx*4]
    sub eax, u2
    imul eax, 256
    cdq
    idiv ebx
    mov bVelY, eax
    jmp BT_VDone
BT_VZero:
    mov bVelX, 0
    mov bVelY, 0
BT_VDone:

    ; ---- 预瞄点 = 目标 + vel*travel ----
    mov eax, bDct
    imul eax, eax, 10
    xor edx, edx
    mov ecx, 27
    div ecx
    cmp eax, 200
    jbe BT_Ld1
    mov eax, 200
BT_Ld1:
    mov u1, eax
    mov eax, bVelX
    imul eax, u1
    sar eax, 8
    add eax, bTgtX
    cmp eax, 8
    jae BT_Ld2
    mov eax, 8
BT_Ld2:
    cmp eax, MAP_W - 8
    jbe BT_Ld3
    mov eax, MAP_W - 8
BT_Ld3:
    mov bPredX, eax
    mov eax, bVelY
    imul eax, u1
    sar eax, 8
    add eax, bTgtY
    cmp eax, 8
    jae BT_Ld4
    mov eax, 8
BT_Ld4:
    cmp eax, MAP_H - 8
    jbe BT_Ld5
    mov eax, MAP_H - 8
BT_Ld5:
    mov bPredY, eax

    ; ---- 视线 ----
    invoke BotLos, bCX, bCY, bPredX, bPredY
    mov bLos, eax

    ; ---- 预瞄角 + 误差 ----
    mov eax, bPredX
    sub eax, bCX
    mov t1, eax
    mov eax, bPredY
    sub eax, bCY
    mov t2, eax
    invoke BotAimDxDy, t1, t2
    mov bAimA, eax
    RL
    mov eax, (TANK ptr [esi]).dir
    sub eax, bAimA
    test eax, eax
    jns BT_E1
    add eax, ANGLE_SPAN
BT_E1:
    cmp eax, ANGLE_SPAN
    jb BT_E2
    sub eax, ANGLE_SPAN
BT_E2:
    cmp eax, 180
    jbe BT_E3
    mov edx, ANGLE_SPAN
    sub edx, eax
    mov eax, edx
BT_E3:
    mov bErrDeg, eax

    ; ---- 寻路节奏（会话39）：错峰每 8 tick 无条件重算 ----
    ; （旧版仅"无 LOS 或远距"才算：围追时 LOS 恢复后旧航点永不过期，
    ;  目标换槽/死亡重生后更是带着跨局航点撞墙。改为常刷，成本 7.5Hz/机。）
    mov eax, gTick
    and eax, 7
    mov ecx, bSlot
    and ecx, 7
    cmp eax, ecx
    jne BT_PathSkip
BT_PathDo:
    call BotBfs
BT_PathSkip:

    ; ---- 驾驶策略 ----
    mov eax, bAimA
    mov bNavA, eax
    mov bDrive, 0
    mov eax, bEvadeT
    .if eax > 0
        dec eax
        mov bEvadeT, eax
        mov eax, bEvadeA
        mov bNavA, eax
        mov bDrive, 1
        cmp bEvadeOwn, 0
        je BTEv1
        cmp bEvadeOwn, 2
        je BT_EvS1                     ; 反弹接近：无限停（会话39 原意）
        inc bEvHold                    ; 会话46：远去弹停步设上限 12tick——规避窗
        cmp bEvHold, 12                ;  每4tick复扫续期会把车钉死在走廊口(实机
        jbe BT_EvS1                    ;  49tick 罚站案)；超时放行，navA 仍侧向，
        jmp BTEv1                      ;  行进即斜出走廊
BT_EvS1:
        mov bDrive, 0                  ; 会话39：自家弹走廊期停步让线（转体继续）
BTEv1:
        ; 规避期每 4 tick 复扫（新威胁可刷新方向）
        mov eax, gTick
        and eax, 3
        .if eax == 0
            call BotThreat
        .endif
    .else
        call BotThreat
        .if bEvadeT > 0
            dec bEvadeT
            mov eax, bEvadeA
            mov bNavA, eax
            mov bDrive, 1
            cmp bEvadeOwn, 0
            je BTEv2
            cmp bEvadeOwn, 2
            je BT_EvS2
            inc bEvHold
            cmp bEvHold, 12
            jbe BT_EvS2
            jmp BTEv2
BT_EvS2:
            mov bDrive, 0
BTEv2:
        .else
            ; 抢道具：比目标近 60px 以上就改道
            mov grabbed, 0
            cmp pickupType, 0
            je BT_Pb
            mov eax, pickupX
            add eax, PICKUP_SIZE/2
            sub eax, bCX
            test eax, eax
            jns BT_G1
            neg eax
BT_G1:
            mov t1, eax
            mov eax, pickupY
            add eax, PICKUP_SIZE/2
            sub eax, bCY
            test eax, eax
            jns BT_G2
            neg eax
BT_G2:
            cmp eax, t1
            jae BT_G3
            xchg eax, t1
BT_G3:
            shr t1, 1
            add eax, t1                ; dPick（oct）
            mov u3, eax
            ; 会话42："不会用技能"根因——技能只能靠拾取激活，而旧改道条件
            ; (dPick<=目标距-60) 几乎永不绕路。空手(skill==0)时主动去抢：
            ; 260px 内直奔道具，抢回才谈得上放技能。
            RL
            cmp (TANK ptr [esi]).skill, 0
            jne BT_PkOld
            cmp u3, 260
            jbe BT_PkGo
            jmp BT_Pb
BT_PkOld:
            mov ecx, bDct
            sub ecx, 60
            cmp u3, ecx
            jae BT_Pb
BT_PkGo:
            mov grabbed, 1
            mov eax, pickupX
            add eax, PICKUP_SIZE/2
            sub eax, bCX
            mov t1, eax
            mov eax, pickupY
            add eax, PICKUP_SIZE/2
            sub eax, bCY
            mov t2, eax
            invoke BotAimDxDy, t1, t2
            mov bNavA, eax
            mov bDrive, 1
BT_Pb:
            cmp grabbed, 0
            jne BT_PolDone
            ; 会话44：驾驶朝向改效用 argmax（BotUtu：主航向 T1 + 敌弹威胁场
            ; T2 + 迟滞锚 T5）。威胁方向的选择逻辑内聚进打分：无威胁时胜者
            ; 恒等于旧导航源（LOS→预瞄角 / 否则航点向角），逐 tick 等价会话42；
            ; 有威胁才按权重侧偏——躲弹不再靠 evadeT 一刀切接管。
            call BotUtu
            mov bNavA, eax
            ; 会话42实机诊断保留：LOS 只做直线墙采样，"直线无墙"≠"车开得到"；
            ; 无视线或正前探墙粘滞(bBlk)一律推进（航点向角已由 BotUtu 接管）。
            cmp bLos, 0
            je BT_Fwd
            cmp bBlk, 0
            jne BT_Fwd
            ; ---- 有视线且正前通畅：距离带管理 ----
            cmp botAggro, 0
            jne BT_AgBand                    ; 会话50c：激进档改贴身缠斗——
            cmp bDct, 130                    ;   后撤带 130→90、中距收油窗删除、
            jb BT_Back                       ;   全程顶进（实测 A/B：单放开火闸
            cmp bDct, 320                    ;   击杀信号不变——卡点在接触率不在
            ja BT_Fwd                        ;   意愿；弹道命中率 27% 已高，加密
                                             ;   接触才能放大击杀）
                                             ; ---- 旧档原样（位级不变）----
            mov eax, gTick
            and eax, 31
            cmp eax, 28
            jb  BT_MidF
            mov bDrive, 0
            jmp BT_PolDone
BT_MidF:
            mov bDrive, 1
            jmp BT_PolDone
BT_Back:
            mov bDrive, -1
            jmp BT_PolDone
BT_Fwd:
            mov bDrive, 1
            jmp BT_PolDone
BT_AgBand:                                   ; 会话50c 激进档距离带
            cmp bDct, 90
            jb BT_Back
            jmp BT_Fwd
BT_PolDone:
        .endif
    .endif

    ; ---- 绕行覆盖（卡死兜底）----
    mov eax, bDetourT
    .if eax > 0
        dec eax
        mov bDetourT, eax
        mov eax, bAimA
        cmp bDetourSide, 0
        jne BT_DetR
        add eax, 90
        cmp eax, ANGLE_SPAN
        jb BT_DetW
        sub eax, ANGLE_SPAN
        jmp BT_DetW
BT_DetR:
        sub eax, 90
        test eax, eax
        jns BT_DetW
        add eax, ANGLE_SPAN
BT_DetW:
        mov bNavA, eax
        mov bDrive, 1
    .endif

    ; ---- 会话46 倒车脱困覆盖：凹袋全向被挡时转向/绕行原地打转（实机 trace：
    ;      (852,499) 钉死 1961tick inF=1/inCCW=1 位移恒 0），唯一出路口是倒出
    ;      进袋方向；bNavA 取起脱时 dir+180±24 快照（不逐 tick 重算，防追尾
    ;      空转），bDrive=-1 走倒车通道（安全门只查前进，不拦）----
    mov eax, bEscT
    .if eax > 0
        dec eax
        mov bEscT, eax
        mov eax, bEscA
        mov bNavA, eax
        mov bDrive, -1
    .endif

    ; ---- 会话42 卡死真凶修复：前进"意图"必须在安全门之前取 ----
    ; 旧版在过程尾取 bDrive，而正前探墙的安全门已把油门摘 0 → 贴墙冻结时
    ; 卡死计数永不累积 → 绕行 30tick / 穿墙 / 驭水三级兜底永不触发，
    ; 人机对着墙发呆不动——正是用户所报"不会自动寻找人"的主因。
    mov eax, bDrive
    cmp eax, 1
    jne BT_It0
    mov bPrevForward, 1
    jmp BT_ItEnd
BT_It0:
    mov bPrevForward, 0
BT_ItEnd:

    ; ---- 前进安全门：正前方车体探墙，挡则处理（免墙技豁免）----
    ; 会话46B：旧版对绕行弧整段豁免 → 30tick 弧顶着油门磨墙，体检挂墙 925 帧
    ; 主因。现绕行同样摘油门：摘的是油门不是舵，弧继续转鼻，鼻让开缺口即续油
    ; ——"磨墙"变"贴角候位"。（曾试"撞墙即翻弧"：探的是物理 dir，翻弧当 tick
    ;   鼻向不变会逐 tick 连翻 + bDetourT 永不过期，T49B 出盒断言实测拒绝。）
    RL
    cmp bDrive, 1
    jne BT_St
    cmp bDetourT, 0
    jne BT_St
    mov edx, (TANK ptr [esi]).effOn
    and edx, (EFF_GHOST or EFF_WATER)
    .if edx == 0
        mov ecx, (TANK ptr [esi]).dir
        mov eax, cosTBL[ecx*4]
        imul eax, eax, 12
        sar eax, TRIG_SHIFT
        add eax, (TANK ptr [esi]).x
        mov ppx, eax
        mov eax, sinTBL[ecx*4]
        imul eax, eax, 12
        sar eax, TRIG_SHIFT
        add eax, (TANK ptr [esi]).y
        mov ppy, eax
        invoke TankBlocked, ppx, ppy
        .if eax != 0
            mov bDrive, 0
            mov bBlk, 1              ; 会话42：粘滞——直到某 tick 正前探通才复位
        .else
            mov bBlk, 0
        .endif
    .endif
BT_St:
    ; ---- 转向输出 + 换向锁（会话46B）----
    ; 体检实据：60s trace 顺/逆交替 984 次（约 26 次/100tick）——效用角逐 tick
    ; 抖几度，3° 死区小于一个 tick 的转量，坦克原地"摇头"。改 5° 死区 + 6tick
    ; 同向锁：锁内反向请求作废（滑行让位），转向从左右蹭变成"转一把再收"。
    RL
    mov eax, bNavA
    sub eax, (TANK ptr [esi]).dir
    test eax, eax
    jns BT_S2
    add eax, ANGLE_SPAN
BT_S2:
    cmp eax, ANGLE_SPAN
    jb BT_S3
    sub eax, ANGLE_SPAN
BT_S3:
    mov edx, eax                       ; edx=0..359 期望偏角
    mov t3, 0                          ; 本 tick 转向请求 0/+1顺/-1逆
    cmp eax, 3                         ; 死区保持 3°：5° 会在 32px 窄门口提前锁舵
    jb  BT_SLk
    cmp eax, 180
    jae BT_SLeft
    mov t3, 1
    jmp BT_SLk
BT_SLeft:
    cmp eax, 358
    jae BT_SLk                         ; 358..359 同入死区（与正向 3° 对称）
    mov t3, -1
    mov eax, 360
    sub eax, edx                       ; 逆时针侧误差折算成幅值
    mov edx, eax
BT_SLk:
    mov eax, bTurnH                    ; 冷却倒数
    .if eax > 0
        dec eax
        mov bTurnH, eax
    .endif
    mov eax, t3
    .if eax != 0 && bTurnD != 0 && eax != bTurnD
        cmp bTurnH, 0
        je BT_SLk2                     ; 锁已过期，放行
        cmp edx, 45                    ; 会话46B：只拦 <45° 的小摆抖动（摇头主源）；
        jb BT_SLk1                     ;  大换向（出盒急转/BFS 拐角）即时改锁放行，
        jmp BT_SLk2                    ;  否则 T49B 脱箱被 coast 拖慢
    .endif
    jmp BT_SLk2
BT_SLk1:
    mov eax, 0                         ; 锁内反向小摆请求作废
BT_SLk2:
    mov t3, eax
    .if eax != 0
        mov bTurnD, eax
        mov bTurnH, 6
    .else
        cmp bTurnH, 0
        jne BT_SNo
        mov bTurnD, 0                  ; 冷却走完且无请求 -> 解锁
    .endif
    cmp t3, 1
    jne BT_ST2
    mov inputTable[edi+12], 1          ; 顺时针
    jmp BT_SNo
BT_ST2:
    cmp t3, -1
    jne BT_SNo
    mov inputTable[edi+8], 1           ; 逆时针
BT_SNo:
    ; ---- 驾驶输出 ----
    cmp bDrive, 1
    jne BT_Dv1
    mov inputTable[edi], 1
    jmp BT_DvEnd
BT_Dv1:
    cmp bDrive, -1
    jne BT_DvEnd
    mov inputTable[edi+4], 1
BT_DvEnd:

    ; ---- 开火（会话39 重构）：直视（LOS+误差<=2）且目标后 216px 内无"兜底墙"。
    ;      钢与砖皆不可拆、皆反弹（会话20 设计变更），屏幕缘同样反弹；贴脸/近墙
    ;      出弹=原路回杀，1HP 必死（T49B 实案：旧"拆墙炮"分支把 mapData 取值当
    ;      布尔使 bot 对 3px 外钢板开火自爆）。故拆墙炮整体移除，墙改走 BFS 绕行。----
    RL
    cmp bPatrol, 0
    jne BT_FNo                          ; 会话46：巡逻期禁开火（无的之矢+误杀复活者）
    cmp botAggro, 0                     ; 会话50b：激进档误差上限 4°→6°，且
    je BT_FR4                           ;   视线闸三级抢救（直视/靶心/盲射走廊）；
    cmp bErrDeg, 6                      ;   旧档此下全程位级不变
    ja BT_FNo
    jmp BT_FRGo
BT_FR4:
    cmp bErrDeg, 4                      ; 会话42：2°→4°（转向 4°/tick 恰一 tick 容差，
    ja BT_FNo                           ; 旧 2° 几乎踩不中，人机整局惜弹像不会开枪）
BT_FRGo:
    cmp bLos, 0
    jne BT_FRGo2                        ; 预瞄位直视：走原安全链
    cmp botAggro, 0
    je BT_FNo                           ; 旧档：无视线即禁火（不变）
    invoke BotLos, bCX, bCY, bTgtX, bTgtY
    cmp eax, 0                          ; 预瞄位遮≠靶心遮：对快速横移目标
    jne BT_FRGo2                        ;   预瞄过头落墙内曾被旧档误判禁火
    cmp bEvadeOwn, 0
    jne BT_FNo
    invoke BotAggroCorr                 ; 盲射走廊：靶后"兜底墙"扫描对回弹
    cmp eax, 0                          ;   射法不适用（弹先撞人即销毁），
    je BT_FNo                           ;   走廊≥180px 通畅即放行
    jmp BT_FSafe
BT_FRGo2:
    cmp bEvadeOwn, 0
    jne BT_FNo                         ; 会话39：自家弹在走廊（追弹/回杀）禁补射
                                          ;（会话50b：上方 bLos 分流后此处不再复查，
                                          ;  靶心抢救路 bLos=0 属正常）
    ; 会话42 实机诊断：贴脸 130px LOS 却整局零开火——"目标身后禁墙"扫描误杀
    ; 了必命中弹（弹先撞人即销毁，根本飞不到身后墙回弹）。转向死区 3°+4°/tick
    ; 步进使稳态瞄准误差恒钉在 2°（转不动也不回），故必中阈值取 ≤2°：2° 偏差在
    ; 200px 处仅横移 7px，小于半车宽，判"必中"跳过回弹否决（目标挂冰盾时弹会被
    ; 盾反射回走廊，反射风险仍在，不放行）。
    cmp bErrDeg, 2
    ja BT_WallScanGo
    cmp bDct, 200
    ja BT_WallScanGo
    mov eax, bTgtIdx
    imul eax, eax, SIZEOF TANK
    lea edx, tanks
    add edx, eax
    mov ecx, (TANK ptr [edx]).effOn
    and ecx, EFF_SHIELD
    jnz BT_WallScanGo
    jmp BT_FSafe
BT_WallScanGo:
    ; 沿 bAimA 自目标中心向前 36..216px 采 6 点：出图=边界；钢/砖=兜底 -> 禁火
    mov ecx, bAimA
    mov edx, cosTBL[ecx*4]
    imul edx, 36
    sar edx, TRIG_SHIFT
    mov esi, sinTBL[ecx*4]
    imul esi, 36
    sar esi, TRIG_SHIFT
    mov eax, bTgtX
    mov t1, eax
    mov eax, bTgtY
    mov t2, eax
    mov u3, 6
BT_FLoop:
    add t1, edx
    add t2, esi
    mov eax, t1
    test eax, eax
    js BT_FNo
    cmp eax, MAP_W
    jae BT_FNo
    mov eax, t2
    test eax, eax
    js BT_FNo
    cmp eax, MAP_H
    jae BT_FNo
    mov ecx, eax
    shr ecx, 5
    imul ecx, ecx, COLS
    mov eax, t1
    shr eax, 5
    add ecx, eax
    movzx eax, byte ptr mapData[ecx]
    cmp eax, TILE_STEEL
    je BT_FNo
    cmp eax, TILE_BRICK
    je BT_FNo
    dec u3
    jnz BT_FLoop
BT_FSafe:
    mov inputTable[edi+16], 1              ; 安全射界：开火
BT_FNo:

    ; ---- 技能 ----
    RL
    cmp bPatrol, 0
    jne BT_SkEnd                        ; 会话46：巡逻期不放技能
    mov edx, (TANK ptr [esi]).aimSkill
    .if edx != 0
        cmp bPrevAim, 0
        jne BT_SkA1
        mov bAimCd, 0
BT_SkA1:
        mov bPrevAim, edx
        cmp (TANK ptr [esi]).aimT, 0
        jne BT_SkEnd
        inc bAimCd
        cmp bAimCd, 14
        jbe BT_SkEnd
        cmp bErrDeg, 3
        ja BT_SkEnd
        mov inputTable[edi+20], 1      ; 二段：复按起爆
        mov bAimCd, 0
        jmp BT_SkEnd
    .endif
    mov bPrevAim, 0
    mov ecx, (TANK ptr [esi]).effOn    ; 已生效位（免重复起技）
    mov eax, (TANK ptr [esi]).skill
    .if eax != 0
        cmp eax, SK_LASER
        je BT_SkLaser                  ; 会话44：激光按时机放（贴脸空大浪费）
        cmp eax, SK_REFLASER
        je BT_SkLaser
        cmp eax, SK_ICE_SHIELD
        je BT_SkShield
        cmp eax, SK_NITRO
        je BT_SkNitro
        cmp eax, SK_GHOST
        je BT_SkGhost
        cmp eax, SK_WATER
        je BT_SkWater
        ; MINE/SWAP/PHANTOM：不用
        jmp BT_SkEnd
BT_SkLaser:
        ; 会话44：有视线等远距放长光束（>120px 才有压制价值）；
        ; 无视线则近处穿墙狙（≤300px，光束穿砖/钢直达），不再一段即按。
        cmp bLos, 0
        je BT_SkL1
        cmp bDct, 120
        jae BT_Press
        jmp BT_SkEnd
BT_SkL1:
        cmp bDct, 300
        jbe BT_Press
        jmp BT_SkEnd
BT_SkShield:
        and ecx, EFF_SHIELD
        .if ecx != 0
            jmp BT_SkEnd
        .endif
        cmp bEvadeT, 0
        jne BT_Press
        cmp bThreatN, 2
        jae BT_Press
        cmp bLos, 0
        je BT_SkEnd                    ; 会话44：贴脸顶盾仅在有目标可压时
        cmp bDct, 160
        jb BT_Press
        jmp BT_SkEnd
BT_SkNitro:
        and ecx, EFF_NITRO
        .if ecx != 0
            jmp BT_SkEnd
        .endif
        cmp bDct, 180                   ; 会话42：240→180，更早开氮气压上
        jb BT_SkEnd
        jmp BT_Press
BT_SkGhost:
        and ecx, EFF_GHOST
        .if ecx != 0
            jmp BT_SkEnd
        .endif
        cmp bLos, 0
        jne BT_SkEnd
        ; 被封死（无路）才穿，或绕行连卡；省 CD
        cmp bPathOk, 0
        je BT_Press
        cmp bStuck, 3
        jae BT_Press
        jmp BT_SkEnd
BT_SkWater:
        and ecx, EFF_WATER
        .if ecx != 0
            jmp BT_SkEnd
        .endif
        cmp bLos, 0
        jne BT_SkEnd
        cmp bStuck, 2
        jb BT_SkEnd
BT_Press:
        mov inputTable[edi+20], 1
    .endif
BT_SkEnd:
    ; ---- 会话42：bPrevForward 已在安全门前记录（意图语义），此处不再覆盖 ----
    jmp BT_Out
BT_Dead:
    ; 会话39：阵亡即刻清寻路/卡死/规避残留（重生点可能远离旧航点）
    mov bPathOk, 0
    mov bStuck, 0
    mov bDetourT, 0
    mov bBlk, 0
    mov bEvadeT, 0
    mov bPrevForward, 0
BT_Out:
    call BotTraceLine                  ; 会话46：bottrace 门控仪表（关=即 ret）
    call BotStoreState
    ret
BotThinkSlot endp



; ------------------------------------------------------------
; BotThink —— 每 tick 对 botMask 命中的每个槽跑一遍决策。
; 由 GameUpdate 在槽循环前 invoke（InputSample 之后）：清零+写入
; 天然覆盖本地键盘对这些槽的输入；非 bot 槽通道不动。
; ------------------------------------------------------------
BotThink proc uses ebx esi edi
    mov eax, gTick
    sub eax, bLastTick
    .if eax != 1
        call BotReset
    .endif
    mov eax, gTick
    mov bLastTick, eax
    xor ebx, ebx
BTh_L:
    cmp ebx, numPlayers
    jae BTh_End
    bt rlBotMask, ebx                  ; 会话47：NN 槽由 rlBotMask 自驱动
    jc BTh_RL                          ;  （不依赖 botMask——换局 mov 不回 NN 位）
    bt botMask, ebx
    jnc BTh_N
    invoke BotThinkSlot, ebx
    jmp BTh_N
BTh_RL:
    invoke RlBotThink, ebx
BTh_N:
    inc ebx
    jmp BTh_L
BTh_End:
    ret
BotThink endp

; ------------------------------------------------------------
; 会话46 bot-trace 仪表 —— CLI "bottrace" 门控（botTrEn=1 才生效）。
; BotTraceLine 每 tick 出一行 CSV：决策中间态 + 最终六通道输出，
; 专抓"贴墙冻结"（意图/油门/粘滞/绕行/寻路/规避 谁没轮到）。
; 常规局与自检 botTrEn 恒 0：proc 首行即 ret，零副作用。
; ------------------------------------------------------------
BotTrComma proc uses eax ecx
    mov ecx, botTrPos
    mov byte ptr botTrBuf[ecx], 44              ; ','
    inc ecx
    mov botTrPos, ecx
    ret
BotTrComma endp

BotTrNum proc uses eax ebx ecx edx esi, pV:DWORD
    mov eax, pV
    mov ecx, botTrPos
    test eax, eax
    jns BTN_G0
    mov byte ptr botTrBuf[ecx], 45              ; '-'
    inc ecx
    neg eax
BTN_G0:
    lea esi, botTrTmp
    mov ebx, 10
BTN_Dig:
    xor edx, edx                      ; 每轮清零！(旧版只清一次，第二轮余数残留
    div ebx                           ; 于 edx 使被除数放大 -> #DE 整数溢出——仪表自炸)
    add edx, 48
    mov [esi], dl
    inc esi
    test eax, eax
    jne BTN_Dig
BTN_Cpy:                                        ; 逆序 digit 串倒灌回 buf
    dec esi
    mov bl, [esi]
    mov byte ptr botTrBuf[ecx], bl
    inc ecx
    cmp esi, OFFSET botTrTmp
    jne BTN_Cpy
    mov botTrPos, ecx
    ret
BotTrNum endp

BotTrFlush proc uses eax ecx edx, pNL:DWORD
    mov ecx, botTrPos
    test ecx, ecx
    je BTF_Done
    .if pNL != 0
        mov byte ptr botTrBuf[ecx], 10
        inc ecx
    .endif
    invoke WriteFile, botTrHv, offset botTrBuf, ecx, addr botTrWrn, NULL
    mov botTrPos, 0
BTF_Done:
    ret
BotTrFlush endp

TRN macro val
    invoke BotTrComma
    mov eax, val
    invoke BotTrNum, eax
endm

BotTraceLine proc uses eax ebx ecx edx esi edi
    cmp botTrEn, 0
    je BTL_Done
    cmp botTrHv, 0
    jne BTL_Emit
    RL
    invoke CreateFileA, offset szBotTr, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    cmp eax, INVALID_HANDLE_VALUE
    je BTL_Done
    mov botTrHv, eax
    invoke WriteFile, eax, offset szBotTrHdr, botTrHdrLen, addr botTrWrn, NULL
BTL_Emit:
    RL
    mov eax, gTick
    invoke BotTrNum, eax
    TRN bSlot
    TRN (TANK ptr [esi]).x
    TRN (TANK ptr [esi]).y
    TRN (TANK ptr [esi]).dir
    TRN bNavA
    TRN bAimA
    TRN bDrive
    TRN bPrevForward
    TRN bBlk
    TRN bStuck
    TRN bDetourT
    TRN bEscT
    TRN bLos
    TRN bDct
    TRN bPathOk
    TRN bWpX
    TRN bWpY
    TRN bTgtIdx
    TRN bTgtX
    TRN bTgtY
    TRN bEvadeT
    TRN bEvadeOwn
    TRN bEvadeA
    TRN (TANK ptr [esi]).skill
    TRN (TANK ptr [esi]).effOn
    TRN (TANK ptr [esi]).fireCd
    TRN inputTable[edi]
    TRN inputTable[edi+4]
    TRN inputTable[edi+8]
    TRN inputTable[edi+12]
    TRN inputTable[edi+16]
    TRN inputTable[edi+20]
    TRN bPatrol
    TRN bEvHold
    TRN (TANK ptr [esi]).alive
    TRN botAggro                        ; 会话50b：末列=激进档实值（验证 RESET 注入到达）
    mov ecx, botTrPos
    mov byte ptr botTrBuf[ecx], 10
    inc ecx
    mov botTrPos, ecx
    invoke WriteFile, botTrHv, offset botTrBuf, botTrPos, addr botTrWrn, NULL
    mov botTrPos, 0
BTL_Done:
    ret
BotTraceLine endp

end
