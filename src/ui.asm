; ============================================================
; ui.asm —— 界面状态机：主菜单 / 人数选择 / 按键设置 / 联机大厅
; 键盘操作（边沿检测防连发，导航键固定不受自定义键位影响）：
;   主菜单: ↑↓ 选择, Enter 确认, 鼠标悬停+左键点击
;   人数选择: ←→ 调整 2..4, Enter 开始, Esc 返回
;     下方按当前人数显示键位容器（2 人 2 个 .. 4 人 4 个）：
;     鼠标点击某键位 -> 闪烁等待 -> 按新键完成改键（冲突则拒绝），
;     容器区右下角"重置按键"按钮恢复默认；键盘操作全部保留
;   设置: ↑↓ 选择动作, Enter 进入重绑 -> 按任意键完成, Esc 返回
;   联机: 自动 UDP 广播发现对手(端口 28888), Enter 与发现的对手开战
;   对局中: Esc 回主菜单
; 联机说明：双方都进"LAN PLAY"页 -> 互相广播发现 -> 各自按 Enter 开战。
;   对局内本机驱动 slot0，对方坦克经 UDP 状态同步显示（net.asm）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

public gameState
public numPlayers
public netMode
public menuFont
public fontSmall
public fontBig
public langFlag
public playerName
public pauseMode
public pauseSel
public countT
public volumeLvl
public sfxOn
public themeNight
public clickEvt
public clickPX
public clickPY
public UiInit
public UiTick
public UiRender
public UiTextZ
public UiForcePlay2
public UiForceNumSel

extern hWnd      :dword
extern hdcBack   :dword
extern keyTable  :dword
extern maxRounds :dword
extern matchOver :dword
GameInit  PROTO
InitKeyDefaults PROTO
GfxRender PROTO
NetInit   PROTO
NetFlush  PROTO
NetShutdown PROTO
SndVolume PROTO :DWORD
SndPlay   PROTO :DWORD
extern peerAddr  :sockaddr_in
extern peerKnown :dword
extern hSock     :dword

; win32.inc 未收录的鼠标 API 原型与常量
VK_LBUTTON     equ 001h
VK_BACK        equ 008h
GetCursorPos   PROTO stdcall :DWORD
ScreenToClient PROTO stdcall :DWORD,:DWORD

; ---- 人数选择页键位容器布局（客户区 992x640，6 行/人）----
KBBOX_X0   equ 28                  ; 首个容器左缘
KBBOX_DX   equ 240                 ; 容器水平间距（宽 216 + 缝 24）
KBBOX_W    equ 216                 ; 容器宽
KBBOX_H    equ 228                 ; 容器高（头 40 + 6 行*30 + 底 8）
KBBOX_Y    equ 322                 ; 容器顶部 y
KBROW_Y0   equ 40                  ; 容器顶 -> 首行偏移
KBROW_DH   equ 30                  ; 行高
RST_X      equ 745                 ; 重置按钮区（容器区右下角）
RST_Y      equ 556
RST_W      equ 210
RST_H      equ 30

.data
    gameState   dd ST_MENU
    langFlag    dd 1                   ; 0=英文 1=中文（默认中文）
    numPlayers  dd 2
    netMode     dd 0                   ; 1 = 联机对局（主循环调用 NetFlush）
    menuSel     dd 0
    numSel      dd 2
    roundsSel   dd 11                  ; 人数页可调的比赛局数（11..51 奇数）
    playerName  db "P1", 0, 13 dup (0), "P2", 0, 13 dup (0)
                db "P3", 0, 13 dup (0), "P4", 0, 13 dup (0)   ; 每人 16 字节
    editSlot    dd -1                  ; 正在改名的容器槽位（-1=无）
    pauseMode   dd 0                   ; 0=无 1=暂停菜单 2=继续倒计时
    pauseSel    dd 0                   ; 暂停菜单选中项 0继续 1音量 2音效 3退出
    countT      dd 0                   ; 倒计时剩余 tick
    volumeLvl   dd 70                  ; 主音量 0..100
    sfxOn       dd 1                   ; 音效开关
    themeNight  dd 0                   ; 深夜模式（主页面黑风）
    setSel      dd 0
    rebindWait  dd 0
    prevUp      dd 0
    prevDown    dd 0
    prevLeft    dd 0
    prevRight   dd 0
    prevEnter   dd 0
    prevEsc     dd 0
    prevAny     dd 0
    prevLBtn    dd 0                   ; 鼠标左键上帧状态（边沿检测）
    mousePt     POINT <>               ; 鼠标客户区坐标（GetCursorPos+ScreenToClient）
    mouseX      dd 0
    mouseY      dd 0
    rebindSlot  dd -1                  ; 人数页改键：正在等待新键的槽位（slot*5+动作），-1=无
    rebindCool  dd 0                   ; 改键进入等待的防误捕冷却 tick
    dbgRet      dd 999                 ; 最近一次 NumSelHitTest 返回（临时诊断）
    dbgMX       dd 0                   ; DBG: HitTest 输入 x
    dbgMY       dd 0                   ; DBG: HitTest 输入 y
    clickEvt    dd 0                   ; 1=本帧有待处理的鼠标点击（WndProc 置位）
    clickPX     dd 0                   ; 点击客户区坐标（消息 lParam）
    clickPY     dd 0
    blinkTick   dd 0                   ; 改键闪烁计数
    discTimer   dd 0
    discBuf     db "TWNET01"
    discFrom    sockaddr_in <>
    discLen     dd SIZEOF sockaddr_in
    recvTmp     db 64 dup (0)
    peerIpBuf   db 20 dup (0)
    peerIpLen   dd 0
    uiBuf       db 96 dup (0)
    menuBrush   dd ?
    menuFont    dd ?
    fontSmall   dd ?                   ; 键位容器用小字体（18px）
    fontBig     dd ?                   ; 倒计时大数字（72px）
    boxBrush    dd ?                   ; 容器边框画刷（深灰）
    brushNight  dd ?                   ; 深夜模式背景刷（近黑）
    boxBrushN   dd ?                   ; 深夜模式容器边框（浅灰）
    boxCur      dd ?                   ; 当帧生效的边框刷
    fontOld     dd ?
    bcastAddr   sockaddr_in <>
    oneVal      dd 1
    aTab        dd aUp, aDn, aLt, aRt, aFire, aUse
    aUp         db "UP", 0
    aDn         db "DOWN", 0
    aLt         db "LEFT", 0
    aRt         db "RIGHT", 0
    aFire       db "FIRE", 0
    aUse        db "SKILL", 0
    ; 中文动作名：等长指针表（每项独立 0 结尾，按下标索引）
    cUpW        dw 4E0Ah, 0             ; 上
    cDnW        dw 4E0Bh, 0             ; 下
    cLtW        dw 5DE6h, 0             ; 左
    cRtW        dw 53F3h, 0             ; 右
    cFireW      dw 5F00h, 706Bh, 0      ; 开火
    cUseW       dw 4F7Fh, 7528h, 0      ; 使用（技能）
    cnActT      dd cUpW, cDnW, cLtW, cRtW, cFireW, cUseW
    vkUpN       db "UP", 0
    vkDnN       db "DOWN", 0
    vkLtN       db "LEFT", 0
    vkRtN       db "RIGHT", 0
    vkSpN       db "SPACE", 0
    vkEnN       db "ENTER", 0
    vkRsN       db "RSH", 0
    vkLsN       db "LSH", 0
    szTitle     db "T A N K   W A R   A S M", 0
    szKeysLbl   db "KEYS (CLICK A KEY TO CHANGE)", 0
    szItem1     db "START GAME", 0
    szItem2     db "SETTINGS", 0
    szItem3     db "LAN PLAY", 0
    szItem4     db "EXIT", 0
    szNumT      db "SELECT PLAYERS", 0
    szNumL      db "<<", 0
    szNumR      db ">>", 0
    szRounds    db "ROUNDS", 0
    szHint      db "ENTER: CONFIRM   ESC: BACK", 0
    szNameHint  db "CLICK NAME TO RENAME", 0
    szNameEdit  db "TYPE A NAME, ENTER TO OK", 0
    szVol2      db "VOLUME", 0
    szSfx2      db "SOUND FX", 0
    szOn2       db "ON", 0
    szOff2      db "OFF", 0
    szNight     db "NIGHT MODE", 0
    szReset     db "RESET ALL KEYS", 0
    szReb2      db "PRESS ANY KEY (EN IME! ESC=CANCEL)", 0
    szSetT      db "KEY SETTINGS", 0
    szSetH      db "ENTER: REBIND   ESC: BACK", 0
    szRebind    db " <- PRESS ANY KEY", 0
    szLanT      db "LAN PLAY", 0
    szLanB      db "BROADCASTING ON UDP PORT 28888 ...", 0
    szLanN      db "SEARCHING FOR PEERS ...", 0
    szLanF      db "PEER FOUND:", 0
    szLanS      db "ENTER: START MATCH   ESC: BACK", 0
    szFont      db "Arial", 0
    wBuf        dd 64 dup (0)           ; 设置行宽字符缓冲
    szLangEN    db "LANGUAGE: ENGLISH", 0
    cnActW      dw 4E0Ah, 0             ; 上
                dw 4E0Bh, 0             ; 下
                dw 5DE6h, 0             ; 左
                dw 53F3h, 0             ; 右
                dw 5F00h, 706Bh, 0      ; 开火
    CN_START dw 5f00h,59cbh,6e38h,620fh, 0
    CN_SET dw 8bbeh,7f6eh, 0
    CN_LAN dw 8054h,673ah,5bf9h,6218h, 0
    CN_EXIT dw 9000h,51fah, 0
    CN_LANG dw 8bedh,8a00h,0ff1ah,4e2dh,6587h, 0
    CN_NUMT dw 9009h,62e9h,73a9h,5bb6h,6570h,91cfh, 0
    CN_ROUNDS dw 5c40h,6570h, 0                                          ; 局数
    CN_HINT dw 56deh,8f66h,0ff1ah,786eh,8ba4h,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_NAMEHINT dw 70B9h,51FBh,540Dh,5B57h,53EFh,6539h,540Dh, 0   ; 点击名字可改名
    CN_NAMEEDIT dw 8F93h,5165h,540Dh,5B57h,56DEh,8F66h,786Eh,8BA4h, 0 ; 输入名字回车确认
    CN_VOL2     dw 97F3h,91CFh, 0                              ; 音量
    CN_SFX      dw 97F3h,6548h, 0                              ; 音效
    CN_ON2      dw 5F00h, 0                                    ; 开
    CN_OFF2     dw 5173h, 0                                    ; 关
    CN_NIGHT    dw 6DF1h,591Ch,6A21h,5F0Fh, 0                  ; 深夜模式
    CN_RESET dw 91cdh,7f6eh,6240h,6709h,66f4h,6539h,6309h,952eh, 0        ; 重置所有更改按键
    CN_REB2 dw 8bf7h,6309h,4efbh,610fh,952eh,0FF08h,5148h,5207h,82f1h,6587h,8f93h,5165h,6cd5h,0FF09h, 0 ; 请按任意键（先切英文输入法）
    CN_KEYS dw 952eh,4f4dh, 0                                            ; 键位
    CN_SETT dw 6309h,952eh,8bbeh,7f6eh, 0
    CN_SETH dw 56deh,8f66h,0ff1ah,6539h,952eh,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    CN_REBIND dw 0020h,003ch,002dh,0020h,8bf7h,6309h,4efbh,610fh,952eh, 0
    CN_LANT dw 8054h,673ah,5bf9h,6218h,0ff08h,5c40h,57dfh,7f51h,0ff09h, 0
    CN_LANB dw 6b63h,5728h,901ah,8fc7h,0020h,0055h,0044h,0050h,0020h,7aefh,53e3h,0020h,0032h,0038h,0038h,0038h,0038h,0020h,5e7fh,64adh,0020h,002eh,002eh,002eh, 0
    CN_LANN dw 6b63h,5728h,641ch,7d22h,5bf9h,624bh,0020h,002eh,002eh,002eh, 0
    CN_LANF dw 5df2h,53d1h,73b0h,5bf9h,624bh,003ah, 0
    CN_LANS dw 56deh,8f66h,0ff1ah,5f00h,59cbh,6bd4h,8d5bh,0020h,0020h,0020h,0020h,0045h,0073h,0063h,0ff1ah,8fd4h,56deh, 0
    colDark     dd 00232323h
    colGray     dd 00606060h
    colHi       dd 0000C06000h
    colFound    dd 0000A000h
    hdcWin2     dd 0

.code

; ------------------------------------------------------------
; UiInit
; ------------------------------------------------------------
UiInit proc
    invoke CreateSolidBrush, 00D2D2D2h
    mov menuBrush, eax
    invoke CreateSolidBrush, 00141414h       ; 深夜模式背景（近黑）
    mov brushNight, eax
    invoke CreateSolidBrush, 00232323h
    mov boxBrush, eax
    invoke CreateSolidBrush, 00A0A0A0h       ; 深夜模式容器边框（浅灰）
    mov boxBrushN, eax
    invoke CreateFontA, 30, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov menuFont, eax
    invoke CreateFontA, 18, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov fontSmall, eax
    invoke CreateFontA, 72, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov fontBig, eax
    ; 键位默认值只在启动时设一次（GameInit 不再重置，
    ; 否则人数页改的自定义键位每局开局都会被洗掉）
    invoke InitKeyDefaults
    ret
UiInit endp

; ------------------------------------------------------------
; UiForcePlay2 -- 命令行 "tankwar play2"：跳过菜单直接 2P 对局
; （自动化截图验收用，避免菜单按键注入受启动期环境停顿影响）
; ------------------------------------------------------------
UiForcePlay2 proc
    mov numPlayers, 2
    invoke GameInit
    mov netMode, 0
    mov gameState, ST_PLAY
    ret
UiForcePlay2 endp

; ------------------------------------------------------------
; UiForceNumSel -- 命令行 "tankwar numsel"：直入人数选择页
; （无注入截图验收键位容器用）
; ------------------------------------------------------------
UiForceNumSel proc
    mov numSel, 2
    mov rebindSlot, -1
    mov gameState, ST_NUMSEL
    ret
UiForceNumSel endp

; ------------------------------------------------------------
; UiTextZ -- 输出 0 结尾字符串
; ------------------------------------------------------------
UiTextZ proc uses esi ecx hdc: dword, x: dword, y: dword, pStr: dword, color: dword
    invoke SetBkMode, hdc, TRANSPARENT
    invoke SetTextColor, hdc, color
    mov esi, pStr
    xor ecx, ecx
UTZ_Len:
    cmp byte ptr [esi+ecx], 0
    je UTZ_Out
    inc ecx
    jmp UTZ_Len
UTZ_Out:
    invoke TextOutA, hdc, x, y, pStr, ecx
    ret
UiTextZ endp

; ------------------------------------------------------------
; UiTextW -- 输出 UTF-16 字符串（自动求长）
; ------------------------------------------------------------
UiTextW proc uses esi ecx hdc: dword, x: dword, y: dword, pStr: dword, color: dword
    invoke SetBkMode, hdc, TRANSPARENT
    invoke SetTextColor, hdc, color
    mov esi, pStr
    xor ecx, ecx
UTW_Len:
    cmp word ptr [esi+ecx*2], 0
    je UTW_Out
    inc ecx
    jmp UTW_Len
UTW_Out:
    invoke TextOutW, hdc, x, y, pStr, ecx
    ret
UiTextW endp

; PickLang -- 按语言返回字符串指针：eax = pEn 或 pCn
PickLang proc pEn: dword, pCn: dword
    mov eax, pEn
    .if langFlag != 0
        mov eax, pCn
    .endif
    ret
PickLang endp

; ------------------------------------------------------------
; MenuActivate -- 主菜单当前项（menuSel）的激活动作
; 键盘 Enter 与鼠标左键点击共用，保证两种操作行为一致
; ------------------------------------------------------------
MenuActivate proc
    .if menuSel == 0
        mov rebindSlot, -1          ; 进入人数页清改键状态
        mov gameState, ST_NUMSEL
    .elseif menuSel == 1
        mov setSel, 0
        mov rebindWait, 0
        mov gameState, ST_SET
    .elseif menuSel == 2
        mov gameState, ST_LAN
        invoke NetShutdown
        invoke NetInit
        mov peerKnown, 0
        mov discTimer, 0
        invoke setsockopt, hSock, SOL_SOCKET, SO_BROADCAST,
               addr oneVal, 4
    .elseif menuSel == 3
        invoke PostQuitMessage, NULL
    .else
        xor langFlag, 1              ; 语言切换
    .endif
    ret
MenuActivate endp

; UiTextL -- 语言感知文本输出（EN=UiTextZ / CN=UiTextW）
UiTextL proc hdc: dword, x: dword, y: dword, pEn: dword, pCn: dword, color: dword
    .if langFlag == 0
        invoke UiTextZ, hdc, x, y, pEn, color
    .else
        invoke UiTextW, hdc, x, y, pCn, color
    .endif
    ret
UiTextL endp

; ------------------------------------------------------------
; KeyEdge -- 按键边沿检测
; ------------------------------------------------------------
KeyEdge proc vk: dword, pPrev: dword
    invoke GetAsyncKeyState, vk
    and eax, 8000h
    .if eax != 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov ecx, pPrev
    mov edx, [ecx]
    mov [ecx], eax
    .if eax != 0 && edx == 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    ret
KeyEdge endp

; ------------------------------------------------------------
; StrCopy -- 复制 len 字节
; ------------------------------------------------------------
StrCopy proc uses esi edi ecx pSrc: dword, pDst: dword, len: dword
    mov esi, pSrc
    mov edi, pDst
    mov ecx, len
    rep movsb
    ret
StrCopy endp

; ------------------------------------------------------------
; VkName -- VK 码 -> 名称（写 uiBuf，返回 eax = 长度）
; ------------------------------------------------------------
VkName proc uses ebx ecx edx edi vk: dword, pDst: dword
    mov edi, pDst
    mov eax, vk
    .if eax == VK_UP
        mov word ptr [edi], 'PU'            ; "UP"
        mov eax, 2
    .elseif eax == VK_DOWN
        invoke StrCopy, offset vkDnN, edi, 4
        mov eax, 4
    .elseif eax == VK_LEFT
        invoke StrCopy, offset vkLtN, edi, 4
        mov eax, 4
    .elseif eax == VK_RIGHT
        invoke StrCopy, offset vkRtN, edi, 5
        mov eax, 5
    .elseif eax == VK_SPACE
        invoke StrCopy, offset vkSpN, edi, 5
        mov eax, 5
    .elseif eax == VK_RETURN
        invoke StrCopy, offset vkEnN, edi, 5
        mov eax, 5
    .elseif eax == VK_RSHIFT
        invoke StrCopy, offset vkRsN, edi, 4
        mov eax, 4
    .elseif eax == VK_LSHIFT
        invoke StrCopy, offset vkLsN, edi, 4
        mov eax, 4
    .elseif (eax >= 'A' && eax <= 'Z') || (eax >= '0' && eax <= '9')
        mov [edi], al
        mov eax, 1
    .else
        mov byte ptr [edi], '0'
        mov byte ptr [edi+1], 'x'
        mov ecx, eax
        shr ecx, 4
        mov dl, cl
        .if dl < 10
            add dl, '0'
        .else
            add dl, '0'-10+7
        .endif
        mov [edi+2], dl
        mov ecx, eax
        and ecx, 0Fh
        mov dl, cl
        .if dl < 10
            add dl, '0'
        .else
            add dl, '0'-10+7
        .endif
        mov [edi+3], dl
        mov eax, 4
    .endif
    ret
VkName endp

; ------------------------------------------------------------
; IpToStr -- sin_addr 网络序 4 字节 -> "a.b.c.d"
; 返回 eax = 长度
; ------------------------------------------------------------
IpToStr proc uses ebx ecx edx esi edi pAddr: dword, pBuf: dword
    mov esi, pAddr
    mov edi, pBuf
    xor ecx, ecx
IPS_Seg:
    .if ecx >= 4
        jmp IPS_Done
    .endif
    .if ecx > 0
        mov byte ptr [edi], '.'
        inc edi
    .endif
    movzx eax, byte ptr [esi+ecx]
    xor edx, edx
    mov ebx, 100
    div ebx
    mov dh, 0                        ; 已写高位标志
    .if al > 0
        add al, '0'
        mov [edi], al
        inc edi
        mov dh, 1
    .endif
    mov eax, edx
    xor edx, edx
    mov ebx, 10
    div ebx
    .if al > 0 || dh != 0
        add al, '0'
        mov [edi], al
        inc edi
    .endif
    add dl, '0'
    mov [edi], dl
    inc edi
    inc ecx
    jmp IPS_Seg
IPS_Done:
    mov eax, edi
    sub eax, pBuf
    ret
IpToStr endp

; ------------------------------------------------------------
; NumSelHitTest -- 人数页鼠标命中测试
; 返回 eax: 0..19 = 键位槽位（slot*KEY_PER+动作），-2 = 重置按钮，
;           -3-slot = 容器标题（点击改名），-1 = 无
; ------------------------------------------------------------
NumSelHitTest proc uses ebx esi
    ; 重置按钮（容器区右下角）
    mov eax, mouseX
    .if eax >= RST_X && eax < RST_X+RST_W && mouseY >= RST_Y && mouseY < RST_Y+RST_H
        mov eax, -2
        ret
    .endif
    xor ebx, ebx                     ; 容器序号
NHT_Box:
    .if ebx >= numSel
        mov eax, -1
        ret
    .endif
    mov eax, ebx
    imul eax, eax, KBBOX_DX
    add eax, KBBOX_X0
    mov ecx, eax                     ; ecx = 容器左缘
    add eax, KBBOX_W
    .if mouseX >= ecx && mouseX < eax
        ; 容器标题区（P1..P4，y KBBOX_Y+4 .. +30）-> 改名
        mov eax, mouseY
        .if eax >= KBBOX_Y+4 && eax < KBBOX_Y+30
            mov eax, -3
            sub eax, ebx             ; -3-slot
            ret
        .endif
        mov edx, KBBOX_Y + KBROW_Y0  ; 首行顶部
        xor esi, esi
NHT_Row:
        .if esi >= KEY_PER
            jmp NHT_Next
        .endif
        mov eax, edx
        add eax, KBROW_DH - 4        ; 行命中高度 26px
        .if mouseY >= edx && mouseY < eax
            mov eax, ebx
            imul eax, eax, KEY_PER
            add eax, esi             ; slot*KEY_PER + 动作
            ret
        .endif
        add edx, KBROW_DH
        inc esi
        jmp NHT_Row
    .endif
NHT_Next:
    inc ebx
    jmp NHT_Box
NumSelHitTest endp

; 带符号十进制写 pBuf，返回长度（临时诊断用）
DbgW proc uses ebx ecx edi pBuf: dword, val: dword
    mov eax, val
    mov edi, pBuf
    test eax, eax
    jns DW_Pos
    mov byte ptr [edi], '-'
    inc edi
    neg eax
DW_Pos:
    xor ebx, ebx                       ; 位数
    mov ecx, 10
    .if eax == 0
        mov byte ptr [edi], '0'
        inc edi
        jmp DW_Done
    .endif
DW_Div:
    xor edx, edx
    div ecx
    add dl, '0'
    push edx
    inc ebx
    .if eax > 0
        jmp DW_Div
    .endif
DW_Pop:
    pop eax
    mov [edi], al
    inc edi
    dec ebx
    .if ebx > 0
        jmp DW_Pop
    .endif
DW_Done:
    mov eax, edi
    sub eax, pBuf
    ret
DbgW endp

; ------------------------------------------------------------
; UT_QuitToMenu -- 从暂停/对局退出到主菜单（联机时断开重置）
; ------------------------------------------------------------
UT_QuitToMenu proc
    mov pauseMode, 0
    mov matchOver, 0
    mov gameState, ST_MENU
    .if netMode != 0
        invoke NetShutdown
        mov netMode, 0
        invoke NetInit
        mov peerKnown, 0
    .endif
    ret
UT_QuitToMenu endp

; ------------------------------------------------------------
; UiTick -- 每逻辑 tick 调用
; ------------------------------------------------------------
UiTick proc uses ebx esi edi
    local upE:dword, dnE:dword, ltE:dword, rtE:dword
    local enE:dword, esE:dword, scanVk:dword
    local lbE:dword

    ; ---- 鼠标采样 ----
    ; hover 位置用 GetCursorPos（尽力而为，多屏 DPI 下仅作视觉提示）；
    ; 点击判定用 WndProc 的 WM_LBUTTONDOWN 消息坐标（DPI/多屏恒正确）
    invoke GetCursorPos, addr mousePt
    invoke ScreenToClient, hWnd, addr mousePt
    mov eax, mousePt.x
    mov mouseX, eax
    mov eax, mousePt.y
    mov mouseY, eax
    mov eax, clickEvt
    mov lbE, eax
    mov clickEvt, 0
    .if lbE != 0
        mov eax, clickPX
        mov mouseX, eax
        mov eax, clickPY
        mov mouseY, eax
    .endif

    invoke KeyEdge, VK_UP, addr prevUp
    mov upE, eax
    invoke KeyEdge, VK_DOWN, addr prevDown
    mov dnE, eax
    invoke KeyEdge, VK_LEFT, addr prevLeft
    mov ltE, eax
    invoke KeyEdge, VK_RIGHT, addr prevRight
    mov rtE, eax
    invoke KeyEdge, VK_RETURN, addr prevEnter
    mov enE, eax
    invoke KeyEdge, VK_ESCAPE, addr prevEsc
    mov esE, eax

    ; ---------- 对局中：Esc 暂停 / 比赛结束回菜单 ----------
    .if gameState == ST_PLAY
        ; 倒计时（pauseMode==2）：到 0 恢复对局；每秒哔一声
        mov eax, pauseMode
        .if eax == 2
            dec countT
            .if countT == 180 || countT == 120 || countT == 60
                invoke SndPlay, 4
            .endif
            .if countT == 0
                mov pauseMode, 0
            .endif
            jmp UT_Done
        .endif
        ; 暂停菜单（pauseMode==1）—— 直接用已采样的边沿变量
        .if eax == 1
            .if upE != 0
                dec pauseSel
                cmp pauseSel, 0
                jge PS_UpOk
                mov pauseSel, 3            ; 环绕（勿写 < 0：无符号恒假）
PS_UpOk:
            .endif
            .if dnE != 0
                inc pauseSel
                .if pauseSel > 3
                    mov pauseSel, 0
                .endif
            .endif
            ; 音量：暂停中 ←→ 直接调节
            .if ltE != 0
                sub volumeLvl, 5
                cmp volumeLvl, 0
                jge PS_VlOk
                mov volumeLvl, 0
PS_VlOk:
                invoke SndVolume, volumeLvl
            .endif
            .if rtE != 0
                add volumeLvl, 5
                .if volumeLvl > 100
                    mov volumeLvl, 100
                .endif
                invoke SndVolume, volumeLvl
            .endif
            .if enE != 0
                .if pauseSel == 0
                    mov pauseMode, 2           ; 继续 -> 3s 倒计时
                    mov countT, 180
                .elseif pauseSel == 2
                    xor sfxOn, 1               ; 音效开关
                .elseif pauseSel == 3
                    call UT_QuitToMenu
                .else
                    mov pauseMode, 2           ; 选中音量行回车 = 直接继续
                    mov countT, 180
                .endif
            .endif
            .if lbE != 0
                ; 菜单项区域：x 420..600，项 y 300+idx*44 .. +38
                mov eax, mouseX
                .if eax >= 420 && eax < 600
                    mov eax, mouseY
                    sub eax, 300
                    .if eax >= 0
                        xor edx, edx
                        mov ecx, 44
                        div ecx                ; eax = 项号
                        .if eax <= 3
                            mov pauseSel, eax
                            .if eax == 0 || eax == 1
                                mov pauseMode, 2
                                mov countT, 180
                            .elseif eax == 2
                                xor sfxOn, 1
                            .else
                                call UT_QuitToMenu
                            .endif
                        .endif
                    .endif
                .endif
            .endif
            jmp UT_Done
        .endif
        ; 打满局数：Enter/Esc 回主菜单（用采样变量）
        mov eax, matchOver
        .if eax != 0
            .if enE != 0 || esE != 0
                mov matchOver, 0
                mov gameState, ST_MENU
            .endif
            jmp UT_Done
        .endif
        ; Esc -> 暂停
        .if esE != 0
            mov pauseMode, 1
            mov pauseSel, 0
        .endif
        jmp UT_Done
    .endif

    ; ---------- 主菜单 ----------
    .if gameState == ST_MENU
        .if dnE != 0
            inc menuSel
            .if menuSel > 4
                mov menuSel, 0
            .endif
        .endif
        .if upE != 0
            .if menuSel == 0
                mov menuSel, 4
            .else
                dec menuSel
            .endif
        .endif
        .if enE != 0
            invoke MenuActivate
        .endif
        ; ---- 鼠标：悬停高亮 + 左键点击激活 ----
        ; 菜单 5 项渲染矩形：x 440..660，y = 250+i*60 .. +34
        xor ebx, ebx
UT_MMouse:
        .if ebx >= 5
            jmp UT_MMouseDone
        .endif
        mov eax, ebx
        imul eax, eax, 60
        add eax, 250
        mov ecx, eax                     ; ecx = 项顶部 y
        add eax, 34                      ; eax = 项底部 y
        .if mouseY >= ecx && mouseY < eax && mouseX >= 440 && mouseX < 660
            mov eax, ebx
            mov menuSel, eax             ; 悬停即选中（高亮联动）
            .if lbE != 0
                invoke MenuActivate      ; 点击激活
                jmp UT_MMouseDone        ; 状态可能已切换
            .endif
        .endif
        inc ebx
        jmp UT_MMouse
UT_MMouseDone:

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
        ; ---- 玩家名编辑：点击容器标题进入；字符输入；Enter/Esc 确认 ----
        ; （Enter 用采样变量 enE——KeyEdge 边沿已被开头采样消费，二次调用恒 0）
        .if editSlot != -1
            inc blinkTick
            .if enE != 0
                mov editSlot, -1
            .else
                invoke GetAsyncKeyState, VK_ESCAPE
                and eax, 8000h
                .if eax != 0
                    mov editSlot, -1
                .else
                    invoke GetAsyncKeyState, VK_BACK
                    and eax, 1
                    .if eax != 0
                        ; 删尾字符
                        mov eax, editSlot
                        imul eax, eax, 16
                        add eax, offset playerName
                        mov edi, eax
                        xor ecx, ecx
UTN_BLen:
                        cmp byte ptr [edi+ecx], 0
                        je UTN_BCut
                        inc ecx
                        .if ecx < 14
                            jmp UTN_BLen
                        .endif
UTN_BCut:
                        .if ecx > 0
                            mov byte ptr [edi+ecx-1], 0
                        .endif
                    .endif
                    ; 可打印字符 0x20..0x5A（空格/数字/大写字母），0x1 边沿位
                    mov scanVk, 20h
UTN_Scan:
                    mov eax, scanVk
                    .if eax >= 5Bh
                        jmp UTN_ScanDone
                    .endif
                    invoke GetAsyncKeyState, eax
                    and eax, 1
                    .if eax != 0
                        mov eax, editSlot
                        imul eax, eax, 16
                        add eax, offset playerName
                        mov edi, eax
                        xor ecx, ecx
UTN_Len:
                        cmp byte ptr [edi+ecx], 0
                        je UTN_Append
                        inc ecx
                        .if ecx < 14
                            jmp UTN_Len
                        .endif
UTN_Append:
                        .if ecx < 12
                            mov edx, scanVk
                            mov [edi+ecx], dl
                            mov byte ptr [edi+ecx+1], 0
                        .endif
                    .endif
                    inc scanVk
                    jmp UTN_Scan
UTN_ScanDone:
                .endif
            .endif
            jmp UT_Done              ; 编辑改名中：屏蔽本页其他操作
        .endif
        ; 人数变少时改键目标可能指向已隐藏的容器 -> 清理
        mov eax, numSel
        imul eax, eax, KEY_PER
        .if rebindSlot >= eax
            mov rebindSlot, -1
        .endif
        .if rebindSlot != -1
            ; ---- 改键等待：目标键位闪烁，按新键完成（冲突拒绝），Esc 取消 ----
            inc blinkTick
            .if esE != 0
                mov rebindSlot, -1
            .else
                ; 改键扫描：0x8000 电平（0x1 边沿位在焦点切换时不可靠），
                ; 范围收窄 0x08..0x5A / 0x60..0x87 / 0xA0..0xA5 —— 排除
                ; 鼠标键、Win/IME 保留区（0x85 误绑问题），Esc=取消专用；
                ; 进入等待后 3 tick 冷却（rebindCool）防点击残键误捕获
                .if rebindCool > 0
                    dec rebindCool
                    jmp UT_Scan2Done
                .endif
                mov scanVk, 08h
UT_Scan2:
                mov eax, scanVk
                .if eax > 0A5h
                    jmp UT_Scan2Done
                .endif
                .if eax == 1Bh                 ; Esc = 取消专用，不捕获
                    jmp UT_Scan2Next
                .endif
                .if eax > 5Ah && eax < 60h     ; Win 键区跳过
                    jmp UT_Scan2Next
                .endif
                .if eax > 87h && eax < 0A0h    ; 保留/IME 区跳过
                    jmp UT_Scan2Next
                .endif
                invoke GetAsyncKeyState, eax
                and eax, 8000h
                .if eax != 0
                    ; 冲突校验：不得与其他任何槽位的键相同
                    mov edx, scanVk
                    xor ebx, ebx
UT_Conf:
                    .if ebx >= MAX_PLAYERS*KEY_PER
                        ; 无冲突：写入并结束等待
                        mov eax, rebindSlot
                        mov keyTable[eax*4], edx
                        mov rebindSlot, -1
                        jmp UT_Scan2Done
                    .endif
                    .if ebx != rebindSlot
                        mov eax, keyTable[ebx*4]
                        .if eax == edx
                            jmp UT_Scan2Done     ; 冲突：保持闪烁等待换键
                        .endif
                    .endif
                    inc ebx
                    jmp UT_Conf
                .endif
UT_Scan2Next:
                inc scanVk
                jmp UT_Scan2
UT_Scan2Done:
            .endif
            ; 等待中允许点击其他键位行切换目标 / 点重置按钮
            .if lbE != 0
                mov eax, mouseX
                mov dbgMX, eax
                mov eax, mouseY
                mov dbgMY, eax
                invoke NumSelHitTest
                mov dbgRet, eax                   ; DBG
                test eax, eax
                js UTW_Next                ; 负值（重置/标题）不走切换
                .if eax != rebindSlot
                    mov rebindSlot, eax
                    mov rebindCool, 3      ; 切换目标：冷却防残键误捕
                .endif
UTW_Next:
                .if eax == -2
                    invoke InitKeyDefaults
                    mov rebindSlot, -1
                .endif
            .endif
        .else
            ; ---- 常规键盘操作（保留） ----
            .if rtE != 0
                inc numSel
                .if numSel > 4
                    mov numSel, 2
                .endif
            .endif
            .if ltE != 0
                dec numSel
                .if numSel < 2
                    mov numSel, 4
                .endif
            .endif
            .if enE != 0
                mov eax, numSel
                mov numPlayers, eax
                mov eax, roundsSel
                mov maxRounds, eax
                invoke GameInit
                mov netMode, 0
                mov gameState, ST_PLAY
            .endif
            .if esE != 0
                mov gameState, ST_MENU
            .endif
            ; ---- 鼠标：键位容器改键 / 重置 / << >> 调人数与局数 / 数字区开始 ----
            .if lbE != 0
                mov eax, mouseX
                mov dbgMX, eax
                mov eax, mouseY
                mov dbgMY, eax
                invoke NumSelHitTest
                mov dbgRet, eax                   ; DBG
                test eax, eax
                js NHT_NegRet              ; 负值：重置/改名（勿写 >= 0：恒真）
                mov rebindSlot, eax        ; 点击键位 -> 闪烁等待新键
                mov rebindCool, 3          ; 冷却防点击残键误捕
                jmp NHT_Done
NHT_NegRet:
                .if eax == -2
                    invoke InitKeyDefaults ; 重置所有更改按键
                    mov rebindSlot, -1
                .elseif eax == -1
                    jmp NHT_Done2          ; 无命中 -> 落到 << >> / 开始区域
                .else
                    neg eax                ; -3-slot -> slot
                    sub eax, 3
                    mov editSlot, eax      ; 点击容器标题 -> 改名
                .endif
                jmp NHT_Done
NHT_Done2:
                ; PLAYERS << 400..460, y190..242
                mov eax, mouseX
                .if eax >= 400 && eax < 460 && mouseY >= 190 && mouseY < 242
                    dec numSel
                    .if numSel < 2
                        mov numSel, 4
                    .endif
                ; PLAYERS >> 535..600, y190..242
                .elseif eax >= 535 && eax < 600 && mouseY >= 190 && mouseY < 242
                    inc numSel
                    .if numSel > 4
                        mov numSel, 2
                    .endif
                ; ROUNDS << 400..460, y252..304
                .elseif eax >= 400 && eax < 460 && mouseY >= 252 && mouseY < 304
                    sub roundsSel, 2
                    .if roundsSel < ROUNDS_MIN
                        mov roundsSel, ROUNDS_MAX
                    .endif
                ; ROUNDS >> 535..600, y252..304
                .elseif eax >= 535 && eax < 600 && mouseY >= 252 && mouseY < 304
                    add roundsSel, 2
                    .if roundsSel > ROUNDS_MAX
                        mov roundsSel, ROUNDS_MIN
                    .endif
                ; 人数数字区 465..530, y180..242 -> 确认开始
                .elseif eax >= 465 && eax < 530 && mouseY >= 180 && mouseY < 242
                    mov eax, numSel
                    mov numPlayers, eax
                    mov eax, roundsSel
                    mov maxRounds, eax
                    invoke GameInit
                    mov netMode, 0
                    mov gameState, ST_PLAY
                .endif
NHT_Done:
            .endif
        .endif

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        ; ---- 音量（←→）/ 音效 / 深夜模式 快捷设置 ----
        .if ltE != 0
            sub volumeLvl, 5
            cmp volumeLvl, 0
            jge SS_Vl1
            mov volumeLvl, 0
SS_Vl1:
            invoke SndVolume, volumeLvl
        .endif
        .if rtE != 0
            add volumeLvl, 5
            .if volumeLvl > 100
                mov volumeLvl, 100
            .endif
            invoke SndVolume, volumeLvl
        .endif
        .if lbE != 0 && mouseY >= 88 && mouseY < 114
            mov eax, mouseX
            .if eax >= 330 && eax < 400
                sub volumeLvl, 10
                cmp volumeLvl, 0
                jge SS_Vl2
                mov volumeLvl, 0
SS_Vl2:
                invoke SndVolume, volumeLvl
            .elseif eax >= 402 && eax < 472
                add volumeLvl, 10
                .if volumeLvl > 100
                    mov volumeLvl, 100
                .endif
                invoke SndVolume, volumeLvl
            .elseif eax >= 500 && eax < 560
                xor sfxOn, 1
            .elseif eax >= 600 && eax < 760
                xor themeNight, 1
            .endif
        .endif
        .if rebindWait != 0
            .if esE != 0
                mov rebindWait, 0
            .else
                ; 扫描同人数页：0x8000 电平 + 收窄范围（排 Esc/Win/IME/鼠标）；
                ; 进入重绑由回车触发，起点 0x20 已排除 Enter，无需冷却
                mov scanVk, 20h
UT_Scan:
                mov eax, scanVk
                .if eax > 0A5h
                    jmp UT_ScanDone
                .endif
                .if eax == 1Bh
                    jmp UT_ScanNext
                .endif
                .if eax > 5Ah && eax < 60h
                    jmp UT_ScanNext
                .endif
                .if eax > 87h && eax < 0A0h
                    jmp UT_ScanNext
                .endif
                invoke GetAsyncKeyState, eax
                and eax, 8000h
                .if eax != 0
                    mov eax, scanVk
                    mov edx, setSel
                    mov keyTable[edx*4], eax
                    mov rebindWait, 0
                    jmp UT_ScanDone
                .endif
UT_ScanNext:
                inc scanVk
                jmp UT_Scan
UT_ScanDone:
            .endif
        .else
            .if dnE != 0
                inc setSel
                .if setSel > MAX_PLAYERS*KEY_PER-1
                    mov setSel, 0
                .endif
            .endif
            .if upE != 0
                .if setSel == 0
                    mov setSel, MAX_PLAYERS*KEY_PER-1
                .else
                    dec setSel
                .endif
            .endif
            .if enE != 0
                mov rebindWait, 1
            .endif
            .if esE != 0
                mov gameState, ST_MENU
            .endif
        .endif

    ; ---------- 联机大厅 ----------
    .elseif gameState == ST_LAN
        inc discTimer
        .if discTimer >= 30
            mov discTimer, 0
            mov bcastAddr.sin_family, AF_INET
            invoke htons, 28888
            mov bcastAddr.sin_port, ax
            mov bcastAddr.sin_addr, INADDR_BROADCAST
            invoke sendto, hSock, offset discBuf, 7, 0,
                   addr bcastAddr, SIZEOF sockaddr_in
        .endif
        mov discLen, SIZEOF sockaddr_in
        invoke recvfrom, hSock, offset recvTmp, 64, 0,
               addr discFrom, addr discLen
        .if eax >= 7
            mov eax, dword ptr recvTmp[0]
            .if eax == 454E5754h               ; "TWNE" (小端)
                cmp byte ptr recvTmp[4], 'T'   ; "T01" 的 'T'
                .if ZERO?
                    invoke StrCopy, addr discFrom, addr peerAddr, 16
                    mov peerKnown, 1
                    invoke IpToStr, addr peerAddr.sin_addr, offset peerIpBuf
                    mov peerIpLen, eax
                .endif
            .endif
        .endif
        .if enE != 0 && peerKnown != 0
            mov numPlayers, 2
            invoke GameInit
            mov netMode, 1
            mov gameState, ST_PLAY
        .endif
        .if esE != 0
            invoke NetShutdown
            mov peerKnown, 0
            mov gameState, ST_MENU
        .endif
    .endif
UT_Done:
    ret
UiTick endp

; ------------------------------------------------------------
; UiRender -- 按状态绘制；对局中委托 GfxRender
; ------------------------------------------------------------
UiRender proc uses ebx esi edi
    local rc:RECT
    local boxRc:RECT
    local rowY:dword
    local txtLen:dword
    local klen:dword
    local rowCol:dword
    local slotIdx:dword

    mov rc.left, 0
    mov rc.top, 0
    mov rc.right, WND_W
    mov rc.bottom, WND_H
    ; 深夜模式：背景近黑 + 文字浅色重映射
    mov eax, themeNight
    .if eax != 0
        invoke FillRect, hdcBack, addr rc, brushNight
        mov colDark, 00D0D0D0h
        mov colGray, 00808080h
        mov colHi,   0000E0E0h
        mov eax, boxBrushN
        mov boxCur, eax
    .else
        invoke FillRect, hdcBack, addr rc, menuBrush
        mov colDark, 00232323h
        mov colGray, 00606060h
        mov colHi,   0000C06000h
        mov eax, boxBrush
        mov boxCur, eax
    .endif
    invoke SelectObject, hdcBack, menuFont
    mov fontOld, eax

    .if gameState == ST_PLAY
        invoke GfxRender
        jmp UR_Done
    .endif

    ; ---------- 主菜单 ----------
    .if gameState == ST_MENU
        invoke UiTextZ, hdcBack, 385, 90, offset szTitle, colDark
        mov ebx, 0
UM_Items:
        .if ebx == menuSel
            mov edx, colHi
        .else
            mov edx, colGray
        .endif
        mov eax, ebx
        imul eax, eax, 60
        add eax, 250
        mov rowY, eax
        push ebx
        mov eax, ebx
        .if eax == 0
            invoke UiTextL, hdcBack, 440, rowY, offset szItem1, offset CN_START, edx
        .elseif eax == 1
            invoke UiTextL, hdcBack, 440, rowY, offset szItem2, offset CN_SET, edx
        .elseif eax == 2
            invoke UiTextL, hdcBack, 440, rowY, offset szItem3, offset CN_LAN, edx
        .elseif eax == 3
            invoke UiTextL, hdcBack, 440, rowY, offset szItem4, offset CN_EXIT, edx
        .else
            invoke UiTextL, hdcBack, 440, rowY, offset szLangEN, offset CN_LANG, edx
        .endif
        pop ebx
        inc ebx
        .if ebx < 5
            jmp UM_Items
        .endif

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
        invoke UiTextL, hdcBack, 420, 150, offset szNumT, offset CN_NUMT, colDark
        ; PLAYERS 行（y 190..242）
        invoke UiTextZ, hdcBack, 410, 200, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 545, 200, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, numSel
        add eax, '0'
        mov [edi], al
        mov byte ptr [edi+1], 0
        invoke UiTextZ, hdcBack, 485, 192, offset uiBuf, 000000D0h
        ; ROUNDS 行（y 252..304）
        invoke UiTextL, hdcBack, 322, 262, offset szRounds, offset CN_ROUNDS, colDark
        invoke UiTextZ, hdcBack, 410, 262, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 545, 262, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, roundsSel
        xor edx, edx
        mov ecx, 10
        div ecx                          ; eax=十位 edx=个位
        add eax, '0'
        add edx, '0'
        mov [edi], al
        mov [edi+1], dl
        mov byte ptr [edi+2], 0
        invoke UiTextZ, hdcBack, 480, 254, offset uiBuf, 000000D0h

        ; ---- 键位容器（小字体）：按当前选择的人数显示 2..4 个 ----
        invoke SelectObject, hdcBack, fontSmall
        invoke UiTextL, hdcBack, 30, 306, offset szKeysLbl, offset CN_KEYS, colGray
        xor ebx, ebx
NS_Box:
        .if ebx >= numSel
            jmp NS_BoxDone
        .endif
        ; 容器边框
        mov eax, ebx
        imul eax, eax, KBBOX_DX
        add eax, KBBOX_X0
        mov boxRc.left, eax
        add eax, KBBOX_W
        mov boxRc.right, eax
        mov eax, KBBOX_Y
        mov boxRc.top, eax
        add eax, KBBOX_H
        mov boxRc.bottom, eax
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        ; 容器标题：玩家名（可点击改名；编辑中光标 '_' 闪烁）
        mov eax, ebx
        imul eax, eax, 16
        add eax, offset playerName
        lea edi, uiBuf
        xor ecx, ecx
NT_Copy:
        mov dl, [eax+ecx]
        .if dl == 0
            jmp NT_Copied
        .endif
        mov [edi+ecx], dl
        inc ecx
        .if ecx < 14
            jmp NT_Copy
        .endif
NT_Copied:
        .if ebx == editSlot
            mov eax, blinkTick
            shr eax, 3
            and eax, 1
            .if eax != 0
                mov byte ptr [edi+ecx], '_'
                inc ecx
            .endif
        .endif
        mov byte ptr [edi+ecx], 0
        invoke UiTextZ, hdcBack, boxRc.left, KBBOX_Y+8, offset uiBuf, colDark
        ; 5 行键位：0上 1下 2左 3右 4开火 5技能
        mov rowY, KBBOX_Y + KBROW_Y0
        xor esi, esi                     ; 动作 0..5
NS_Row:
        .if esi >= KEY_PER
            inc ebx
            jmp NS_Box
        .endif
        mov eax, ebx
        imul eax, eax, KEY_PER
        add eax, esi
        mov slotIdx, eax
        ; 颜色：改键中的槽位闪烁；悬停高亮；其余灰
        mov eax, slotIdx
        .if eax == rebindSlot
            mov eax, blinkTick
            shr eax, 3
            and eax, 1
            .if eax != 0
                mov eax, colHi
                mov rowCol, eax
            .else
                mov eax, colDark
                mov rowCol, eax
            .endif
        .else
            mov eax, boxRc.left
            add eax, 8
            mov ecx, boxRc.right
            sub ecx, 8
            mov edi, rowY
            mov edx, edi
            add edx, KBROW_DH - 4
            .if mouseX >= eax && mouseX < ecx && mouseY >= edi && mouseY < edx
                mov eax, colHi
                mov rowCol, eax
            .else
                mov eax, colGray
                mov rowCol, eax
            .endif
        .endif
        ; 动作名（语言感知）
        mov eax, esi
        mov edx, aTab[eax*4]             ; 英文动作名指针
        mov eax, esi
        mov ecx, cnActT[eax*4]           ; 中文动作名指针
        invoke UiTextL, hdcBack, boxRc.left, rowY, edx, ecx, rowCol
        ; 键名（VkName -> uiBuf）
        mov eax, slotIdx
        mov eax, keyTable[eax*4]
        invoke VkName, eax, offset uiBuf
        mov byte ptr uiBuf[eax], 0
        mov eax, boxRc.left
        add eax, 120
        invoke UiTextZ, hdcBack, eax, rowY, offset uiBuf, rowCol
        add rowY, KBROW_DH
        inc esi
        jmp NS_Row
NS_BoxDone:
        ; ---- 重置按钮（容器区右下角）----
        mov eax, mouseX
        .if eax >= RST_X && eax < RST_X+RST_W && mouseY >= RST_Y && mouseY < RST_Y+RST_H
            mov edx, colHi
        .else
            mov edx, colDark
        .endif
        mov boxRc.left, RST_X-10
        mov boxRc.top, RST_Y-4
        mov boxRc.right, RST_X+RST_W+8
        mov boxRc.bottom, RST_Y+RST_H+4
        invoke FrameRect, hdcBack, addr boxRc, boxCur
        invoke UiTextL, hdcBack, RST_X, RST_Y, offset szReset, offset CN_RESET, edx
        ; ---- 底部提示：改键等待时显示引导，否则显示操作提示 ----
        .if rebindSlot != -1
            invoke UiTextL, hdcBack, 360, 600, offset szReb2, offset CN_REB2, colHi
        .elseif editSlot != -1
            invoke UiTextL, hdcBack, 350, 600, offset szNameEdit, offset CN_NAMEEDIT, colHi
        .else
            invoke UiTextL, hdcBack, 330, 600, offset szHint, offset CN_HINT, colGray
            invoke UiTextL, hdcBack, 620, 600, offset szNameHint, offset CN_NAMEHINT, colGray
        .endif
        invoke SelectObject, hdcBack, menuFont

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        invoke UiTextL, hdcBack, 420, 36, offset szSetT, offset CN_SETT, colDark
        invoke UiTextL, hdcBack, 380, 74, offset szSetH, offset CN_SETH, colGray
        ; ---- 快捷设置行（小字体，y 96）：音量 / 音效 / 深夜模式 ----
        invoke SelectObject, hdcBack, fontSmall
        invoke UiTextL, hdcBack, 240, 96, offset szVol2, offset CN_VOL2, colDark
        lea edi, uiBuf
        mov eax, volumeLvl
        xor edx, edx
        mov ecx, 10
        div ecx
        add al, '0'
        add dl, '0'
        mov [edi], al
        mov [edi+1], dl
        mov byte ptr [edi+2], '%'
        mov byte ptr [edi+3], 0
        invoke UiTextZ, hdcBack, 330, 96, offset uiBuf, colDark
        invoke UiTextL, hdcBack, 430, 96, offset szSfx2, offset CN_SFX, colDark
        mov eax, sfxOn
        .if eax != 0
            invoke UiTextL, hdcBack, 500, 96, offset szOn2, offset CN_ON2, colDark
        .else
            invoke UiTextL, hdcBack, 500, 96, offset szOff2, offset CN_OFF2, colDark
        .endif
        invoke UiTextL, hdcBack, 600, 96, offset szNight, offset CN_NIGHT, colDark
        mov eax, themeNight
        .if eax != 0
            invoke UiTextL, hdcBack, 700, 96, offset szOn2, offset CN_ON2, colDark
        .else
            invoke UiTextL, hdcBack, 700, 96, offset szOff2, offset CN_OFF2, colDark
        .endif
        invoke SelectObject, hdcBack, menuFont

        xor ebx, ebx
SS_Rows:
        .if ebx >= MAX_PLAYERS*KEY_PER
            jmp SS_Done
        .endif
        ; 行文本（宽字符）: "P<p+1> <ACTION> : <KEY>"
        lea edi, wBuf
        mov word ptr [edi], 'P'
        mov eax, ebx
        xor edx, edx
        mov ecx, KEY_PER
        div ecx
        add al, '1'
        mov [edi+2], ax                 ; '1'..'4'（宽）
        mov word ptr [edi+4], ' '
        add edi, 6
        .if langFlag == 0
            mov esi, aTab[edx*4]        ; 英文动作名（ASCII -> 宽）
SS_CopyAct:
            mov al, [esi]
            .if al == 0
                jmp SS_CopyDone
            .endif
            movzx eax, al
            mov [edi], ax
            inc esi
            add edi, 2
            jmp SS_CopyAct
SS_CopyDone:
        .else
            mov esi, cnActT[edx*4]      ; 中文动作名（等长指针表，0 结尾）
CN_CopyAct:
            mov ax, [esi]
            .if ax == 0
                jmp SS_CopyDone2
            .endif
            mov [edi], ax
            add esi, 2
            add edi, 2
            jmp CN_CopyAct
SS_CopyDone2:
        .endif
        mov word ptr [edi], ' '
        mov word ptr [edi+2], ':'
        mov word ptr [edi+4], ' '
        add edi, 6
        ; 键名：VkName 生成 ASCII 到 uiBuf，再转宽
        mov eax, ebx
        mov eax, keyTable[eax*4]
        invoke VkName, eax, offset uiBuf
        mov klen, eax
        xor ecx, ecx
KN_Loop:
        .if ecx >= klen
            jmp KN_Done
        .endif
        movzx eax, byte ptr uiBuf[ecx]
        mov [edi], ax
        inc ecx
        add edi, 2
        jmp KN_Loop
KN_Done:
        ; 重绑提示（仅选中行）
        .if rebindWait != 0 && ebx == setSel
            .if langFlag == 0
                invoke StrCopy, offset szRebind, edi, 17
                mov word ptr [edi+17], 0
                add edi, 18
            .else
                invoke StrCopy, offset CN_REBIND, edi, 18
                mov word ptr [edi+18], 0
                add edi, 20
            .endif
        .endif
        mov word ptr [edi], 0
        ; 颜色与行坐标
        mov eax, ebx
        .if eax == setSel
            mov edx, colHi
        .else
            mov edx, colGray
        .endif
        mov eax, ebx
        imul eax, eax, 26                 ; 行高 26（20 行 110..614 不溢出）
        add eax, 110
        mov rowY, eax
        invoke UiTextW, hdcBack, 380, rowY, offset wBuf, edx
        inc ebx
        jmp SS_Rows
SS_Done:

    ; ---------- 联机大厅 ----------
    .elseif gameState == ST_LAN
        invoke UiTextL, hdcBack, 440, 130, offset szLanT, offset CN_LANT, colDark
        invoke UiTextL, hdcBack, 350, 220, offset szLanB, offset CN_LANB, colGray
        .if peerKnown != 0
            invoke UiTextL, hdcBack, 350, 280, offset szLanF, offset CN_LANF, colFound
            invoke UiTextZ, hdcBack, 530, 280, offset peerIpBuf, colFound
        .else
            invoke UiTextL, hdcBack, 350, 280, offset szLanN, offset CN_LANN, colGray
        .endif
        invoke UiTextL, hdcBack, 350, 360, offset szLanS, offset CN_LANS, colDark
    .endif

UR_Done:
    invoke SelectObject, hdcBack, fontOld
    invoke GetDC, hWnd
    mov hdcWin2, eax
    invoke BitBlt, hdcWin2, 0, 0, WND_W, WND_H, hdcBack, 0, 0, SRCCOPY
    invoke ReleaseDC, hWnd, hdcWin2
    ret
UiRender endp

end
