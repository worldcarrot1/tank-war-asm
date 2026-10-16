; ============================================================
; gfx.asm —— 渲染模块（GDI，Tank Trouble 风格）
; 布局：顶部 32px 计分条（深色 + 白字比分），下方 640x480 地图。
; 风格：浅灰底、深灰墙体、棕砖（带砖缝纹理与弹洞）、蓝水（波纹）、
;       淡冰（高光）、圆角车体 + 炮塔 + 伸出炮管坦克、黑色小圆弹。
; 注意：Win32 ABI 中 eax/ecx/edx 跨 invoke 会被破坏，
; 循环计数一律用 ebx/esi/edi（被调用方保证保存）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

public hdcBack                    ; ui.asm 菜单界面复用后台 DC
extern hWnd        :dword          ; main.asm 里的主窗口句柄
extern numPlayers  :dword          ; ui.asm（当前玩家数）
extern mapData     :byte           ; game.asm 里的地图数组
extern tanks       :TANK           ; game.asm 里的坦克状态
extern bullets     :BULLET         ; game.asm 里的子弹池

.data
    hdcWin      dd ?                ; 窗口 DC（临时缓存）
    hdcBack     dd ?                ; 后台内存 DC
    hbmBack     dd ?                ; 后台位图
    hbmOld      dd ?
    penDark     dd ?                ; 描边笔（深色 2px）
    penOld      dd ?
    brushBg     dd ?                ; 空地：浅灰
    brushBrick  dd ?                ; 砖墙：棕
    brushMortar dd ?                ; 砖缝：深棕
    brushSteel  dd ?                ; 钢墙：深灰
    brushWater  dd ?                ; 水：蓝
    brushWave   dd ?                ; 水波纹：浅蓝
    brushIce    dd ?                ; 冰：淡青白
    brushStreak dd ?                ; 冰高光：白
    brushP1     dd ?                ; P1 车体：绿
    brushP2     dd ?                ; P2 车体：蓝
    brushP3     dd ?                ; P3 车体：红
    brushP4     dd ?                ; P4 车体：橙
    brushBullet dd ?                ; 子弹：近黑
    brushHud    dd ?                ; 计分条：深灰
    scoreBuf    db 48 dup (0)       ; 比分文本 "P1 nn P2 nn ..."

.code

; ------------------------------------------------------------
; GfxInit —— 创建后台缓冲、画刷与描边笔
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

    invoke CreatePen, PS_SOLID, 2, 00232323h
    mov penDark, eax
    invoke CreateSolidBrush, 00D2D2D2h
    mov brushBg, eax
    invoke CreateSolidBrush, 00285AAAh
    mov brushBrick, eax
    invoke CreateSolidBrush, 0014376Eh
    mov brushMortar, eax
    invoke CreateSolidBrush, 00404040h
    mov brushSteel, eax
    invoke CreateSolidBrush, 00DC783Ch
    mov brushWater, eax
    invoke CreateSolidBrush, 00F0B482h
    mov brushWave, eax
    invoke CreateSolidBrush, 00FAEEE1h
    mov brushIce, eax
    invoke CreateSolidBrush, 00FFFFFFh
    mov brushStreak, eax
    invoke CreateSolidBrush, 0055C85Fh
    mov brushP1, eax
    invoke CreateSolidBrush, 00E66E46h
    mov brushP2, eax
    invoke CreateSolidBrush, 002828A0h
    mov brushP3, eax
    invoke CreateSolidBrush, 000080F0h
    mov brushP4, eax
    invoke CreateSolidBrush, 00191919h
    mov brushBullet, eax
    invoke CreateSolidBrush, 00282828h
    mov brushHud, eax
    ret
GfxInit endp

; ------------------------------------------------------------
; FormatScore —— 生成比分文本 "P1 SS : SS P2"，返回 eax = 长度
; ------------------------------------------------------------
FormatScore proc uses ebx edi
    lea edi, scoreBuf
    xor ebx, ebx
FS_Slot:
    .if ebx >= numPlayers
        jmp FS_Done
    .endif
    ; "Pn nn "
    mov eax, ebx
    add eax, '1'
    mov ecx, edi
    mov byte ptr [ecx], 'P'
    mov byte ptr [ecx+1], al
    mov byte ptr [ecx+2], ' '
    add edi, 3
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov eax, (TANK ptr [eax]).score
    .if eax > 99
        mov eax, 99
    .endif
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    add dl, '0'
    mov [edi], al
    mov [edi+1], dl
    mov byte ptr [edi+2], ' '
    add edi, 3
    inc ebx
    jmp FS_Slot
FS_Done:
    mov eax, edi
    sub eax, offset scoreBuf         ; 长度
    ret
FormatScore endp

; ------------------------------------------------------------
; DrawTank —— 圆角车体 + 中心炮塔 + 伸出炮管（笔/刷已就位）
; 入参：hdc, px, py(已含 HUD 偏移), dirV
; ------------------------------------------------------------
DrawTank proc hdc: dword, px: dword, py: dword, dirV: dword
    local rc2:RECT
    ; 炮管（先画，压在车体下层，伸出车体 2px）
    mov eax, px
    mov edx, py
    .if dirV == DIR_UP
        add eax, 13
        mov rc2.left, eax
        add eax, 6
        mov rc2.right, eax
        mov eax, py
        sub eax, 2
        mov rc2.top, eax
        add eax, 22
        mov rc2.bottom, eax
    .elseif dirV == DIR_DOWN
        add eax, 13
        mov rc2.left, eax
        add eax, 6
        mov rc2.right, eax
        add edx, 12
        mov rc2.top, edx
        mov eax, py
        add eax, 34
        mov rc2.bottom, eax
    .elseif dirV == DIR_LEFT
        sub eax, 2
        mov rc2.left, eax
        mov eax, px
        add eax, 20
        mov rc2.right, eax
        add edx, 13
        mov rc2.top, edx
        add edx, 6
        mov rc2.bottom, edx
    .else                                   ; DIR_RIGHT
        add eax, 12
        mov rc2.left, eax
        mov eax, px
        add eax, 34
        mov rc2.right, eax
        add edx, 13
        mov rc2.top, edx
        add edx, 6
        mov rc2.bottom, edx
    .endif
    invoke Rectangle, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    ; 车体（圆角方块）
    mov eax, px
    add eax, 2
    mov rc2.left, eax
    add eax, 28
    mov rc2.right, eax
    mov eax, py
    add eax, 2
    mov rc2.top, eax
    add eax, 28
    mov rc2.bottom, eax
    invoke RoundRect, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom, 10, 10
    ; 炮塔（中心圆）
    mov eax, px
    add eax, 9
    mov rc2.left, eax
    add eax, 14
    mov rc2.right, eax
    mov eax, py
    add eax, 9
    mov rc2.top, eax
    add eax, 14
    mov rc2.bottom, eax
    invoke Ellipse, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    ret
DrawTank endp

; ------------------------------------------------------------
; GfxRender —— 绘制一帧：计分条 -> 地图 -> 坦克 -> 子弹 -> 上屏
; ------------------------------------------------------------
GfxRender proc
    local rc:RECT
    local r2:RECT
    local txtLen:dword

    ; 0) 背景与计分条
    mov rc.left, 0
    mov rc.top, 0
    mov rc.right, WND_W
    mov rc.bottom, WND_H
    invoke FillRect, hdcBack, addr rc, brushBg
    mov rc.bottom, HUD_H
    invoke FillRect, hdcBack, addr rc, brushHud
    invoke SetBkMode, hdcBack, TRANSPARENT
    invoke SetTextColor, hdcBack, 00FFFFFFh
    invoke FormatScore
    mov txtLen, eax                   ; 保存长度（勿被居中计算覆盖）
    mov eax, txtLen
    shl eax, 3                        ; len*8（近似字符宽）
    mov ecx, MAP_W
    sub ecx, eax
    sar ecx, 1
    invoke TextOutA, hdcBack, ecx, 9, offset scoreBuf, txtLen

    ; 1) 描边笔就位；逐格画地图（y 偏移 HUD_H）
    invoke SelectObject, hdcBack, penDark
    mov penOld, eax
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
    add eax, HUD_H
    mov rc.top, eax
    add eax, CELL
    mov rc.bottom, eax

    movzx eax, mapData[esi]
    .if eax == TILE_STEEL
        invoke FillRect, hdcBack, addr rc, brushSteel
    .elseif eax == TILE_WATER
        invoke FillRect, hdcBack, addr rc, brushWater
        ; 两道浅色波纹
        mov eax, rc.left
        add eax, 4
        mov r2.left, eax
        mov eax, rc.right
        sub eax, 4
        mov r2.right, eax
        mov eax, rc.top
        add eax, 8
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushWave
        mov eax, rc.top
        add eax, 20
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushWave
    .elseif eax == TILE_ICE
        invoke FillRect, hdcBack, addr rc, brushIce
        ; 两道白色高光（错位）
        mov eax, rc.left
        add eax, 4
        mov r2.left, eax
        mov eax, rc.right
        sub eax, 10
        mov r2.right, eax
        mov eax, rc.top
        add eax, 6
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushStreak
        mov eax, rc.left
        add eax, 10
        mov r2.left, eax
        mov eax, rc.right
        sub eax, 4
        mov r2.right, eax
        mov eax, rc.top
        add eax, 18
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushStreak
    .elseif eax == TILE_BRICK
        ; 砖基座 + 深色砖缝（两横 + 上半中缝 + 下半两条错缝）
        invoke FillRect, hdcBack, addr rc, brushBrick
        mov eax, rc.left
        mov r2.left, eax
        mov eax, rc.right
        mov r2.right, eax
        mov eax, rc.top
        add eax, 10
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushMortar
        mov eax, rc.top
        add eax, 21
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushMortar
        mov eax, rc.left
        add eax, 15
        mov r2.left, eax
        add eax, 2
        mov r2.right, eax
        mov eax, rc.top
        mov r2.top, eax
        add eax, 10
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushMortar
        mov eax, rc.left
        add eax, 7
        mov r2.left, eax
        add eax, 2
        mov r2.right, eax
        mov eax, rc.top
        add eax, 23
        mov r2.top, eax
        mov eax, rc.bottom
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushMortar
        mov eax, rc.left
        add eax, 23
        mov r2.left, eax
        add eax, 2
        mov r2.right, eax
        invoke FillRect, hdcBack, addr r2, brushMortar
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

    ; 2) 画坦克（ebx=槽位号，y 偏移 HUD_H）
    xor ebx, ebx
    mov esi, offset tanks
TankLoop:
    mov eax, (TANK ptr [esi]).alive
    .if eax != 0
        push ebx
        mov eax, ebx
        .if eax == 0
            invoke SelectObject, hdcBack, brushP1
        .elseif eax == 1
            invoke SelectObject, hdcBack, brushP2
        .elseif eax == 2
            invoke SelectObject, hdcBack, brushP3
        .else
            invoke SelectObject, hdcBack, brushP4
        .endif
        pop ebx
        mov eax, (TANK ptr [esi]).x
        mov ecx, eax                   ; px
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H
        mov edx, eax                   ; py（含计分条偏移）
        mov eax, (TANK ptr [esi]).dir
        invoke DrawTank, hdcBack, ecx, edx, eax
    .endif
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp TankLoop
    .endif

    ; 3) 画子弹（黑色小圆，y 偏移 HUD_H）
    invoke SelectObject, hdcBack, brushBullet
    xor ebx, ebx
    mov esi, offset bullets
BulletLoop:
    mov eax, (BULLET ptr [esi]).active
    .if eax != 0
        mov eax, (BULLET ptr [esi]).x
        add eax, 1
        mov rc.left, eax
        add eax, 6
        mov rc.right, eax
        mov eax, (BULLET ptr [esi]).y
        add eax, HUD_H + 1
        mov rc.top, eax
        add eax, 6
        mov rc.bottom, eax
        invoke Ellipse, hdcBack, rc.left, rc.top, rc.right, rc.bottom
    .endif
    add esi, SIZEOF BULLET
    inc ebx
    .if ebx < MAX_BULLETS
        jmp BulletLoop
    .endif

    ; 4) 恢复画笔，整幅上屏
    invoke SelectObject, hdcBack, penOld
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
    invoke DeleteObject, penDark
    invoke DeleteObject, brushBg
    invoke DeleteObject, brushBrick
    invoke DeleteObject, brushMortar
    invoke DeleteObject, brushSteel
    invoke DeleteObject, brushWater
    invoke DeleteObject, brushWave
    invoke DeleteObject, brushIce
    invoke DeleteObject, brushStreak
    invoke DeleteObject, brushP1
    invoke DeleteObject, brushP2
    invoke DeleteObject, brushP3
    invoke DeleteObject, brushP4
    invoke DeleteObject, brushBullet
    invoke DeleteObject, brushHud
    ret
GfxShutdown endp

end
