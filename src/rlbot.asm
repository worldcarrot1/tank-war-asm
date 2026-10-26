; ============================================================
; rlbot.asm —— 会话47 Phase3 蒸馏：run14 冠军 PPO 网络（90->128->128
; ->36，tanh x2，obsv1）逐维复刻进引擎，接管 botMask 槽的六通道输入
; （与键盘同路数，不碰任何结算逻辑——BotThink 约定继承）。
;
; 与 bot.asm 启发式的分工：
;   - botMask 位 i=1 -> 槽 i 由 AI 接管；其中 rlBotMask 位 i=1 者走
;     本模块（BotThink 内二选一）。两掩码全 0 时与旧版逐字节一致
;     （md5 回归锁不破）。
;   - game.asm 四处 BOT_* 属性钩子加 rlBotMask 旁路：NN 槽用玩家属性
;     （训练时 ego 即玩家物理：均速 2.5、2°/t 转向、CD20——蒸馏同分布）。
;   - 策略 = 贪心 argmax（与 eval_greedy 一致）+ "道具信标"叠加层
;     （会话47 16 轮终判：趋近道具是纯权重的策略几何盲区；叠加层按
;     tools/rl_beacon_probe.py 同款算术给 logits 加偏置，rlBeaconEn=0
;     可关回纯权重）。
;   - 观测 90 列逐式对应 rl_train.py build_obs（obsv1）；角度用引擎
;     cosTBL/sinTBL x1024（训练用全精度三角，0.001 量化差远小于
;     argmax 裕度；一致性由 rlbot_trace.bin 与 python 影子网络对拍）。
;
; 数值：x87 float32；权重/tanh 表/倒数常量 = inc/rlw.inc（自动生成）。
;   FPU 控制词仅在本模块决策段切"向零截断"（fistp 取 floor 用），
;   进出 save/restore 不外泄。
; 确定性：只用引擎状态与 gTick；EMA/回合计数按槽隔离；无 RNG。
; CLI："tankwar rlbot"（bot 挑战局但槽1换 NN+玩家属性）
;     "tankwar rlbot rlbotdump"（逐 tick 追加 obs+logits 二进制流）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc
include rlw_cfg.inc          ; RL_HW 隐层宽度（gen_rlbot_data 随网络刷新，会话51 预铺）
IFNDEF RL_HW
RL_HW equ 128                ; cfg 缺位兜底：须与现存 rlw.inc 的矩阵行宽一致
ENDIF
; 会话51 B 预铺：观测尾 12 列弹道 CPA 特征（6 槽×(latN,τN)，与 python
; OBS_V3 逐式）。默认 0=本模块所有 .text/.data 增量被 IF 排除，构建逐位
; 不变；RL_OBSCPA=1 必须由 gen_rlbot_data 同步蒸出 102 列 L1 权重进
; rlw.inc，否则 RlDot 越行读——cfg 位与权重量纲是一对契约。
IFNDEF RL_OBSCPA
RL_OBSCPA equ 0
ENDIF
RL_OBSN equ 90 + 12*RL_OBSCPA
;（rlw.inc 数据段含 dd 初值，必须在 .data 内 include，见下方）

; ---- 跨模块引用 ----
extern tanks        :TANK
extern bullets      :BULLET
extern inputTable   :dword
extern gTick        :dword
extern mapData      :byte
extern pickupType   :dword
extern pickupX      :dword
extern pickupY      :dword
extern cosTBL       :dword
extern sinTBL       :dword
extern matchOver    :dword
extern roundsPlayed :dword
extern maxRounds    :dword

public rlBotMask
public rlBeaconEn
public rlBotTrEn
public RlBotThink
public RlBotReset

; ------------------------------------------------------------
.data
    rlBotMask   dd 0                     ; 位 i：槽 i 由 NN 接管（main.asm 置位）
    rlBeaconEn  dd 1                     ; 道具信标叠加层开关
    rlBotTrEn   dd 0                     ; "rlbotdump" 二进制轨迹开关
    rlTrH       dd 0                     ; 轨迹文件句柄
    rlTrOpened  dd 0                     ; 已尝试建文件标记（0=未尝试）
    cwTrunc     dw 0F7Fh                 ; x87 CW：RC=11 向零截断，PC=11 全精度
    szRlTr      db "rlbot_trace.bin", 0
    rlZero      dd 0                     ; +0.0 位模式（float 零常量）
    include rlw.inc                      ; 自动生成：权重/tanh 表/RLC_* 常量（ifndef 守卫）
    IF RL_OBSCPA
        ; V3 倒数常量仅 RL_OBSCPA=1 构建进镜像（默认构建 .data 逐位不变）
        RLC_INV_300 dd 0.0033333333      ; 横向偏距归一：px -> /300
        RLC_INV_48  dd 0.0208333333      ; τN 时间窗：1 tick /48
    ENDIF
.data?
    rlSlot      dd ?
    rlCur       dd ?                     ; obs 列游标（RlSetF4 推进）
    rlSelfX     dd ?                     ; 自车 x/y 快照（弹/道具列复用）
    rlSelfY     dd ?
    rlOppT      dd ?                     ; 对手 TANK* 备份（弹循环要占 ebx）
    rlObs       dd RL_OBSN dup(?)        ; 观测列（float；默认 90，V3=102）
    rlH1        dd RL_HW dup(?)
    rlH2        dd RL_HW dup(?)
    rlLogit     dd 36 dup(?)             ; 终 logits（信标加过后）
    rlLogitRaw  dd 36 dup(?)             ; 信标前原 logits（dump 对拍用）
    rlEsin      dd 4 dup(?)              ; 敌向 EMA（列 16/17；逐槽）
    rlEcos      dd 4 dup(?)
    rlPrevR     dd 4 dup(?)              ; 上 tick roundsPlayed（变=换局清 EMA）
    rlB6d2      dd 6 dup(?)              ; 最近 6 弹 d2（升序）
    rlB6ix      dd 6 dup(?)              ; 对应弹池下标（-1=空位）
    IF RL_OBSCPA
        ; V3 弹槽暂存：RlFillL 逐槽算 (latN,τN) 存这里，RlBuildObs 末尾
        ; 按槽序统一写入 obs[90..101]（空槽/背离槽置零，与 python 对齐）
        rlB6lat     dd 6 dup(?)
        rlB6tau     dd 6 dup(?)
        rlV3d       dd ?                 ; raw dot=dx*vx+dy*vy（16.16，int）
        rlV3vx      dd ?                 ; v'=v/65536（px/tick，float）
        rlV3vy      dd ?
        rlV3s2      dd ?                 ; |v'|^2
    ENDIF
    ; ---- 暂存：int ----
    rlIT1       dd ?
    rlIT2       dd ?
    rlIT3       dd ?
    rlIT4       dd ?
    rlIT5       dd ?
    ; ---- 暂存：float ----
    rlMinTmp    dd ?                     ; RlMin1 弹出暂存
    rlTanZ      dd ?                     ; RlTanh：z=(x+8)*256
    rlTanI      dd ?                     ; RlTanh：截断整数
    rlTanFr     dd ?                     ; RlTanh：frac
    rlEaF       dd ?                     ; 对手存活 float（EMA 乘子）
    rlSeF       dd ?
    rlCeF       dd ?
    rlDxF       dd ?                     ; 信标：道具向量 float
    rlDyF       dd ?
    rlCF        dd ?                     ; 信标：自车 cos/sin float
    rlSF        dd ?
    rlBkW       dd ?                     ; 信标：距离带权
    rlBkV       dd ?                     ; 信标：单动作偏置
    rlMvsP      dd ?                     ; 信标：mv 分量候选 +dot / -dot
    rlMvsN      dd ?
    rlTnsP      dd ?                     ; 信标：tn 分量候选 +crs / -crs
    rlTnsN      dd ?
    rlAmBest    dd ?                     ; argmax：当前最优值
    rlAmIdx     dd ?                     ; argmax：最优下标（=动作 k）
    rlSwT       dw ?                     ; fnstsw 落点（ml 不认 fnstsw ah，改内存取标志）
    rlBkThr     dd ?                     ; dump：信标门状态 -3关/-2前门拦/n=威胁数
    rlRecHdr    dd 4 dup(?)              ; dump：slot/tick/chosen/bkThr

.code
; ------------------------------------------------------------
; RlBotReset —— BotReset 顺带调用：EMA/回合缓存清零。无打印，自检
; T48/T49 调 BotReset 时行为透明（rlEsin..rlPrevR 连片 12 dword）。
; ------------------------------------------------------------
RlBotReset proc uses eax ecx edi
    lea edi, rlEsin
    mov ecx, 12
    xor eax, eax
    rep stosd
    ret
RlBotReset endp

; ------------------------------------------------------------
; RlMin1 —— st0 = min(st0, 1.0)。
; ------------------------------------------------------------
RlMin1 proc
    fst rlMinTmp
    fcom RLC_ONE                    ; C0 = (v < 1)
    fnstsw rlSwT
    test rlSwT, 0100h               ; C0 位
    jnz  @F                         ; v<1：st0 已是 min
    fstp rlMinTmp                   ; v>=1：弃 v 取 1
    fld RLC_ONE
@@:
    ret
RlMin1 endp

; ------------------------------------------------------------
; RlTanh —— 入口 st0=x，出口 st0=tanh(x)。表 x∈[-8,8]、步长 2^-8、
; 4097 点线性插值；调用方控制词=向零截断 -> fistp 对 z>=0 即 floor，
; z<0 截出 <=0 走 RlTnLo 兜底。
; ------------------------------------------------------------
RlTanh proc
    fld RLC_P8
    faddp st(1), st(0)
    fld RLC_256
    fmulp st(1), st(0)
    fstp rlTanZ
    fld rlTanZ
    fistp rlTanI
    mov eax, rlTanI
    cmp eax, 0
    jl  RlTnLo
    cmp eax, RL_TANH_N - 1
    jge RlTnHi
    fld rlTanZ
    fild rlTanI
    fsubp st(1), st(0)              ; frac = z - i0
    fstp rlTanFr
    fld RL_TANH[4+eax*4]            ; t1
    fld RL_TANH[eax*4]              ; t0
    fsubp st(1), st(0)              ; t1-t0
    fmul rlTanFr
    fld RL_TANH[eax*4]
    faddp st(1), st(0)
    ret
RlTnHi:
    fld RL_TANH[4*(RL_TANH_N-1)]
    ret
RlTnLo:
    fld RL_TANH[0]
    ret
RlTanh endp

; ------------------------------------------------------------
; RlSetF4 —— st0 写 rlObs[rlCur*4]，游标 +1。
; ------------------------------------------------------------
RlSetF4 proc uses eax
    mov eax, rlCur
    fstp rlObs[eax*4]
    inc eax
    mov rlCur, eax
    ret
RlSetF4 endp

; ------------------------------------------------------------
; RlDot —— st0 = Σ_{i<n} [pIn+i*4] * [pW+i*4]（pW=[out][in] 矩阵的一行）。
; ------------------------------------------------------------
RlDot proc uses ecx esi edi, pIn: dword, pW: dword, n: dword
    mov esi, pIn
    mov edi, pW
    mov ecx, n
    fldz
RlD_L:
    fld dword ptr [esi]
    fmul dword ptr [edi]
    faddp st(1), st(0)
    add esi, 4
    add edi, 4
    dec ecx
    jnz RlD_L
    ret
RlDot endp

; ------------------------------------------------------------
; RlBuildObs —— 逐维复刻 build_obs（obsv1）。
; 入参寄存器：esi=自车 TANK*，ebx=对手 TANK*；rlOppT 也须已置=ebx。
; 出口：rlCur=RL_OBSN（默认=90；RL_OBSCPA=1 时=102）。uses 全名单 -> 调用者寄存器不损（弹循环占 ebx）。
; EMA 每列 16/17 在构建时更新——死亡 tick 也照建（与 python 同步）。
; ------------------------------------------------------------
RlBuildObs proc uses eax ebx ecx edx esi edi ebp
    lea edi, rlObs
    mov ecx, RL_OBSN
    xor eax, eax
    rep stosd
    mov rlCur, 0
    mov eax, (TANK ptr [esi]).x
    mov rlSelfX, eax
    mov eax, (TANK ptr [esi]).y
    mov rlSelfY, eax
    ; ---- [0..3] 位姿 ----
    fild rlSelfX
    fmul RLC_INV_W
    call RlSetF4
    fild rlSelfY
    fmul RLC_INV_H
    call RlSetF4
    mov eax, (TANK ptr [esi]).dir
    fild dword ptr sinTBL[eax*4]
    fmul RLC_INV_1024
    call RlSetF4
    fild dword ptr cosTBL[eax*4]
    fmul RLC_INV_1024
    call RlSetF4
    ; ---- [4..10] 自车状态 ----
    cmp (TANK ptr [esi]).alive, 0
    je RlB4z
    fld RLC_ONE
    jmp RlB4s
RlB4z:
    fld rlZero
RlB4s:
    call RlSetF4
    fild (TANK ptr [esi]).fireCd
    fmul RLC_INV_30
    call RlMin1
    call RlSetF4
    fild (TANK ptr [esi]).skill
    fmul RLC_INV_8
    call RlMin1
    call RlSetF4
    cmp (TANK ptr [esi]).effOn, 0
    je RlB7z
    fld RLC_ONE
    jmp RlB7s
RlB7z:
    fld rlZero
RlB7s:
    call RlSetF4
    cmp (TANK ptr [esi]).shieldT, 0
    je RlB8z
    fld RLC_ONE
    jmp RlB8s
RlB8z:
    fld rlZero
RlB8s:
    call RlSetF4
    cmp (TANK ptr [esi]).protT, 0
    je RlB9z
    fld RLC_ONE
    jmp RlB9s
RlB9z:
    fld rlZero
RlB9s:
    call RlSetF4
    fild (TANK ptr [esi]).lives
    fmul RLC_INV_3
    call RlSetF4                        ; [10]

    ; ---- [11..20] 对手 + 敌向 EMA ----
    cmp (TANK ptr [ebx]).alive, 0
    je RlEaz
    fld RLC_ONE
    jmp RlEas
RlEaz:
    fld rlZero
RlEas:
    fst rlEaF
    call RlSetF4                        ; [11]
    mov eax, (TANK ptr [ebx]).x
    sub eax, rlSelfX
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_W
    call RlSetF4                        ; [12]
    mov eax, (TANK ptr [ebx]).y
    sub eax, rlSelfY
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_H
    call RlSetF4                        ; [13]
    mov eax, (TANK ptr [ebx]).dir
    fild dword ptr sinTBL[eax*4]
    fmul RLC_INV_1024
    fst rlSeF
    call RlSetF4                        ; [14] se 原值（不乘 ea，同 python）
    fild dword ptr cosTBL[eax*4]
    fmul RLC_INV_1024
    fst rlCeF
    call RlSetF4                        ; [15]
    mov ebp, rlSlot
    fld rlSeF
    fmul rlEaF
    fld rlEsin[ebp*4]
    fsubp st(1), st(0)                  ; se*ea - esin
    fmul RLC_EMA_A
    fld rlEsin[ebp*4]
    faddp st(1), st(0)
    fst rlEsin[ebp*4]
    call RlSetF4                        ; [16] 更新后 esin
    fld rlCeF
    fmul rlEaF
    fld rlEcos[ebp*4]
    fsubp st(1), st(0)
    fmul RLC_EMA_A
    fld rlEcos[ebp*4]
    faddp st(1), st(0)
    fst rlEcos[ebp*4]
    call RlSetF4                        ; [17]
    cmp (TANK ptr [ebx]).aimT, 0
    je RlB18z
    fld RLC_ONE
    jmp RlB18s
RlB18z:
    fld rlZero
RlB18s:
    call RlSetF4                        ; [18]
    fild (TANK ptr [ebx]).skill
    fmul RLC_INV_8
    call RlMin1
    call RlSetF4                        ; [19]
    cmp (TANK ptr [ebx]).effOn, 0
    je RlB20z
    fld RLC_ONE
    jmp RlB20s
RlB20z:
    fld rlZero
RlB20s:
    call RlSetF4                        ; [20]

    ; ---- [21..56] 最近 6 弹（含自弹：build_obs 不滤 owner）----
    mov eax, 7FFFFFFFh
    mov edx, -1
    mov ecx, 0
RlB6i:
    mov rlB6d2[ecx*4], eax
    mov rlB6ix[ecx*4], edx
    inc ecx
    cmp ecx, 6
    jb RlB6i
    xor edi, edi                        ; i=弹下标
RlPoolL:
    cmp edi, MAX_BULLETS
    jae RlPoolEnd
    imul ecx, edi, SIZEOF BULLET
    lea ebx, bullets
    add ebx, ecx
    cmp (BULLET ptr [ebx]).active, 0
    je RlPoolN
    mov ecx, (BULLET ptr [ebx]).x
    sub ecx, rlSelfX
    imul ecx, ecx                       ; dx^2
    mov edx, (BULLET ptr [ebx]).y
    sub edx, rlSelfY
    imul edx, edx
    add ecx, edx                        ; d2 (<=2.1e6，int32 安全)
    xor eax, eax                        ; 找插入位
RlSrch:
    cmp ecx, rlB6d2[eax*4]
    jb RlIns
    inc eax
    cmp eax, 6
    jb RlSrch
    jmp RlPoolN
RlIns:
    mov rlIT1, eax
    mov edx, 5
RlSh:
    cmp edx, rlIT1
    jbe RlShEnd
    mov eax, rlB6d2[edx*4-4]
    mov rlB6d2[edx*4], eax
    mov eax, rlB6ix[edx*4-4]
    mov rlB6ix[edx*4], eax
    dec edx
    jmp RlSh
RlShEnd:
    mov eax, rlIT1
    mov rlB6d2[eax*4], ecx
    mov rlB6ix[eax*4], edi
RlPoolN:
    inc edi
    jmp RlPoolL
RlPoolEnd:
    xor ecx, ecx                        ; 填充 k=0..5
RlFillL:
    mov eax, rlB6ix[ecx*4]
    test eax, eax
    js RlFillE
    imul ebx, eax, SIZEOF BULLET
    lea eax, bullets
    add ebx, eax                        ; ebx=&弹（注意：先借 eax 存基址）
    mov eax, (BULLET ptr [ebx]).x
    sub eax, rlSelfX
    mov rlIT1, eax                      ; dx
    mov eax, (BULLET ptr [ebx]).y
    sub eax, rlSelfY
    mov rlIT2, eax                      ; dy
    mov eax, (BULLET ptr [ebx]).vx
    mov rlIT3, eax                      ; vx（引擎即 16.16 有符号 dd）
    mov eax, (BULLET ptr [ebx]).vy
    mov rlIT4, eax
    fild rlIT1
    fmul RLC_INV_W
    call RlSetF4
    fild rlIT2
    fmul RLC_INV_H
    call RlSetF4
    fild rlIT3
    fmul RLC_INV_FP
    call RlSetF4
    fild rlIT4
    fmul RLC_INV_FP
    call RlSetF4
    mov eax, rlIT1
    imul eax, rlIT3                     ; |dx*vx| <= 1.8e8 安全
    mov edx, rlIT2
    imul edx, rlIT4
    add eax, edx                        ; dot = dx*vx + dy*vy
    IF RL_OBSCPA
    mov rlV3d, eax                      ; V3 暂存 raw dot（RlSetF4 会毁 eax）
    ENDIF
    test eax, eax
    jns RlFillAway
    fld RLC_ONE                         ; 接近中
    jmp RlFillDs
RlFillAway:
    fld rlZero
RlFillDs:
    call RlSetF4                        ; 接近旗标
    fld RLC_ONE
    call RlSetF4                        ; 在场=1.0
    IF RL_OBSCPA
    ; ---- V3 尾列暂存（与 rl_train.build_obs 逐式，ego 静止参照预测）----
    ; r=弹->我，迎面量 dot3=-dot_raw；背离/平行(dot3<=0，含 v=0→dot3=0)
    ; 走置零支——与 python `s2>0 and dot>0` 双门等价。
    cmp rlV3d, 0
    jle RlV3Off
    fild rlIT3
    fmul RLC_INV_FP
    fstp rlV3vx                         ; vxp
    fild rlIT4
    fmul RLC_INV_FP
    fstp rlV3vy                         ; vyp
    fld rlV3vx
    fmul rlV3vx
    fstp rlV3s2
    fld rlV3vy
    fmul rlV3vy
    fadd rlV3s2
    fstp rlV3s2                         ; s2'=|v'|^2 >0
    ; latN = |vyp*dx - vxp*dy| / sqrt(s2') / 300（叉积/模=CPA 横向偏距，
    ;        raw 65536 尺度在分子分母同次约掉，与 python 原始整数式同值）
    fld rlV3vy
    fild rlIT1
    fmulp st(1), st(0)
    fld rlV3vx
    fild rlIT2
    fmulp st(1), st(0)
    fsubrp st(1), st(0)
    fabs
    fld rlV3s2
    fsqrt
    fdivp st(1), st(0)
    fmul RLC_INV_300
    fstp rlB6lat[ecx*4]
    ; τN = max(0, 1 - t*/48)，t* = dot3/s2 = (-dot_raw/65536)/s2'（拍数）
    fild rlV3d
    fchs
    fmul RLC_INV_FP
    fdiv rlV3s2
    fmul RLC_INV_48
    fld RLC_ONE
    fsubrp st(1), st(0)
    fstp rlB6tau[ecx*4]
    mov eax, rlB6tau[ecx*4]             ; 负值(符号位)回 0，对齐 max(0,·)
    test eax, eax
    jns RlV3Go
    mov rlB6tau[ecx*4], 0
    jmp RlV3Go
RlV3Off:
    mov rlB6lat[ecx*4], 0
    mov rlB6tau[ecx*4], 0
RlV3Go:
    ENDIF
    jmp RlFillN
RlFillE:
    add rlCur, 6                        ; 空位四列+旗标+在场 全零占位
    IF RL_OBSCPA
    mov rlB6lat[ecx*4], 0               ; 空槽 V3 尾列=0（python j>=len(bl) 支）
    mov rlB6tau[ecx*4], 0
    ENDIF
RlFillN:
    inc ecx
    cmp ecx, 6
    jb RlFillL

    ; ---- [57..81] 5x5 地图窗（越界=1.0）----
    mov eax, rlSelfX
    shr eax, 5
    mov rlIT1, eax                      ; cx
    mov eax, rlSelfY
    shr eax, 5
    mov rlIT2, eax                      ; cy
    xor ecx, ecx                        ; r
RlRowL:
    mov ebx, rlIT2
    sub ebx, 2
    add ebx, ecx                        ; gy=cy-2+r
    mov eax, -1
    cmp ebx, 0
    jl RlRowOOB
    cmp ebx, ROWS
    jae RlRowOOB
    imul eax, ebx, COLS
RlRowOOB:
    mov rlIT3, eax                      ; 行基址 or -1
    xor edx, edx                        ; c
RlColL:
    cmp rlIT3, 0
    jl RlCellOOB
    mov ebx, rlIT1
    sub ebx, 2
    add ebx, edx                        ; gx
    cmp ebx, 0
    jl RlCellOOB
    cmp ebx, COLS
    jae RlCellOOB
    add ebx, rlIT3
    movzx eax, byte ptr mapData[ebx]
    mov rlIT4, eax
    fild rlIT4
    fmul RLC_INV_6
    call RlSetF4
    jmp RlCellN
RlCellOOB:
    fld RLC_ONE
    call RlSetF4
RlCellN:
    inc edx
    cmp edx, 5
    jb RlColL
    inc ecx
    cmp ecx, 5
    jb RlRowL

    ; ---- [82..85] 道具（obsv1：在场1, dx/W, dy/H, 型/8）----
    mov eax, pickupType
    test eax, eax
    je RlPkNo
    fld RLC_ONE
    call RlSetF4
    mov eax, pickupX
    sub eax, rlSelfX
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_W
    call RlSetF4
    mov eax, pickupY
    sub eax, rlSelfY
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_H
    call RlSetF4
    mov eax, pickupType
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_8
    call RlSetF4
    jmp RlPkEnd
RlPkNo:
    add rlCur, 4
RlPkEnd:

    ; ---- [86..89] 比分/局数/终局 ----
    fild (TANK ptr [esi]).score
    fmul RLC_INV_3
    call RlSetF4
    mov eax, rlOppT
    mov eax, (TANK ptr [eax]).score
    mov rlIT1, eax
    fild rlIT1
    fmul RLC_INV_3
    call RlSetF4
    mov eax, maxRounds
    .if eax == 0
        mov eax, 1
    .endif
    mov rlIT1, eax
    fild roundsPlayed
    fild rlIT1
    fdivp st(1), st(0)
    call RlSetF4
    cmp matchOver, 0
    je RlMz
    fld RLC_ONE
    jmp RlMs
RlMz:
    fld rlZero
RlMs:
    call RlSetF4                        ; [89]；rlCur 此刻=90
    IF RL_OBSCPA
    ; ---- [90..101] V3 尾：按弹槽同序写 (latN,τN)（暂存已在 RlFillL 备好）----
    xor ecx, ecx
RlV3P:
    fld rlB6lat[ecx*4]
    call RlSetF4
    fld rlB6tau[ecx*4]
    call RlSetF4
    inc ecx
    cmp ecx, 6
    jb RlV3P
    ; rlCur 此刻=RL_OBSN(102)
    ENDIF
    ret
RlBuildObs endp

; ------------------------------------------------------------
; RlForward —— RL_OBSN(默认90)->RL_HW(tanh)->RL_HW(tanh)->36(无 tanh)。
; 权重行主序 [out][in]：第 j 输出行 = RLW_Lx + j*in*4。RL_OBSCPA=1 时
; rlw.inc 的 L1 行宽必须是 102（gen 同步蒸 obsv3 权重，契约见头部注释）。
; ------------------------------------------------------------
RlForward proc uses eax ebx ecx
    lea ebx, RLW_L1
    xor ecx, ecx
RlF1L:
    invoke RlDot, offset rlObs, ebx, RL_OBSN
    fadd RLB_1[ecx*4]
    call RlTanh
    fstp rlH1[ecx*4]
    add ebx, RL_OBSN*4
    inc ecx
    cmp ecx, RL_HW
    jb RlF1L
    lea ebx, RLW_L2
    xor ecx, ecx
RlF2L:
    invoke RlDot, offset rlH1, ebx, RL_HW
    fadd RLB_2[ecx*4]
    call RlTanh
    fstp rlH2[ecx*4]
    add ebx, RL_HW*4
    inc ecx
    cmp ecx, RL_HW
    jb RlF2L
    lea ebx, RLW_P
    xor ecx, ecx
RlF3L:
    invoke RlDot, offset rlH2, ebx, RL_HW
    fadd RLB_P[ecx*4]
    fstp rlLogit[ecx*4]
    add ebx, RL_HW*4
    inc ecx
    cmp ecx, 36
    jb RlF3L
    ret
RlForward endp

; ------------------------------------------------------------
; RlBeacon —— 道具信标叠加层：给"能接近道具"的动作加 logits 偏置。
; 与 tools/rl_beacon_probe.py beacon_bonus 逐式对应（无超越函数，
; 只有 mul/add/fsqrt；距离判定全走 d2 整数比较，与 d 阈值等价）。
;   门：道具在场 & 自车活 & 40<d<700 & 260px 内接近中敌弹 <= RL_B_THREAT
;   带：w = 1.0(d<200) / 0.6(<400) / 0.3
;   值：b[k] = w * (BKM*mvs + BKT*tns)
;        mvs = +dot(前进) / -dot(倒车) / 0(停)
;        tns = -crs(左转) / +crs(右转) / 0(停)   crs=sin(道具角-车头角)
; ------------------------------------------------------------
RlBeacon proc uses eax ebx ecx edx esi edi ebp
    mov eax, -2
    mov rlBkThr, eax                    ; 先标"前门拦截"，过闸后改写为威胁计数
    cmp pickupType, 0
    je RlBkRet
    mov esi, rlSlot
    imul esi, esi, SIZEOF TANK
    add esi, OFFSET tanks
    cmp (TANK ptr [esi]).alive, 0
    je RlBkRet
    mov eax, pickupX
    sub eax, (TANK ptr [esi]).x
    mov rlIT1, eax                      ; dx
    mov eax, pickupY
    sub eax, (TANK ptr [esi]).y
    mov rlIT2, eax                      ; dy
    mov ecx, rlIT1
    imul ecx, ecx
    mov edx, rlIT2
    imul edx, edx
    add ecx, edx                        ; d2
    mov rlIT5, ecx
    cmp ecx, 1600                       ; d<40 → 让 NN 自己收口
    jl RlBkRet
    cmp ecx, 490000                     ; d>700 → 不值得绕
    jg RlBkRet
    ; 距离带权
    cmp ecx, 40000
    jl RlBkW1
    cmp ecx, 160000
    jl RlBkW2
    fld RLC_BW3
    jmp RlBkW
RlBkW1:
    fld RLC_BW1
    jmp RlBkW
RlBkW2:
    fld RLC_BW2
RlBkW:
    fstp rlBkW
    ; 威胁闸：260px 内接近中敌弹（owner!= 本槽；同 python 过滤自弹）
    xor ebx, ebx                        ; cnt
    xor edi, edi                        ; i
RlThL:
    cmp edi, MAX_BULLETS
    jae RlThEnd
    imul ecx, edi, SIZEOF BULLET
    lea eax, bullets
    add eax, ecx
    mov ecx, eax                        ; ecx=&b
    cmp (BULLET ptr [ecx]).active, 0
    je RlThN
    mov eax, (BULLET ptr [ecx]).owner
    cmp eax, rlSlot
    je RlThN
    mov eax, (BULLET ptr [ecx]).x
    sub eax, (TANK ptr [esi]).x
    mov rlIT3, eax                      ; bdx
    mov eax, (BULLET ptr [ecx]).y
    sub eax, (TANK ptr [esi]).y
    mov rlIT4, eax                      ; bdy
    mov eax, rlIT3
    imul eax, eax
    mov edx, rlIT4
    imul edx, edx
    add eax, edx
    cmp eax, 67600                      ; 260^2
    jge RlThN
    mov eax, rlIT3
    imul eax, (BULLET ptr [ecx]).vx     ; |bdx*v| <= 1.8e8 安全
    mov edx, rlIT4
    imul edx, (BULLET ptr [ecx]).vy
    add eax, edx
    test eax, eax
    jns RlThN                           ; 远离中不计
    inc ebx
    cmp ebx, RL_B_THREAT
    jg RlBkTh                           ; 太烫 -> 关信标（门槛上抛：计数记进 aux）
    jmp RlThN
RlBkTh:
    mov rlBkThr, ebx
    jmp RlBkRet
RlThN:
    inc edi
    jmp RlThL
RlThEnd:
    mov rlBkThr, ebx                    ; 门放行：记当时威胁计数
    ; 车头单位向量 float
    fild rlIT1
    fstp rlDxF
    fild rlIT2
    fstp rlDyF
    mov eax, (TANK ptr [esi]).dir
    fild dword ptr cosTBL[eax*4]
    fmul RLC_INV_1024
    fstp rlCF
    fild dword ptr sinTBL[eax*4]
    fmul RLC_INV_1024
    fstp rlSF
    ; dotN = (c*dx + s*dy)/d
    fld rlCF
    fmul rlDxF
    fld rlSF
    fmul rlDyF
    faddp st(1), st(0)
    fild rlIT5
    fsqrt
    fdivp st(1), st(0)
    fstp rlMvsP
    mov eax, rlMvsP
    xor eax, 80000000h
    mov rlMvsN, eax                     ; 倒车分量 = -dotN
    ; crsN = (c*dy - s*dx)/d
    fld rlCF
    fmul rlDyF
    fld rlSF
    fmul rlDxF
    fsubp st(1), st(0)
    fild rlIT5
    fsqrt
    fdivp st(1), st(0)
    fstp rlTnsP
    mov eax, rlTnsP
    xor eax, 80000000h
    mov rlTnsN, eax                     ; 左转分量 = -crsN
    ; 9 组合 (mv,tn) x 4 (f,s)：同偏置写 4 条连续 logits
    xor edi, edi                        ; mv 0..2
RlMvL:
    xor ebp, ebp                        ; tn 0..2
RlTnL:
    cmp edi, 0
    je RlMv0
    cmp edi, 1
    je RlMv1
    fld rlZero
    jmp RlMvS
RlMv0:
    fld rlMvsP
    jmp RlMvS
RlMv1:
    fld rlMvsN
RlMvS:
    fmul RLC_BKM
    cmp ebp, 0
    je RlTn0
    cmp ebp, 1
    je RlTn1
    fld rlZero
    jmp RlTnS
RlTn0:
    fld rlTnsN
    jmp RlTnS
RlTn1:
    fld rlTnsP
RlTnS:
    fmul RLC_BKT
    faddp st(1), st(0)                  ; KM*mvs + KT*tns
    fmul rlBkW
    fstp rlBkV
    mov eax, edi
    imul eax, eax, 12
    mov ecx, ebp
    shl ecx, 2
    add eax, ecx                        ; base=mv*12+tn*4
    mov ecx, 4
RlAddL:
    fld rlLogit[eax*4]
    fadd rlBkV
    fstp rlLogit[eax*4]
    inc eax
    dec ecx
    jnz RlAddL
    inc ebp
    cmp ebp, 3
    jb RlTnL
    inc edi
    cmp edi, 3
    jb RlMvL
RlBkRet:
    ret
RlBeacon endp

; ------------------------------------------------------------
; RlChoose —— 贪心 argmax（等值取先，同 np.argmax）+ 六通道解码。
; k = mv*12 + tn*4 + f*2 + s；mv 0前进1倒车2停；tn 0左转1右转2停。
; ------------------------------------------------------------
RlChoose proc uses eax ebx ecx edx edi
    fld rlLogit[0]
    fstp rlAmBest
    mov rlAmIdx, 0
    mov rlIT3, 1                        ; 环路计数走内存：fnstsw ah 会毁 eax 高字节
RlAmL:
    cmp rlIT3, 36
    jae RlAmEnd
    mov eax, rlIT3
    fld rlLogit[eax*4]
    fcom rlAmBest                       ; C0=(v<best) C3=(v==best)
    fnstsw rlSwT
    test rlSwT, 4100h                   ; C3|C0：v<=best 保留旧（含相等，同 np.argmax）
    jnz RlAmKeep
    fstp rlAmBest
    mov eax, rlIT3
    mov rlAmIdx, eax
    jmp RlAmN
RlAmKeep:
    fstp rlMinTmp
RlAmN:
    inc rlIT3
    jmp RlAmL
RlAmEnd:
    mov eax, rlAmIdx
    mov edx, 0
    mov ecx, 12
    div ecx                             ; eax=mv edx=rem(=tn*4+f*2+s)
    mov rlIT2, edx
    mov edi, rlSlot
    imul edi, edi, KEY_PER*4
    lea ecx, inputTable
    add edi, ecx
    test eax, eax
    je RlC_fwd
    cmp eax, 1
    je RlC_back
    jmp RlC_mvD
RlC_fwd:
    mov dword ptr [edi], 1
    jmp RlC_mvD
RlC_back:
    mov dword ptr [edi+4], 1
RlC_mvD:
    mov eax, rlIT2
    shr eax, 2                          ; tn
    test eax, eax
    je RlC_ccw
    cmp eax, 1
    je RlC_cw
    jmp RlC_tnD
RlC_ccw:
    mov dword ptr [edi+8], 1
    jmp RlC_tnD
RlC_cw:
    mov dword ptr [edi+12], 1
RlC_tnD:
    mov eax, rlIT2
    and eax, 3
    shr eax, 1                          ; f
    .if eax != 0
        mov dword ptr [edi+16], 1
    .endif
    mov eax, rlIT2
    and eax, 1                          ; s
    .if eax != 0
        mov dword ptr [edi+20], 1
    .endif
    ret
RlChoose endp

; ------------------------------------------------------------
; RlDump —— "rlbotdump"：每决策 tick 追加 664B 记录
; [slot|tick|chosen|bkThr][90 obs][36 原logits][36 信标后logits]，全
; float32/int32 位模式。bkThr：-3=信标关 -2=前门拦 n>=0=威胁计数。
; python 影子网络（tools/rl_distill_check.py）同 obs 复算对拍。
; ------------------------------------------------------------
RlDump proc uses eax ecx edx
    .if rlTrOpened == 0
        mov rlTrOpened, 1
        invoke CreateFileA, offset szRlTr, GENERIC_WRITE, 0, NULL, \
               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
        mov rlTrH, eax
    .endif
    cmp rlTrH, -1
    je RlDRet
    mov eax, rlSlot
    mov rlRecHdr[0], eax
    mov eax, gTick
    mov rlRecHdr[4], eax
    mov eax, rlAmIdx
    mov rlRecHdr[8], eax
    mov eax, rlBkThr
    mov rlRecHdr[12], eax
    invoke WriteFile, rlTrH, offset rlRecHdr, 16, addr rlIT1, NULL
    invoke WriteFile, rlTrH, offset rlObs, RL_OBSN*4, addr rlIT1, NULL
    invoke WriteFile, rlTrH, offset rlLogitRaw, 36*4, addr rlIT1, NULL
    invoke WriteFile, rlTrH, offset rlLogit, 36*4, addr rlIT1, NULL
RlDRet:
    ret
RlDump endp

; ------------------------------------------------------------
; RlBotThink —— 单槽一 tick 的 NN 决策（BotThink 对 rlBotMask 命中
; 槽 invoke）。死亡也照建观测（EMA 与 python 同步），但死亡不写通道
; （引擎死亡忽略输入，与训练环境等价）。
; ------------------------------------------------------------
RlBotThink proc uses eax ebx ecx edx esi edi, pSlot: dword
    mov eax, pSlot
    mov rlSlot, eax
    sub esp, 4
    fnstcw word ptr [esp]               ; 控制词入栈（stdcall 帧内局部）
    fldcw cwTrunc                       ; 决策段截断取整模式
    ; ---- 六通道清零（覆盖键盘残留，与启发式同构）----
    mov edi, eax
    imul edi, edi, KEY_PER*4
    lea ecx, inputTable
    add edi, ecx
    mov dword ptr [edi], 0
    mov dword ptr [edi+4], 0
    mov dword ptr [edi+8], 0
    mov dword ptr [edi+12], 0
    mov dword ptr [edi+16], 0
    mov dword ptr [edi+20], 0
    ; ---- 指针：自车/对手（两车约定：opp = 1-slot）----
    mov esi, eax
    imul esi, esi, SIZEOF TANK
    add esi, OFFSET tanks
    xor ebx, ebx
    .if eax == 0
        mov ebx, 1
    .endif
    imul ebx, ebx, SIZEOF TANK
    add ebx, OFFSET tanks
    ; ---- 换局清 EMA（roundsPlayed 变 = python reseed）----
    mov eax, roundsPlayed
    mov ecx, rlSlot
    cmp eax, rlPrevR[ecx*4]
    je RlNoRR
    mov rlPrevR[ecx*4], eax
    mov dword ptr rlEsin[ecx*4], 0
    mov dword ptr rlEcos[ecx*4], 0
RlNoRR:
    mov rlOppT, ebx
    call RlBuildObs
    cmp (TANK ptr [esi]).alive, 0
    je RlBtRet
    call RlForward
    lea esi, rlLogit                    ; 原 logits 快照（信标叠加前的纯网络输出）
    lea edi, rlLogitRaw
    mov ecx, 36
    cld
    rep movsd
    cmp rlBeaconEn, 0
    je RlBtNoBk
    call RlBeacon
    jmp RlBtCh
RlBtNoBk:
    mov eax, -3
    mov rlBkThr, eax                    ; dump aux：信标整体关闭
RlBtCh:
    call RlChoose
    cmp rlBotTrEn, 0
    je RlBtRet
    call RlDump
RlBtRet:
    fldcw word ptr [esp]                ; 恢复调用方控制词
    add esp, 4
    ret
RlBotThink endp

end
