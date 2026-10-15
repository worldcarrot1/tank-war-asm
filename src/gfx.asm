; ============================================================
; gfx.asm —— 渲染模块（GDI）
; 策略：CreateCompatibleDC 建后台缓冲，先把地图/坦克/子弹画进
; 内存位图，最后一轮 BitBlt 整幅上屏，避免闪烁。
; M1 新增：水/冰地形、砖墙 2x2 子块绘制（按 brickMask）。
; 注意：Win32 ABI 中 eax/ecx/edx 跨 invoke 会被破坏，
; 循环计数一律用 ebx/esi/edi（被调用方保证保存）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

extern hWnd        :dword          ; main.asm 里的主窗口句柄
extern mapData     :byte           ; game.asm 里的地图数组
extern brickMask   :byte           ; game.asm 里的砖格子块占用位
extern tanks       :TANK           ; game.asm 里的坦克状态
extern bullets     :BULLET         ; game.asm 里的子弹池

.data
    hdcWin      dd ?                ; 窗口 DC（临时缓存）
    hdcBack     dd ?                ; 后台内存 DC
    hbmBack     dd ?                ; 后台位图
    hbmOld      dd ?
    brushEmpty  dd ?                ; 空地：黑
    brushBrick  dd ?                ; 砖墙：砖红
    brushSteel  dd ?                ; 钢墙：灰
    brushWater  dd ?                ; 水域：深蓝
    brushIce    dd ?                ; 冰面：淡青白
    brushSelf   dd ?                ; P1 坦克：橙
    brushPeer   dd ?                ; P2 坦克：蓝
    brushBullet dd ?                ; 子弹：白

.code

; ------------------------------------------------------------
; GfxInit —— 创建后台缓冲与画刷
; 颜色为 COLORREF（0x00BBGGRR，GDI 的 BGR 序）
; ------------------------------------------------------------
GfxInit proc
    invoke GetDC, hWnd
    mov hdcWin, eax
    invoke CreateCompatibleDC, hdcWin
    mov hdcBack, eax
    invoke CreateCompatibleBitmap, hdcWin, WND_W, WND_H
    mov hbmBack, eax
    invoke SelectObject, hdcBack, hbmBack
    mov hbmOld, eax
    invoke ReleaseDC, hWnd, hdcWin

    invoke CreateSolidBrush, 00000000h
    mov brushEmpty, eax
    invoke CreateSolidBrush, 00004080h
    mov brushBrick, eax
    invoke CreateSolidBrush, 00A0A0A0h
    mov brushSteel, eax
    invoke CreateSolidBrush, 00C04010h
    mov brushWater, eax
    invoke CreateSolidBrush, 00F0E8D8h
    mov brushIce, eax
    invoke CreateSolidBrush, 000080F0h
    mov brushSelf, eax
    invoke CreateSolidBrush, 00F08000h
    mov brushPeer, eax
    invoke CreateSolidBrush, 00FFFFFFh
    mov brushBullet, eax
    ret
GfxInit endp

; ------------------------------------------------------------
; GfxRender —— 绘制一帧：地图 -> 坦克 -> 子弹 -> 上屏
; ------------------------------------------------------------
GfxRender proc
    local rc:RECT
    local r2:RECT
    local msk:dword

    ; 1) 清屏为空地颜色
    mov rc.left, 0
    mov rc.top, 0
    mov rc.right, WND_W
    mov rc.bottom, WND_H
    invoke FillRect, hdcBack, addr rc, brushEmpty

    ; 2) 逐格画地图：esi=格子索引，edi=行，ebx=列
    xor esi, esi
    xor edi, edi
RowLoop:
    xor ebx, ebx
ColLoop:
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

    movzx eax, mapData[esi]
    .if eax == TILE_STEEL
        invoke FillRect, hdcBack, addr rc, brushSteel
    .elseif eax == TILE_WATER
        invoke FillRect, hdcBack, addr rc, brushWater
    .elseif eax == TILE_ICE
        invoke FillRect, hdcBack, addr rc, brushIce
    .elseif eax == TILE_BRICK
        ; 砖墙按子块位绘制（bit0 左上 1 右上 2 左下 3 右下）
        movzx eax, brickMask[esi]
        mov msk, eax
        .if msk & 1
            ; 左上子块
            mov eax, rc.left
            mov r2.left, eax
            mov eax, rc.top
            mov r2.top, eax
            add eax, SUBPX
            mov r2.right, eax
            mov eax, rc.top
            add eax, SUBPX
            mov r2.bottom, eax
            invoke FillRect, hdcBack, addr r2, brushBrick
        .endif
        .if msk & 2
            ; 右上子块
            mov eax, rc.left
            add eax, SUBPX
            mov r2.left, eax
            mov eax, rc.right
            mov r2.right, eax
            mov eax, rc.top
            mov r2.top, eax
            add eax, SUBPX
            mov r2.bottom, eax
            invoke FillRect, hdcBack, addr r2, brushBrick
        .endif
        .if msk & 4
            ; 左下子块
            mov eax, rc.left
            mov r2.left, eax
            add eax, SUBPX
            mov r2.right, eax
            mov eax, rc.top
            add eax, SUBPX
            mov r2.top, eax
            mov eax, rc.bottom
            mov r2.bottom, eax
            invoke FillRect, hdcBack, addr r2, brushBrick
        .endif
        .if msk & 8
            ; 右下子块
            mov eax, rc.left
            add eax, SUBPX
            mov r2.left, eax
            mov eax, rc.right
            mov r2.right, eax
            mov eax, rc.top
            add eax, SUBPX
            mov r2.top, eax
            mov eax, rc.bottom
            mov r2.bottom, eax
            invoke FillRect, hdcBack, addr r2, brushBrick
        .endif
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

    ; 3) 画坦克（32x32 矩形，死亡跳过）；ebx=槽位号
    xor ebx, ebx
    mov esi, offset tanks
TankLoop:
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
        .if ebx == 0
            invoke FillRect, hdcBack, addr rc, brushSelf
        .else
            invoke FillRect, hdcBack, addr rc, brushPeer
        .endif
    .endif
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp TankLoop
    .endif

    ; 4) 画子弹（8x8 白块，弹体左上角即 x,y）
    xor ebx, ebx
    mov esi, offset bullets
BulletLoop:
    mov eax, (BULLET ptr [esi]).active
    .if eax != 0
        mov eax, (BULLET ptr [esi]).x
        mov rc.left, eax
        add eax, BULLET_SIZE_PX
        mov rc.right, eax
        mov eax, (BULLET ptr [esi]).y
        mov rc.top, eax
        add eax, BULLET_SIZE_PX
        mov rc.bottom, eax
        invoke FillRect, hdcBack, addr rc, brushBullet
    .endif
    add esi, SIZEOF BULLET
    inc ebx
    .if ebx < MAX_BULLETS
        jmp BulletLoop
    .endif

    ; 5) 整幅上屏
    invoke GetDC, hWnd
    mov hdcWin, eax
    invoke BitBlt, hdcWin, 0, 0, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
    invoke ReleaseDC, hWnd, hdcWin
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
    invoke DeleteObject, brushWater
    invoke DeleteObject, brushIce
    invoke DeleteObject, brushSelf
    invoke DeleteObject, brushPeer
    invoke DeleteObject, brushBullet
    ret
GfxShutdown endp

end
