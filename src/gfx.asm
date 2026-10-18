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
public DrawPickupIcon             ; 技能说明页复用图标绘制
public brushPickBg                ; 说明页图标底色
public brushIcon                  ; 图标白色填充
public penIcon                    ; 图标白色笔
public penOld2                    ; 说明页恢复用
public brushMortar                ; 图标深色描边
public DrawTank                   ; 玩法演示复用
public brushP1                    ; 玩法演示车体色
public brushP2
public brushBullet                ; 玩法演示子弹
public brushBrick                 ; 玩法演示爆炸/血条
public brushIce                   ; 玩法演示地形
public brushWater                 ; 玩法演示地形
public brushBg                    ; 玩法演示空地
public brushSteel                 ; 玩法演示挡板
public brushDirt                  ; 玩法演示地形（泥地）
public brushDirtDark              ; 玩法演示泥地纹理
public brushWave                  ; 玩法演示水波纹
public brushStreak                ; 玩法演示冰高光
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
extern fontBig     :dword          ; 倒计时大数字（ui.asm）
extern playerName  :byte           ; 玩家名（ui.asm，每人 16 字节）
extern pauseMode   :dword          ; 0=无 1=暂停 2=倒计时（ui.asm）
extern pauseSel    :dword          ; 暂停菜单选中项
extern countT      :dword          ; 倒计时剩余
extern volumeLvl   :dword          ; 音量 0..100
extern sfxOn       :dword          ; 音效开关
extern shakeT      :dword          ; 爆炸震屏剩余 tick（game.asm）
extern cosTBL      :dword          ; 360 度三角表 x1024（game.asm .data，gen_trig.py 生成）
extern sinTBL      :dword

WallRects PROTO :DWORD,:DWORD,:DWORD   ; game.asm：墙格挡板矩形枚举
UiTextZ   PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD   ; ui.asm：ASCII 文本
UiTextL   PROTO :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD ; ui.asm：双语文本

.data
    rotPts      POINT 8 dup (<>)    ; DrawTank 旋转顶点暂存（车体八边形；炮管复用前 4 个）
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
    scoreBuf    db 48 dup (0)       ; 比分/临时文本缓冲
    itemCol     dd 0                ; 暂停菜单当前项颜色
    brushPickBg dd ?                ; 拾取物深色底（蓝黑）
    brushIcon   dd ?                ; 图标白色填充
    penIcon     dd ?                ; 图标白色 2px 笔
    penOld2     dd ?
    gfxX        dd ?                ; 图标绘制原点（宏用）
    gfxY        dd ?
    szWinsEn    db "WINS THE MATCH!", 0
    szBackEn    db "PRESS ENTER FOR MENU", 0
    szPaused    db "PAUSED", 0
    szResume    db "RESUME (ENTER)", 0
    szVol       db "VOLUME: <- ->", 0
    szSfx       db "SOUND FX", 0
    szQuit      db "QUIT TO MENU", 0
    szOn        db "ON", 0
    szOff       db "OFF", 0
    CN_WIN      dw 83B7h,5F97h,6BD4h,8D5Bh,80DCh,5229h,0FF01h, 0 ; 获得比赛胜利！
    CN_BACKMENU dw 6309h,56DEh,8F66h,8FD4h,56DEh,4E3Bh,83DCh,5355h, 0 ; 按回车返回主菜单
    CN_PAUSED   dw 5df2h,6682h,505ch, 0                       ; 已暂停
    CN_RESUME   dw 7ee7h,7eedh,6e38h,620fh,0FF08h,56deh,8f66h,0FF09h, 0 ; 继续游戏(回车)
    CN_VOL      dw 97f3h,91cfh,0FF1Ah, 0                      ; 音量：
    CN_SFX      dw 97f3h,6548h, 0                             ; 音效
    CN_QUIT     dw 9000h,51fah,6e38h,620fh, 0                 ; 退出游戏
    CN_ON       dw 5f00h, 0                                   ; 开
    CN_OFF      dw 5173h, 0                                   ; 关

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
    invoke CreateSolidBrush, 00202030h       ; 拾取物深蓝黑底
    mov brushPickBg, eax
    invoke CreateSolidBrush, 00F0F0F0h       ; 图标白
    mov brushIcon, eax
    invoke CreatePen, PS_SOLID, 2, 00F0F0F0h
    mov penIcon, eax
    ret
GfxInit endp

; ------------------------------------------------------------
; DrawHud —— 会话 27 重排：所有玩家块作为一组按 numPlayers 水平
;   居中（旧版固定 4 槽左起）；不再显示生命数（一命制下无信息量）；
;   每块 = 相应颜色小坦克（DrawTank 25px 炮口朝右）+ 30px 大号
;   得分（menuFont）+ 18px 玩家名（fontSmall），更醒目。
;   文本白色由 GfxRender 预设（SetTextColor/SetBkMode）。
; ------------------------------------------------------------
DrawTank PROTO hdc: dword, px: dword, py: dword, dirV: dword
DrawHud proc uses ebx esi edi
    local oldBr: dword
    local x0: dword
    ; ---- 组起点：total = n*212 + (n-1)*24，x0 = (MAP_W-total)/2 ----
    mov eax, numPlayers
    imul eax, eax, 212
    mov ecx, numPlayers
    dec ecx
    imul ecx, ecx, 24
    add eax, ecx
    mov edx, MAP_W
    sub edx, eax
    shr edx, 1
    mov x0, edx
    xor ebx, ebx
DH_Blk:
    .if ebx >= numPlayers
        ret
    .endif
    ; ---- 玩家色小坦克（DrawTank 自理画笔），y 626..651 ----
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
    mov oldBr, eax
    invoke DrawTank, hdcBack, x0, 626, 0
    ; ---- 大号得分：x0+31 起，30px，两位封顶 99（沿用旧口径）----
    invoke SelectObject, hdcBack, menuFont
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
    mov edi, OFFSET scoreBuf
    mov [edi], al
    mov [edi+1], dl
    mov byte ptr [edi+2], 0
    mov eax, x0
    add eax, 31
    invoke TextOutA, hdcBack, eax, 620, offset scoreBuf, 2
    ; ---- 玩家名：x0+85 起，18px（≤15 字节截断，同旧版）----
    invoke SelectObject, hdcBack, fontSmall
    mov eax, ebx
    imul eax, eax, 16
    add eax, offset playerName
    mov edi, OFFSET scoreBuf
    xor ecx, ecx
DH_Nm:
    mov dl, [eax+ecx]
    .if dl == 0
        jmp DH_NmDone
    .endif
    mov [edi+ecx], dl
    inc ecx
    .if ecx < 15
        jmp DH_Nm
    .endif
DH_NmDone:
    mov byte ptr [edi+ecx], 0
    mov eax, x0
    add eax, 85
    invoke TextOutA, hdcBack, eax, 630, offset scoreBuf, ecx
    invoke SelectObject, hdcBack, oldBr
    add x0, 212 + 24
    inc ebx
    jmp DH_Blk
DrawHud endp

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
; 坦克边长 TANK_SIZE=25（会话 17 定稿）；炮管伸出车体 8px = 出弹点
; ------------------------------------------------------------
; ------------------------------------------------------------
; PickLine -- 白色笔画线段（x1,y1 -> x2,y2）
; ------------------------------------------------------------
PickLine proc hdc: dword, x1: dword, y1: dword, x2: dword, y2: dword
    invoke MoveToEx, hdc, x1, y1, 0
    invoke LineTo, hdc, x2, y2
    ret
PickLine endp

; 坐标先算进寄存器再 invoke（px+const 在参数里会被当内存寻址！）
; 坐标 = (px + off*sc, py + off*sc)，sc 为缩放（拾取物 1，说明页大图 3）
PK_LINE MACRO hx, x1, y1, x2, y2
    mov eax, x1
    imul eax, sc
    add eax, px
    mov ecx, y1
    imul ecx, sc
    add ecx, py
    mov edx, x2
    imul edx, sc
    add edx, px
    mov ebx, y2
    imul ebx, sc
    add ebx, py
    invoke PickLine, hx, eax, ecx, edx, ebx
ENDM
PK_FILL MACRO hx, what, x1, y1, x2, y2
    mov eax, x1
    imul eax, sc
    add eax, px
    mov ecx, y1
    imul ecx, sc
    add ecx, py
    mov edx, x2
    imul edx, sc
    add edx, px
    mov ebx, y2
    imul ebx, sc
    add ebx, py
    invoke what, hx, eax, ecx, edx, ebx
ENDM
DrawPickupIcon proc uses ebx edi hdc: dword, px: dword, py: dword, tp: dword, sc: dword
    mov eax, tp
    .if eax == SK_ICE_SHIELD
        ; 冰盾：盾牌轮廓（平顶垂边、下收尖）+ 中央冰晶十字
        PK_LINE hdc, 3,3, 13,3
        PK_LINE hdc, 3,3, 3,9
        PK_LINE hdc, 13,3, 13,9
        PK_LINE hdc, 3,9, 8,14
        PK_LINE hdc, 13,9, 8,14
        PK_LINE hdc, 8,5, 8,11
        PK_LINE hdc, 5,8, 11,8
    .elseif eax == SK_LASER
        ; 激光炮：大炮剪影 = 粗炮轮 + 炮管 + 炮口箍（白色填充）
        invoke SelectObject, hdc, brushIcon
        PK_FILL hdc, Ellipse, 2,8, 10,16
        PK_FILL hdc, Rectangle, 5,6, 15,10
        PK_FILL hdc, Rectangle, 13,4, 16,12
    .elseif eax == SK_REFLASER
        PK_LINE hdc, 3, 14, 8, 14
        PK_LINE hdc, 8, 14, 8, 4
        PK_LINE hdc, 8, 4, 13, 4
        PK_LINE hdc, 13, 4, 13, 14
    .elseif eax == SK_GHOST
        ; 穿墙术：实心竖墙块、中央留缝；箭头自左贯入右贯出
        invoke SelectObject, hdc, brushIcon
        PK_FILL hdc, Rectangle, 6,1, 10,7
        PK_FILL hdc, Rectangle, 6,10, 10,16
        PK_LINE hdc, 1, 8, 15, 8
        PK_LINE hdc, 12, 5, 15, 8
        PK_LINE hdc, 12, 11, 15, 8
    .elseif eax == SK_MINE
        ; 地雷：圆弹体（白填充）+ 引信 + 火花十字
        invoke SelectObject, hdc, brushIcon
        PK_FILL hdc, Ellipse, 1,6, 11,15
        PK_LINE hdc, 9, 6, 12, 3
        PK_LINE hdc, 12, 1, 12, 5
        PK_LINE hdc, 10, 3, 14, 3
    .elseif eax == SK_NITRO
        PK_LINE hdc, 3, 4, 7, 9
        PK_LINE hdc, 7, 9, 3, 14
        PK_LINE hdc, 9, 4, 13, 9
        PK_LINE hdc, 13, 9, 9, 14
    .elseif eax == SK_SWAP
        PK_LINE hdc, 4, 6, 14, 6
        PK_LINE hdc, 11, 3, 14, 6
        PK_LINE hdc, 14, 6, 11, 9
        PK_LINE hdc, 14, 12, 4, 12
        PK_LINE hdc, 7, 9, 4, 12
        PK_LINE hdc, 4, 12, 7, 15
    .elseif eax == SK_WATER
        ; 驭水术：两排海浪波纹线
        PK_LINE hdc, 2, 7, 4, 4
        PK_LINE hdc, 4, 4, 6, 7
        PK_LINE hdc, 6, 7, 8, 4
        PK_LINE hdc, 8, 4, 10, 7
        PK_LINE hdc, 10, 7, 12, 4
        PK_LINE hdc, 12, 4, 14, 7
        PK_LINE hdc, 2, 14, 4, 11
        PK_LINE hdc, 4, 11, 6, 14
        PK_LINE hdc, 6, 14, 8, 11
        PK_LINE hdc, 8, 11, 10, 14
        PK_LINE hdc, 10, 14, 12, 11
        PK_LINE hdc, 12, 11, 14, 14
    .else
        ; 定格术：照相机 = 白机身+顶钮，镜头三层同心（暗环/白圈/暗瞳）。
        ; 镂空用 brushPickBg——所有调用方都先铺该色深色底板
        invoke SelectObject, hdc, brushIcon
        PK_FILL hdc, Rectangle, 2, 6, 14, 14
        PK_FILL hdc, Rectangle, 6, 4, 10, 6
        invoke SelectObject, hdc, brushPickBg
        PK_FILL hdc, Ellipse, 5, 8, 11, 14
        invoke SelectObject, hdc, brushIcon
        PK_FILL hdc, Ellipse, 6, 9, 10, 13
        invoke SelectObject, hdc, brushPickBg
        PK_FILL hdc, Ellipse, 7, 10, 9, 12
        invoke SelectObject, hdc, brushIcon      ; 复位白刷，别把镂空色留给后面绘制
    .endif
    ret
DrawPickupIcon endp

; ROTP —— 局部点（以车体中心为原点，局部前向=+x）旋转到 [ecx] 顶点并推进。
; 调用前需备好：ecx=顶点指针，局部变量 cxL/cyL/cosL/sinL。
; gx = cx + (lx*c - ly*s)>>10；gy = cy + (lx*s + ly*c)>>10（屏幕 y 向下，CW+）
ROTP macro lx, ly
    mov eax, cosL
    imul eax, eax, lx
    mov edx, sinL
    imul edx, edx, ly
    sub eax, edx
    sar eax, TRIG_SHIFT
    add eax, cxL
    mov (POINT ptr [ecx]).x, eax
    mov eax, sinL
    imul eax, eax, lx
    mov edx, cosL
    imul edx, edx, ly
    add eax, edx
    sar eax, TRIG_SHIFT
    add eax, cyL
    mov (POINT ptr [ecx]).y, eax
    add ecx, SIZEOF POINT
endm

; ------------------------------------------------------------
; DrawTank —— 整车旋转渲染（会话 19）
; dirV = 航向角 0..359（0右 90下 180左 270上，屏幕顺时针为正）。
; 局部前向取 +x，与弹道向量 (cos,sin) 同向 —— 旧 360 版把前向定在
; -y，炮管与瞄准差 90 度（看着朝天打实际朝右飞），此处不得重犯。
; 车体 = 原 RoundRect(25,圆角9) 的八边形近似（四角切 5）；炮管 =
; 局部 x -3..21、y +-3 的矩形四角（伸出体外 8px = 出弹位，与
; MuzzlePoint 分离距离一致，做到"指哪打哪"）；炮塔/舱盖为圆，
; 圆旋转不变，舱盖中心沿航向偏 2px 示意朝向。
; 已知妥协：碰撞盒仍是 25px 轴对齐 AABB，45 度时视觉角尖可探入
; 墙 <=3.6px（旧 360 版同款）。正交角度下与原 Square 风格视觉差 <=1px。
; ------------------------------------------------------------
DrawTank proc hdc: dword, px: dword, py: dword, dirV: dword
    local cxL:dword, cyL:dword, cosL:dword, sinL:dword
    local rc2:RECT
    local oldPen:dword
    invoke SelectObject, hdc, penDark
    mov oldPen, eax
    ; 旋转锚 = 车体中心
    mov eax, px
    add eax, TANK_SIZE/2
    mov cxL, eax
    mov eax, py
    add eax, TANK_SIZE/2
    mov cyL, eax
    ; 单位向量 x1024（dir 恒 0..359：TurnTank/NetRestore 保证规范化）
    mov eax, dirV
    mov ecx, cosTBL[eax*4]
    mov cosL, ecx
    mov ecx, sinTBL[eax*4]
    mov sinL, ecx
    ; 炮管（先画，压在车体下层）
    lea ecx, rotPts
    ROTP 21, 3
    ROTP 21, -3
    ROTP -3, -3
    ROTP -3, 3
    invoke Polygon, hdc, addr rotPts, 4
    ; 车体八边形
    lea ecx, rotPts
    ROTP 12, 7
    ROTP 12, -7
    ROTP 7, -12
    ROTP -7, -12
    ROTP -12, -7
    ROTP -12, 7
    ROTP -7, 12
    ROTP 7, 12
    invoke Polygon, hdc, addr rotPts, 8
    ; 炮塔（大圆 直径 17 居中，旋转不变）
    mov eax, cxL
    sub eax, 8
    mov rc2.left, eax
    add eax, 17
    mov rc2.right, eax
    mov eax, cyL
    sub eax, 8
    mov rc2.top, eax
    add eax, 17
    mov rc2.bottom, eax
    invoke Ellipse, hdc, rc2.left, rc2.top, rc2.right, rc2.bottom
    ; 舱盖（中心小圆 直径 7，近黑；沿航向偏 2px 示意朝向）
    invoke SelectObject, hdc, brushBullet
    mov eax, cosL
    imul eax, eax, 2
    sar eax, TRIG_SHIFT
    add eax, cxL
    sub eax, 3
    mov rc2.left, eax
    add eax, 7
    mov rc2.right, eax
    mov eax, sinL
    imul eax, eax, 2
    sar eax, TRIG_SHIFT
    add eax, cyL
    sub eax, 3
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
        sub eax, 4
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
        add eax, TANK_SIZE-5
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
        add eax, TANK_SIZE-5
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
        add eax, TANK_SIZE-5
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
    ; 计分条在地图下方：坦克色块图标 + 玩家名 + 分数
    mov rc.top, MAP_H
    mov rc.bottom, WND_H
    invoke FillRect, hdcBack, addr rc, brushHud
    invoke SetBkMode, hdcBack, TRANSPARENT
    invoke SetTextColor, hdcBack, 00FFFFFFh
    invoke SelectObject, hdcBack, fontSmall
    invoke DrawHud

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

    ; 1c) 技能拾取物：深色方块 + 特性图形（白 2px，见 DrawPickupIcon）
    mov eax, pickupType
    .if eax != 0
        mov eax, pickupX
        mov rc.left, eax
        add eax, PICKUP_SIZE
        mov rc.right, eax
        mov eax, pickupY
        mov rc.top, eax
        add eax, PICKUP_SIZE
        mov rc.bottom, eax
        invoke FillRect, hdcBack, addr rc, brushPickBg
        invoke FrameRect, hdcBack, addr rc, brushMortar
        invoke SelectObject, hdcBack, penIcon
        mov penOld2, eax
        mov eax, pickupX
        mov ecx, pickupY
        mov eax, pickupType
        invoke DrawPickupIcon, hdcBack, pickupX, pickupY, pickupType, 1
        invoke SelectObject, hdcBack, penOld2
    .endif

    ; 2) 画坦克（ebx=槽位号；地图从 y=0 渲染，HUD 在 MAP_H 之下）
    xor ebx, ebx
    mov esi, offset tanks
TankLoop:
    mov eax, (TANK ptr [esi]).alive
    .if eax != 0
        ; 重生保护期闪烁：暗相跳过绘制
        mov eax, (TANK ptr [esi]).protT
        .if eax > 0
            and eax, 8
            .if eax == 0
                jmp TankSkip
            .endif
        .endif
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
        invoke DrawPhantom, hdcBack, eax, ecx
        pop esi
        pop ebx
TP_NoPh:
    .endif
TankSkip:
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp TankLoop
    .endif

    ; 3) 画子弹（黑色小圆；同样 y 不偏移，地图原点即窗口原点）
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
        invoke MoveToEx, hdcBack, laserX[0], eax, 0
        xor ebx, ebx
GL_Seg:
        inc ebx
        mov eax, laserN
        .if ebx < eax
            mov edx, ebx
            shl edx, 2
            mov eax, laserY[edx]
            mov ecx, laserX[edx]
            invoke LineTo, hdcBack, ecx, eax
            jmp GL_Seg
        .endif
    .endif
    mov eax, prevTank
    .if eax != -1 && prevN >= 2
        invoke SelectObject, hdcBack, penPreview
        mov eax, prevY[0]
        invoke MoveToEx, hdcBack, prevX[0], eax, 0
        xor ebx, ebx
GP_Seg:
        inc ebx
        mov eax, prevN
        .if ebx < eax
            mov edx, ebx
            shl edx, 2
            mov eax, prevY[edx]
            mov ecx, prevX[edx]
            invoke LineTo, hdcBack, ecx, eax
            jmp GP_Seg
        .endif
    .endif

    ; 4b) 暂停 / 倒计时覆盖层
    mov eax, pauseMode
    .if eax == 1
        ; 半透风格深色覆盖（整幅地图区）
        mov rc.left, 0
        mov rc.top, 0
        mov rc.right, WND_W
        mov rc.bottom, WND_H
        invoke FillRect, hdcBack, addr rc, brushHud
        invoke SelectObject, hdcBack, menuFont
        invoke UiTextL, hdcBack, 440, 220, offset szPaused, offset CN_PAUSED, 0000E0E0h
        xor ebx, ebx                     ; 菜单项号
GP_Item:
        ; 项高亮色
        mov eax, pauseSel
        .if eax == ebx
            mov eax, 0000E0E0h
        .else
            mov eax, 00A0A0A0h
        .endif
        mov itemCol, eax
        invoke SelectObject, hdcBack, fontSmall
        mov eax, ebx
        .if eax == 0
            invoke UiTextL, hdcBack, 470, 300, offset szResume, offset CN_RESUME, itemCol
        .elseif eax == 1
            invoke UiTextL, hdcBack, 470, 344, offset szVol, offset CN_VOL, itemCol
            ; 音量数值 nn%
            lea edi, scoreBuf
            mov eax, volumeLvl
            xor edx, edx
            mov ecx, 10
            div ecx
            add al, '0'
            add dl, '0'
            mov [edi], al
            mov [edi+1], dl
            mov word ptr [edi+2], 0
            invoke TextOutA, hdcBack, 560, 344, offset scoreBuf, 2
        .elseif eax == 2
            mov eax, sfxOn
            .if eax != 0
                invoke UiTextL, hdcBack, 470, 388, offset szSfx, offset CN_SFX, itemCol
                invoke UiTextL, hdcBack, 560, 388, offset szOn, offset CN_ON, itemCol
            .else
                invoke UiTextL, hdcBack, 470, 388, offset szSfx, offset CN_SFX, itemCol
                invoke UiTextL, hdcBack, 560, 388, offset szOff, offset CN_OFF, itemCol
            .endif
        .else
            invoke UiTextL, hdcBack, 470, 432, offset szQuit, offset CN_QUIT, itemCol
        .endif
        inc ebx
        .if ebx < 4
            jmp GP_Item
        .endif
    .elseif eax == 2
        ; 倒计时大数字（3/2/1）居中
        invoke SelectObject, hdcBack, fontBig
        mov eax, countT
        add eax, 59
        xor edx, edx
        mov ecx, 60
        div ecx                          ; eax = ceil(countT/60)
        add al, '0'
        lea edi, scoreBuf
        mov [edi], al
        mov word ptr [edi+1], 0
        invoke UiTextZ, hdcBack, 470, 260, offset scoreBuf, 0000E0E0h
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

    ; 5) 恢复画笔，整幅上屏（爆炸震屏：随机偏移 ±3px）
    invoke SelectObject, hdcBack, penOld
    invoke GetDC, hWnd
    mov hdcWin, eax
    xor ecx, ecx                     ; dx
    xor edx, edx                     ; dy
    mov eax, shakeT
    .if eax > 0
        invoke GetTickCount
        mov ebx, eax
        and ebx, 7
        sub ebx, 3                   ; dx = -3..4
        invoke GetTickCount
        shr eax, 3
        and eax, 7
        sub eax, 3                   ; dy = -3..4
        mov ecx, ebx
        mov edx, eax
    .endif
    invoke BitBlt, hdcWin, ecx, edx, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
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
    invoke DeleteObject, brushPickBg
    invoke DeleteObject, brushIcon
    invoke DeleteObject, penIcon
    ret
GfxShutdown endp

end
