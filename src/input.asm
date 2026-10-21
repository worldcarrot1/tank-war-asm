; ============================================================
; input.asm —— 键盘输入采样（键位表驱动）
; 每 tick 用 GetAsyncKeyState 扫描 keyTable（4 人 x 6 键：
; 上/下/左/右/开火/技能，键位可在人数页容器或设置界面重绑），
; 结果写入 inputTable。
; R = 重开整场（固定键）；菜单导航键由 ui.asm 自行处理。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

extern keyTable    :dword
extern inputTable  :dword
extern inputRestart :dword
extern netMode      :dword           ; ui.asm（会话36：联机对局）

.data
    ; ---- 会话34：开局武装 ----
    ; GameInit/换局 调 InputArmHold 置 playArm=0，下一次 InputSample 先记录
    ; "进场瞬间哪些键正被按住"（如按 Enter 确认开局=同时是 P2 开火键），
    ; 这些键在松开一次之前一律报 0，防止开局走火。
    inputArm dd MAX_PLAYERS*KEY_PER dup (0)
    playArm  dd 1

.code

; ------------------------------------------------------------
; InputArmHold —— 进入对局时调用（GameInit / 新一轮 ResetTanks 后）
; ------------------------------------------------------------
InputArmHold proc
    mov playArm, 0
    ret
InputArmHold endp

; ------------------------------------------------------------
; InputSample —— 每 tick 调用一次，扫描全部键位
; ------------------------------------------------------------
InputSample proc uses ebx esi edi
    local act: dword                 ; 动作计数（invoke 会破坏易失寄存器，不能寄存器计数）
    .if playArm == 0
        mov playArm, 1
        xor ebx, ebx
        mov esi, offset keyTable
        mov edi, offset inputArm
IAR_Loop:
        mov eax, [esi]
        invoke GetAsyncKeyState, eax
        and eax, 8000h
        mov ecx, 0
        .if eax != 0
            mov ecx, 1
        .endif
        mov dword ptr [edi], ecx
        add esi, 4
        add edi, 4
        inc ebx
        .if ebx < MAX_PLAYERS*KEY_PER
            jmp IAR_Loop
        .endif
    .endif
    xor ebx, ebx                     ; slot
    mov esi, offset keyTable
    mov edi, offset inputTable
IS_Slot:
    mov act, 0                       ; action 0..4
IS_Act:
    mov eax, [esi]
    invoke GetAsyncKeyState, eax
    and eax, 8000h
    mov edx, ebx
    imul edx, edx, KEY_PER
    add edx, act                     ; edx = 槽位索引 slot*KEY_PER+action
    .if eax != 0
        .if inputArm[edx*4] != 0
            mov dword ptr [edi], 0   ; 进场按住未松：屏蔽（会话34）
        .else
            mov dword ptr [edi], 1
        .endif
    .else
        mov dword ptr [edi], 0
        mov inputArm[edx*4], 0       ; 已松开 -> 解除武装，恢复正常电平
    .endif
    add esi, 4
    add edi, 4
    inc act
    mov eax, act
    .if eax < KEY_PER
        jmp IS_Act
    .endif
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp IS_Slot
    .endif
    ; 会话36（B3）：联机局对手机械坦克完全由网络包驱动。本地热座若正配
    ; 第二套键位（slot1）也照常扫描，会把远端坦克当 P2 开——这里采样完
    ; 立即把 slot1 六路清零。其余槽位联机时本就闲置（numPlayers=2）。
    .if netMode != 0
        mov edi, offset inputTable
        add edi, KEY_PER*4             ; slot1 起点
        xor eax, eax
        mov ecx, KEY_PER
        rep stosd
    .endif
    ; 固定重开键（会话36：联机禁用——单机 R=整场重开会重洗地图袋/出生点，
    ; 联机时两端各自洗牌 = 同步炸裂；掉线处理由 net.asm 超时负责）
    .if netMode == 0
        invoke GetAsyncKeyState, VK_R
        and eax, 8000h
        .if eax != 0
            mov inputRestart, 1
        .else
            mov inputRestart, 0
        .endif
    .else
        mov inputRestart, 0
    .endif
    ret
InputSample endp

end
