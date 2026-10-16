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
public langFlag
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
extern peerAddr  :sockaddr_in
extern peerKnown :dword
extern hSock     :dword

; win32.inc 未收录的鼠标 API 原型与常量
VK_LBUTTON     equ 001h
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
    boxBrush    dd ?                   ; 容器边框画刷（深灰）
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
    szReset     db "RESET ALL KEYS", 0
    szReb2      db "PRESS ANY KEY ... (ESC = CANCEL)", 0
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
    CN_RESET dw 91cdh,7f6eh,6240h,6709h,66f4h,6539h,6309h,952eh, 0        ; 重置所有更改按键
    CN_REB2 dw 8bf7h,6309h,4efbh,610fh,952eh,0ff08h,0045h,0073h,0063h,0020h,003dh,0020h,53d6h,6d88h,0ff09h, 0 ; 请按任意键（Esc = 取消）
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
    invoke CreateSolidBrush, 00232323h
    mov boxBrush, eax
    invoke CreateFontA, 30, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov menuFont, eax
    invoke CreateFontA, 18, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov fontSmall, eax
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
; 返回 eax: 0..19 = 键位槽位（slot*5+动作），-2 = 重置按钮，-1 = 无
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

; ------------------------------------------------------------
; UiTick -- 每逻辑 tick 调用
; ------------------------------------------------------------
UiTick proc uses ebx esi edi
    local upE:dword, dnE:dword, ltE:dword, rtE:dword
    local enE:dword, esE:dword, scanVk:dword
    local lbE:dword

    ; ---------- 对局中：Esc 暂停 / 比赛结束回菜单 ----------
    .if gameState == ST_PLAY
        ; 打满局数：Enter/Esc 回主菜单
        mov eax, matchOver
        .if eax != 0
            invoke KeyEdge, VK_RETURN, addr prevEnter
            mov ecx, eax
            invoke KeyEdge, VK_ESCAPE, addr prevEsc
            .if ecx != 0 || eax != 0
                mov matchOver, 0
                mov gameState, ST_MENU
            .endif
            jmp UT_Done
        .endif
        invoke KeyEdge, VK_ESCAPE, addr prevEsc
        .if eax != 0
            mov gameState, ST_MENU
            .if netMode != 0
                invoke NetShutdown
                mov netMode, 0
                invoke NetInit
                mov peerKnown, 0
            .endif
        .endif
        jmp UT_Done
    .endif

    ; ---- 鼠标采样（菜单界面用）：客户区坐标 + 左键点击边沿 ----
    invoke GetCursorPos, addr mousePt
    invoke ScreenToClient, hWnd, addr mousePt
    mov eax, mousePt.x
    mov mouseX, eax
    mov eax, mousePt.y
    mov mouseY, eax
    invoke KeyEdge, VK_LBUTTON, addr prevLBtn
    mov lbE, eax

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
                ; 扫描 0x08..0xFF（含 Enter/方向键；跳过 Esc；鼠标键 < 0x08 不会误触）
                mov scanVk, 08h
UT_Scan2:
                mov eax, scanVk
                .if eax >= 100h
                    jmp UT_Scan2Done
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
                inc scanVk
                jmp UT_Scan2
UT_Scan2Done:
            .endif
            ; 等待中允许点击其他键位行切换目标 / 点重置按钮
            .if lbE != 0
                invoke NumSelHitTest
                .if eax == -2
                    invoke InitKeyDefaults
                    mov rebindSlot, -1
                .elseif eax != -1 && eax != rebindSlot
                    mov rebindSlot, eax
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
                invoke NumSelHitTest
                .if eax >= 0
                    mov rebindSlot, eax      ; 点击键位 -> 闪烁等待新键
                .elseif eax == -2
                    invoke InitKeyDefaults   ; 重置所有更改按键
                .else
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
                .endif
            .endif
        .endif

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        .if rebindWait != 0
            invoke KeyEdge, VK_ESCAPE, addr prevEsc
            .if eax != 0
                mov rebindWait, 0
            .else
                ; 扫描 0x20..0xFF 找新按下键
                mov scanVk, 20h
UT_Scan:
                mov eax, scanVk
                .if eax >= 100h
                    jmp UT_ScanDone
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
    invoke FillRect, hdcBack, addr rc, menuBrush
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
        invoke FrameRect, hdcBack, addr boxRc, boxBrush
        ; 容器标题 P1..P4
        lea edi, uiBuf
        mov byte ptr [edi], 'P'
        mov eax, ebx
        add al, '1'
        mov [edi+1], al
        mov byte ptr [edi+2], 0
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
        invoke FrameRect, hdcBack, addr boxRc, boxBrush
        invoke UiTextL, hdcBack, RST_X, RST_Y, offset szReset, offset CN_RESET, edx
        ; ---- 底部提示：改键等待时显示引导，否则显示操作提示 ----
        .if rebindSlot != -1
            invoke UiTextL, hdcBack, 360, 600, offset szReb2, offset CN_REB2, colHi
        .else
            invoke UiTextL, hdcBack, 380, 600, offset szHint, offset CN_HINT, colGray
        .endif
        invoke SelectObject, hdcBack, menuFont

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        invoke UiTextL, hdcBack, 420, 36, offset szSetT, offset CN_SETT, colDark
        invoke UiTextL, hdcBack, 380, 74, offset szSetH, offset CN_SETH, colGray

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
        imul eax, eax, 28
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
