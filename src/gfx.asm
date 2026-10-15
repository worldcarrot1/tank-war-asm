; ============================================================
; gfx.asm —— 渲染模块（GDI）
; 策略：CreateCompatibleDC 建后台缓冲，先把地图/坦克/子弹画进
; 内存位图，最后一轮 BitBlt 整幅上屏，避免闪烁。
;
; 阶段 1 用 FillRect 画纯色方块（坦克/子弹都是矩形），
; 阶段 3 可替换为 LoadImage 加载的位图精灵，接口不变。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include windows.inc
include user32.inc
include kernel32.inc
include gdi32.inc
includelib user32.lib
includelib kernel32.lib
includelib gdi32.lib

include ..\inc\game.inc

extern hWnd        :dword          ; main.asm 里的主窗口句柄
extern mapData     :byte           ; game.inc 里的地图数组

; ---- 需要读取的游戏状态（game.asm 定义）----
extern tanks       :TANK
extern bullets     :BULLET

.data
    hdcBack     dd ?                ; 后台内存 DC
    hbmBack     dd ?                ; 后台位图
    hbmOld      dd ?
    brushEmpty  dd ?                ; 各类格子的画刷
    brushBrick  dd ?
    brushSteel  dd ?
    brushSelf   dd ?                ; 自己的坦克（蓝）
    brushPeer   dd ?                ; 对方坦克（红）
    brushBullet dd ?

.code

; ------------------------------------------------------------
; GfxInit —— 创建后台缓冲与画刷
; ------------------------------------------------------------
GfxInit proc
    invoke GetDC, hWnd
    mov edx, eax                     ; 暂存窗口 DC
    invoke CreateCompatibleDC, edx
    mov hdcBack, eax
    invoke CreateCompatibleBitmap, edx, WND_W, WND_H
    mov hbmBack, eax
    invoke SelectObject, hdcBack, hbmBack
    mov hbmOld, eax
    invoke ReleaseDC, hWnd, edx

    invoke CreateSolidBrush, 00000000h
    mov brushEmpty, eax              ; 空地：黑
    invoke CreateSolidBrush, 00804020h
    mov brushBrick, eax              ; 砖墙：暗橙红（GDI 是 BGR 序）
    invoke CreateSolidBrush, 00A0A0A0h
    mov brushSteel, eax              ; 钢墙：灰
    invoke CreateSolidBrush, 00E07000h
    mov brushSelf, eax               ; 己方：橙蓝 0000E070? 见下
    invoke CreateSolidBrush, 0000C0F0h
    mov brushPeer, eax
    invoke CreateSolidBrush, 00FFFFFFh
    mov brushBullet, eax             ; 子弹：白
    ret
GfxInit endp

; ------------------------------------------------------------
; GfxRender —— 绘制一帧：地图 -> 坦克 -> 子弹 -> 上屏
; ------------------------------------------------------------
GfxRender proc
    local rc:RECT

    ; 1) 清屏为空地颜色
    invoke SelectObject, hdcBack, brushEmpty
    mov rc.left, 0
    mov rc.top, 0
    mov rc.right, WND_W
    mov rc.bottom, WND_H
    invoke FillRect, hdcBack, addr rc, brushEmpty

    ; 2) 逐格画地图（esi 遍历 mapData）
    xor esi, esi                     ; 格子索引
    xor edi, edi                     ; 行号
RowLoop:
    xor ebx, ebx                     ; 列号
ColLoop:
    mov al, mapData[esi]
    ; 计算该格像素矩形
    mov eax, ebx
    imul eax, CELL
    mov rc.left, eax
    add eax, CELL
    mov rc.right, eax
    mov eax, edi
    imul eax, CELL
    mov rc.top, eax
    add eax, CELL
    mov rc.bottom, eax
    ; 按格子类型选画刷
    mov al, mapData[esi]
    .if al == TILE_BRICK
        invoke FillRect, hdcBack, addr rc, brushBrick
    .elseif al == TILE_STEEL
        invoke FillRect, hdcBack, addr rc, brushSteel
    .endif
    inc esi
    inc ebx
    .if ebx < COLS
        jmp ColLoop
    .endif
    inc edi
    .if edi < ROWS
        jmp RowLoop
    .endif

    ; 3) 画两辆坦克（32x32 矩形，死亡跳过）
    mov ecx, 2
TankLoop:
    dec ecx
    mov eax, SIZEOF TANK
    imul eax, ecx
    lea esi, tanks
    add esi, eax
    mov eax, (TANK ptr [esi]).alive
    .if eax != 0
        mov eax, (TANK ptr [esi]).x
        mov rc.left, eax
        add eax, CELL
        mov rc.right, eax
        mov eax, (TANK ptr [esi]).y
        mov rc.top, eax
        add eax, CELL
        mov rc.bottom, eax
        .if ecx == PLAYER_SELF
            invoke FillRect, hdcBack, addr rc, brushSelf
        .else
            invoke FillRect, hdcBack, addr rc, brushPeer
        .endif
    .endif
    .if ecx > 0
        jmp TankLoop
    .endif

    ; 4) 画子弹（8x8 矩形）
    xor ecx, ecx
BulletLoop:
    mov eax, SIZEOF BULLET
    imul eax, ecx
    lea esi, bullets
    add esi, eax
    mov eax, (BULLET ptr [esi]).active
    .if eax != 0
        mov eax, (BULLET ptr [esi]).x
        add eax, CELL/2 - 4
        mov rc.left, eax
        add eax, 8
        mov rc.right, eax
        mov eax, (BULLET ptr [esi]).y
        add eax, CELL/2 - 4
        mov rc.top, eax
        add eax, 8
        mov rc.bottom, eax
        invoke FillRect, hdcBack, addr rc, brushBullet
    .endif
    inc ecx
    .if ecx < MAX_BULLETS
        jmp BulletLoop
    .endif

    ; 5) 整幅上屏
    invoke GetDC, hWnd
    mov edx, eax
    invoke BitBlt, edx, 0, 0, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
    invoke ReleaseDC, hWnd, edx
    ret
GfxRender endp

; ------------------------------------------------------------
; GfxShutdown —— 释放 GDI 资源
; ------------------------------------------------------------
GfxShutdown proc
    invoke SelectObject, hdcBack, hbmOld
    invoke DeleteObject, hbmBack
    invoke DeleteDC, hdcBack
    invoke DeleteObject, brushEmpty
    invoke DeleteObject, brushBrick
    invoke DeleteObject, brushSteel
    invoke DeleteObject, brushSelf
    invoke DeleteObject, brushPeer
    invoke DeleteObject, brushBullet
    ret
GfxShutdown endp

end
