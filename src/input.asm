; ============================================================
; input.asm —— 键盘输入采样
; 用 GetAsyncKeyState 每个逻辑 tick 采样一次（而不是依赖
; WM_KEYDOWN 消息），保证帧率波动时输入节奏一致。
;
; 键位：WASD 移动 / 空格开火 / R 重新开始
; 采样结果写入 game.asm 的输入快照变量，供 GameUpdate 消费。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc

extern inputUp      :dword
extern inputDown    :dword
extern inputLeft    :dword
extern inputRight   :dword
extern inputFire    :dword
extern inputRestart :dword

.code

; ------------------------------------------------------------
; KeyDown —— 检测某键当前是否按下
; 入参：vk = VK 码，返回 eax = 1(按下) / 0(抬起)
; ------------------------------------------------------------
KeyDown proc vk: DWORD
    invoke GetAsyncKeyState, vk
    and eax, 8000h                   ; 取最高位：当前是否按下
    .if eax != 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    ret
KeyDown endp

; ------------------------------------------------------------
; InputSample —— 每 tick 调用一次，刷新输入快照
; ------------------------------------------------------------
InputSample proc
    invoke KeyDown, VK_W
    mov inputUp, eax
    invoke KeyDown, VK_S
    mov inputDown, eax
    invoke KeyDown, VK_A
    mov inputLeft, eax
    invoke KeyDown, VK_D
    mov inputRight, eax
    invoke KeyDown, VK_SPACE
    mov inputFire, eax
    invoke KeyDown, VK_R
    mov inputRestart, eax
    ret
InputSample endp

end
