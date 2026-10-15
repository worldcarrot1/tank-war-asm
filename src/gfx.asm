; ============================================================
; gfx.asm —— 渲染模块（GDI）
; 策略：CreateCompatibleDC 建后台缓冲，先把地图/坦克/子弹画进
; 内存位图，最后一轮 BitBlt 整幅上屏，避免闪烁。
;
; 阶段 1 用 FillRect 画纯色方块（坦克/子弹都是矩形），
; 后续可替换为 LoadImage 加载的位图精灵，接口不变。
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
    brushSelf   dd ?                ; 己方坦克：橙
    brushPeer   dd ?                ; 对方坦克：蓝
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

    ; 3) 画两辆坦克（32x32 矩形，死亡跳过）；ebx=玩家编号
    mov ebx, 2
TankLoop:
    dec ebx
    mov eax, SIZEOF TANK
    imul eax, ebx
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
        .if ebx == PLAYER_SELF
            invoke FillRect, hdcBack, addr rc, brushSelf
        .else
            invoke FillRect, hdcBack, addr rc, brushPeer
        .endif
    .endif
    .if ebx > 0
        jmp TankLoop
    .endif

    ; 4) 画子弹（8x8 矩形，画在格子中心）；ebx=槽位号
    xor ebx, ebx
BulletLoop:
    mov eax, SIZEOF BULLET
    imul eax, ebx
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
    invoke DeleteObject, brushSelf
    invoke DeleteObject, brushPeer
    invoke DeleteObject, brushBullet
    ret
GfxShutdown endp

end
