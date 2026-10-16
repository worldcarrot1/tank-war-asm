; ============================================================
; input.asm —— 键盘输入采样（键位表驱动）
; 每 tick 用 GetAsyncKeyState 扫描 keyTable（4 人 x 5 键，
; 键位可在设置界面重绑），结果写入 inputTable。
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

.code

; ------------------------------------------------------------
; InputSample —— 每 tick 调用一次，扫描全部键位
; ------------------------------------------------------------
InputSample proc uses ebx esi edi
    local act: dword                 ; 动作计数（invoke 会破坏易失寄存器，不能寄存器计数）
    xor ebx, ebx                     ; slot
    mov esi, offset keyTable
    mov edi, offset inputTable
IS_Slot:
    mov act, 0                       ; action 0..4
IS_Act:
    mov eax, [esi]
    invoke GetAsyncKeyState, eax
    and eax, 8000h
    .if eax != 0
        mov dword ptr [edi], 1
    .else
        mov dword ptr [edi], 0
    .endif
    add esi, 4
    add edi, 4
    inc act
    mov eax, act
    .if eax < 5
        jmp IS_Act
    .endif
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp IS_Slot
    .endif
    ; 固定重开键
    invoke GetAsyncKeyState, VK_R
    and eax, 8000h
    .if eax != 0
        mov inputRestart, 1
    .else
        mov inputRestart, 0
    .endif
    ret
InputSample endp

end
