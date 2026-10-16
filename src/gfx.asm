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
extern pickupType  :dword          ; 技能拾取物
extern pickupX     :dword
extern pickupY     :dword
extern laserN      :dword          ; 激光路径（发射后显示）
extern laserX      :dword
extern laserY      :dword
extern laserT      :dword
extern prevN       :dword          ; 激光预览路径（瞄准中虚线）
extern prevX       :dword
extern prevY       :dword
extern prevTank    :dword
extern matchOver   :dword          ; 比赛结束标志（game.asm）
extern langFlag    :dword          ; 0=英 1=中（ui.asm）
extern menuFont    :dword          ; 菜单大字体（ui.asm）
extern fontSmall   :dword          ; 小字体（ui.asm）

WallRects PROTO :DWORD,:DWORD,:DWORD   ; game.asm：墙格挡板矩形枚举
UiTextZ   PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD   ; ui.asm：ASCII 文本

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
    brushDirt   dd ?                ; 泥土：棕褐
    brushDirtDark dd ?              ; 泥土纹理：深棕褐
    brushP1     dd ?                ; P1 车体：绿
    brushP2     dd ?                ; P2 车体：蓝
    brushP3     dd ?                ; P3 车体：红
    brushP4     dd ?                ; P4 车体：橙
    brushBullet dd ?                ; 子弹：近黑
    brushHud    dd ?                ; 计分条：深灰
    skillBrush  dd 10 dup (0)       ; [1..9] 技能配色刷（BGR）
    penLaser    dd ?                ; 发射激光：红实线 2px
    penPreview  dd ?                ; 激光预览：灰虚线 1px
    skillNum    db "0", 0           ; 拾取物上的技能序号
    scoreBuf    db 48 dup (0)       ; 比分文本 "P1 nn P2 nn ..."
    szWinsEn    db "WINS THE MATCH!", 0
    szBackEn    db "PRESS ENTER FOR MENU", 0
    CN_WIN      dw 83B7h,5F97h,6BD4h,8D5Bh,80DCh,5229h,0FF01h, 0 ; 获得比赛胜利！
    CN_BACKMENU dw 6309h,56DEh,8F66h,8FD4h,56DEh,4E3Bh,83DCh,5355h, 0 ; 按回车返回主菜单

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
    invoke CreateSolidBrush, 008CB4D2h       ; 泥土：棕褐 RGB(210,180,140)
    mov brushDirt, eax
    invoke CreateSolidBrush, 006E96B4h       ; 泥土纹理：深棕褐 RGB(180,150,110)
    mov brushDirtDark, eax
    invoke CreateSolidBrush, 0028781Ah       ; P1 深绿 RGB(26,120,40)
    mov brushP1, eax
    invoke CreateSolidBrush, 00A0461Eh       ; P2 深蓝 RGB(30,70,160)
    mov brushP2, eax
    invoke CreateSolidBrush, 003030C0h       ; P3 深红 RGB(192,48,48)
    mov brushP3, eax
    invoke CreateSolidBrush, 00005AB4h       ; P4 深橙 RGB(180,90,0)
    mov brushP4, eax
    invoke CreateSolidBrush, 00191919h
    mov brushBullet, eax
    invoke CreateSolidBrush, 00282828h
    mov brushHud, eax
    ; ---- 技能配色（下标 = 技能 id）----
    ; 1冰盾淡蓝 2激光红 3反射品红 4穿墙紫 5地雷深灰 6加速橙 7换位青 8驭水蓝
    invoke CreateSolidBrush, 00FFF0E0h
    mov skillBrush[4], eax
    invoke CreateSolidBrush, 003030FFh
    mov skillBrush[8], eax
    invoke CreateSolidBrush, 00FF00C8h
    mov skillBrush[12], eax
    invoke CreateSolidBrush, 00C020A0h
    mov skillBrush[16], eax
    invoke CreateSolidBrush, 003C3C3Ch
    mov skillBrush[20], eax
    invoke CreateSolidBrush, 00008CFFh
    mov skillBrush[24], eax
    invoke CreateSolidBrush, 00C8C800h
    mov skillBrush[28], eax
    invoke CreateSolidBrush, 00E05010h
    mov skillBrush[32], eax
    invoke CreateSolidBrush, 00906080h       ; 9 定格：深紫
    mov skillBrush[36], eax
    invoke CreatePen, PS_SOLID, 2, 000000E0h
    mov penLaser, eax
    invoke CreatePen, PS_DASH, 1, 00606060h
    mov penPreview, eax
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
; 坦克边长 TANK_SIZE=21（原 32 的 2/3）；炮管伸出车体 8px = 出弹点
; ------------------------------------------------------------
DrawTank proc hdc: dword, px: dword, py: dword, dirV: dword
    local rc2:RECT
    local oldPen:dword
    ; 25px 参照图样式：粗黑描边 + 圆角车身 + 大圆炮塔 + 粗炮管
    invoke SelectObject, hdc, penDark
    mov oldPen, eax
    ; 炮管（先画，压在车体下层；宽 6，伸出体外 8px = 出弹位）
    mov eax, px
    mov edx, py
    .if dirV == DIR_UP
        add eax, 9
        mov rc2.left, eax
        add eax, 6
        mov rc2.right, eax
        mov eax, py
        sub eax, 8
        mov rc2.top, eax
        add eax, 22
        mov rc2.bottom, eax
    .elseif dirV == DIR_DOWN
        add eax, 9
        mov rc2.left, eax
        add eax, 6
        mov rc2.right, eax
        add edx, 11
        mov rc2.top, edx
        mov eax, py
        add eax, 33
        mov rc2.bottom, eax
    .elseif dirV == DIR_LEFT
        sub eax, 8
        mov rc2.left, eax
        mov eax, px
        add eax, 16
        mov rc2.right, eax
        add edx, 9
        mov rc2.top, edx
        add edx, 6
        mov rc2.bottom, edx
    .else                                   ; DIR_RIGHT
        add eax, 9
        mov rc2.left, eax
        mov eax, px
        add eax, 33
        mov rc2.right, eax
        add edx, 9
        mov rc2.top, edx
        add edx, 6
        mov rc2.bottom, edx
    .endif
    invoke Rectangle, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    ; 车体（圆角方块 25x25）
    mov eax, px
    mov rc2.left, eax
    add eax, 25
    mov rc2.right, eax
    mov eax, py
    mov rc2.top, eax
    add eax, 25
    mov rc2.bottom, eax
    invoke RoundRect, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom, 9, 9
    ; 炮塔（大圆 直径 17 居中）
    mov eax, px
    add eax, 4
    mov rc2.left, eax
    add eax, 17
    mov rc2.right, eax
    mov eax, py
    add eax, 4
    mov rc2.top, eax
    add eax, 17
    mov rc2.bottom, eax
    invoke Ellipse, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    ; 舱盖（中心小圆 直径 7，近黑）
    invoke SelectObject, hdc, brushBullet
    mov eax, px
    add eax, 9
    mov rc2.left, eax
    add eax, 7
    mov rc2.right, eax
    mov eax, py
    add eax, 9
    mov rc2.top, eax
    add eax, 7
    mov rc2.bottom, eax
    invoke Ellipse, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    invoke SelectObject, hdc, oldPen
    ret
DrawTank endp

; ------------------------------------------------------------
; DrawTankBadges —— 坦克技能徽标
; 持有技能：右上角 8x8 色块（黑边）；冰盾：外圈冰色框；
; 角标彩点：加速左下橙 / 穿墙左上紫 / 驭水右下蓝 / 换位待发右下青
; ------------------------------------------------------------
DrawTankBadges proc uses ebx esi edi tk: dword
    local r2:RECT
    mov esi, tk
    ; 持有技能（右上角）
    mov eax, (TANK ptr [esi]).skill
    .if eax != SKILL_NONE
        mov ebx, eax
        mov eax, (TANK ptr [esi]).x
        add eax, TANK_SIZE-8
        mov r2.left, eax
        add eax, 8
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H
        mov r2.top, eax
        add eax, 8
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, skillBrush[ebx*4]
        invoke FrameRect, hdcBack, addr r2, brushMortar
    .endif
    ; 冰盾激活：坦克外圈
    mov eax, (TANK ptr [esi]).effOn
    .if eax & EFF_SHIELD
        mov eax, (TANK ptr [esi]).x
        sub eax, 4
        mov r2.left, eax
        add eax, TANK_SIZE+8
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H-4
        mov r2.top, eax
        add eax, TANK_SIZE+8
        mov r2.bottom, eax
        invoke FrameRect, hdcBack, addr r2, brushIce
    .endif
    ; 燃油加速：左下橙点
    mov eax, (TANK ptr [esi]).effOn
    .if eax & EFF_NITRO
        mov eax, (TANK ptr [esi]).x
        mov r2.left, eax
        add eax, 5
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H + TANK_SIZE-5
        mov r2.top, eax
        add eax, 5
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, skillBrush[6*4]
    .endif
    ; 穿墙：左上紫点
    mov eax, (TANK ptr [esi]).effOn
    .if eax & EFF_GHOST
        mov eax, (TANK ptr [esi]).x
        mov r2.left, eax
        add eax, 5
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H
        mov r2.top, eax
        add eax, 5
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, skillBrush[4*4]
    .endif
    ; 驭水：右下蓝点
    mov eax, (TANK ptr [esi]).effOn
    .if eax & EFF_WATER
        mov eax, (TANK ptr [esi]).x
        add eax, TANK_SIZE-5
        mov r2.left, eax
        add eax, 5
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H + TANK_SIZE-5
        mov r2.top, eax
        add eax, 5
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, skillBrush[8*4]
    .endif
    ; 换位待发：右下青点（与驭水同角但互斥出现概率低，颜色可辨）
    mov eax, (TANK ptr [esi]).swapBul
    .if eax != -1                   ; 有绑定（勿写 >= 0：无符号恒真）
        mov eax, (TANK ptr [esi]).x
        add eax, TANK_SIZE-5
        mov r2.left, eax
        add eax, 5
        mov r2.right, eax
        mov eax, (TANK ptr [esi]).y
        add eax, HUD_H + TANK_SIZE-5
        mov r2.top, eax
        add eax, 5
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, skillBrush[7*4]
    .endif
    ret
DrawTankBadges endp

; ------------------------------------------------------------
; DrawPhantom -- 定格术虚影：空心坦克轮廓（车体+炮塔描边）
; ------------------------------------------------------------
DrawPhantom proc hdc: dword, px: dword, py: dword
    local rc2:RECT
    local oldPen:dword
    invoke SelectObject, hdc, penDark
    mov oldPen, eax
    mov eax, px
    mov rc2.left, eax
    add eax, 25
    mov rc2.right, eax
    mov eax, py
    mov rc2.top, eax
    add eax, 25
    mov rc2.bottom, eax
    invoke RoundRect, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom, 9, 9
    mov eax, px
    add eax, 4
    mov rc2.left, eax
    add eax, 17
    mov rc2.right, eax
    mov eax, py
    add eax, 4
    mov rc2.top, eax
    add eax, 17
    mov rc2.bottom, eax
    invoke Ellipse, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    invoke SelectObject, hdc, oldPen
    ret
DrawPhantom endp

; ------------------------------------------------------------
; GfxRender —— 绘制一帧：计分条 -> 地图 -> 坦克 -> 子弹 -> 上屏
; ------------------------------------------------------------
GfxRender proc
    local rc:RECT
    local r2:RECT
    local txtLen:dword
    local rbuf[5]:RECT               ; 墙格挡板矩形（与碰撞共用几何）
    local pR:dword
    local cntR:dword
    local iR:dword
    local tType:dword
    local curBrush:dword

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

    ; 1a) 地面层（先画，位于墙/坦克下面）：水/冰/泥 整格铺满
    xor esi, esi
    xor edi, edi
GroundRow:
    xor ebx, ebx
GroundCol:
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
    .if eax == TILE_WATER
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
    .elseif eax == TILE_DIRT
        ; 泥土：棕褐整格 + 两道深棕褐土纹
        invoke FillRect, hdcBack, addr rc, brushDirt
        mov eax, rc.left
        add eax, 4
        mov r2.left, eax
        mov eax, rc.right
        sub eax, 10
        mov r2.right, eax
        mov eax, rc.top
        add eax, 7
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushDirtDark
        mov eax, rc.left
        add eax, 10
        mov r2.left, eax
        mov eax, rc.right
        sub eax, 4
        mov r2.right, eax
        mov eax, rc.top
        add eax, 19
        mov r2.top, eax
        add eax, 2
        mov r2.bottom, eax
        invoke FillRect, hdcBack, addr r2, brushDirtDark
    .endif
    inc esi
    inc ebx
    .if ebx < COLS
        jmp GroundCol
    .endif
    inc edi
    .if edi < ROWS
        jmp GroundRow
    .endif

    ; 1b) 墙层（画在地面之上、坦克之下）：细挡板钢/砖
    invoke SelectObject, hdcBack, penDark
    mov penOld, eax
    xor esi, esi
    xor edi, edi
WallRow:
    xor ebx, ebx
WallCol:
    movzx eax, mapData[esi]
    .if eax == TILE_STEEL || eax == TILE_BRICK
        ; 细挡板墙：中心点 + 朝邻墙的连接条（几何来自 game.asm
        ; WallRects，与碰撞完全一致，所见即所撞）
        mov tType, eax
        invoke WallRects, ebx, edi, addr rbuf
        mov cntR, eax
        .if tType == TILE_STEEL
            mov eax, brushSteel
        .else
            mov eax, brushBrick
        .endif
        mov curBrush, eax
        lea eax, rbuf
        mov pR, eax
        mov iR, 0
BR_Loop:
        mov eax, cntR
        .if iR >= eax
            jmp BR_Done
        .endif
        invoke FillRect, hdcBack, pR, curBrush
        ; 砖墙加砖缝：横条画竖缝、竖条/点画横缝（2px 居中）
        .if tType == TILE_BRICK
            mov edx, pR
            mov eax, (RECT ptr [edx]).right
            sub eax, (RECT ptr [edx]).left
            mov ecx, (RECT ptr [edx]).bottom
            sub ecx, (RECT ptr [edx]).top
            .if eax > ecx
                ; 横向条 -> 中缝竖 tick
                mov eax, (RECT ptr [edx]).left
                add eax, (RECT ptr [edx]).right
                sar eax, 1
                dec eax
                mov r2.left, eax
                add eax, 2
                mov r2.right, eax
                mov eax, (RECT ptr [edx]).top
                mov r2.top, eax
                mov eax, (RECT ptr [edx]).bottom
                mov r2.bottom, eax
            .else
                ; 竖条/点 -> 中缝横 tick
                mov eax, (RECT ptr [edx]).left
                mov r2.left, eax
                mov eax, (RECT ptr [edx]).right
                mov r2.right, eax
                mov eax, (RECT ptr [edx]).top
                add eax, (RECT ptr [edx]).bottom
                sar eax, 1
                dec eax
                mov r2.top, eax
                add eax, 2
                mov r2.bottom, eax
            .endif
            invoke FillRect, hdcBack, addr r2, brushMortar
        .endif
        add pR, SIZEOF RECT
        inc iR
        jmp BR_Loop
BR_Done:
    .endif
    inc esi
    inc ebx
    .if ebx < COLS
        jmp WallCol
    .endif
    inc edi
    .if edi < ROWS
        jmp WallRow
    .endif

    ; 1c) 技能拾取物：彩色块 + 白色序号（1..8）
    mov eax, pickupType
    .if eax != 0
        mov eax, pickupX
        mov rc.left, eax
        add eax, PICKUP_SIZE
        mov rc.right, eax
        mov eax, pickupY
        add eax, HUD_H
        mov rc.top, eax
        add eax, PICKUP_SIZE
        mov rc.bottom, eax
        mov eax, pickupType
        invoke FillRect, hdcBack, addr rc, skillBrush[eax*4]
        invoke FrameRect, hdcBack, addr rc, brushMortar
        mov al, '0'
        add al, byte ptr pickupType
        mov skillNum, al
        mov eax, pickupX
        add eax, 6
        mov ecx, pickupY
        add ecx, HUD_H+1
        invoke TextOutA, hdcBack, eax, ecx, offset skillNum, 1
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
        invoke DrawTankBadges, esi      ; 技能徽标
        ; 定格虚影：画在虚影位置（空心轮廓）
        mov eax, (TANK ptr [esi]).effOn
        test eax, EFF_PHANTOM
        jz TP_NoPh
        push ebx
        push esi
        mov eax, (TANK ptr [esi]).phantomX
        mov ecx, (TANK ptr [esi]).phantomY
        add ecx, HUD_H
        invoke DrawPhantom, hdcBack, eax, ecx
        pop esi
        pop ebx
TP_NoPh:
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

    ; 3b) 激光：发射路径（红实线）与瞄准预览（灰虚线）
    mov eax, laserT
    .if eax > 0 && laserN >= 2
        invoke SelectObject, hdcBack, penLaser
        mov eax, laserY[0]
        add eax, HUD_H
        invoke MoveToEx, hdcBack, laserX[0], eax, 0
        xor ebx, ebx
GL_Seg:
        inc ebx
        mov eax, laserN
        .if ebx < eax
            mov edx, ebx
            shl edx, 2
            mov eax, laserY[edx]
            add eax, HUD_H
            mov ecx, laserX[edx]
            invoke LineTo, hdcBack, ecx, eax
            jmp GL_Seg
        .endif
    .endif
    mov eax, prevTank
    .if eax != -1 && prevN >= 2
        invoke SelectObject, hdcBack, penPreview
        mov eax, prevY[0]
        add eax, HUD_H
        invoke MoveToEx, hdcBack, prevX[0], eax, 0
        xor ebx, ebx
GP_Seg:
        inc ebx
        mov eax, prevN
        .if ebx < eax
            mov edx, ebx
            shl edx, 2
            mov eax, prevY[edx]
            add eax, HUD_H
            mov ecx, prevX[edx]
            invoke LineTo, hdcBack, ecx, eax
            jmp GP_Seg
        .endif
    .endif

    ; 4) 比赛结束覆盖层：胜者大字 + 提示
    mov eax, matchOver
    .if eax != 0
        ; 最高分槽位
        xor ebx, ebx
        xor esi, esi                     ; bestSlot
        mov edi, -1                      ; bestScore（esi/edi 临时）
GM_Best:
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov eax, (TANK ptr [eax]).score
        .if eax > edi
            mov edi, eax
            mov esi, ebx
        .endif
        inc ebx
        .if ebx < MAX_PLAYERS
            jmp GM_Best
        .endif
        invoke FillRect, hdcBack, addr rc, brushHud
        invoke SelectObject, hdcBack, menuFont
        ; "P? WINS THE MATCH!" / "P? 获胜！"
        lea edi, scoreBuf
        mov byte ptr [edi], 'P'
        mov eax, esi
        add al, '1'
        mov [edi+1], al
        mov word ptr [edi+2], 0
        invoke UiTextZ, hdcBack, 380, 270, offset scoreBuf, 0000E0E0h
        .if langFlag != 0
            invoke TextOutW, hdcBack, 385, 320, offset CN_WIN, 7
        .else
            invoke TextOutA, hdcBack, 420, 325, offset szWinsEn, 15
        .endif
        invoke SelectObject, hdcBack, fontSmall
        .if langFlag != 0
            invoke TextOutW, hdcBack, 420, 400, offset CN_BACKMENU, 8
        .else
            invoke TextOutA, hdcBack, 405, 402, offset szBackEn, 20
        .endif
    .endif

    ; 5) 恢复画笔，整幅上屏
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
    invoke DeleteObject, brushDirt
    invoke DeleteObject, brushDirtDark
    invoke DeleteObject, brushP1
    invoke DeleteObject, brushP2
    invoke DeleteObject, brushP3
    invoke DeleteObject, brushP4
    invoke DeleteObject, brushBullet
    invoke DeleteObject, brushHud
    ; 技能刷与激光笔
    xor ebx, ebx
GS_SkillBrush:
    mov eax, skillBrush[ebx*4]
    .if eax != 0
        push ebx
        invoke DeleteObject, eax
        pop ebx
    .endif
    inc ebx
    .if ebx < 9
        jmp GS_SkillBrush
    .endif
    invoke DeleteObject, penLaser
    invoke DeleteObject, penPreview
    ret
GfxShutdown endp

end
