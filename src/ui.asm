; ============================================================
; ui.asm —— 界面状态机：主菜单 / 人数选择 / 按键设置 / 联机大厅
; 键盘操作（边沿检测防连发，导航键固定不受自定义键位影响）：
;   主菜单: ↑↓ 选择, Enter 确认
;   人数选择: ←→ 调整 2..4, Enter 开始, Esc 返回
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
public UiInit
public UiTick
public UiRender

extern hWnd      :dword
extern hdcBack   :dword
extern keyTable  :dword
GameInit  PROTO
GfxRender PROTO
NetInit   PROTO
NetFlush  PROTO
NetShutdown PROTO
extern peerAddr  :sockaddr_in
extern peerKnown :dword
extern hSock     :dword

.data
    gameState   dd ST_MENU
    numPlayers  dd 2
    netMode     dd 0                   ; 1 = 联机对局（主循环调用 NetFlush）
    menuSel     dd 0
    numSel      dd 2
    setSel      dd 0
    rebindWait  dd 0
    prevUp      dd 0
    prevDown    dd 0
    prevLeft    dd 0
    prevRight   dd 0
    prevEnter   dd 0
    prevEsc     dd 0
    prevAny     dd 0
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
    fontOld     dd ?
    bcastAddr   sockaddr_in <>
    oneVal      dd 1
    aTab        dd aUp, aDn, aLt, aRt, aFire
    aUp         db "UP", 0
    aDn         db "DOWN", 0
    aLt         db "LEFT", 0
    aRt         db "RIGHT", 0
    aFire       db "FIRE", 0
    vkUpN       db "UP", 0
    vkDnN       db "DOWN", 0
    vkLtN       db "LEFT", 0
    vkRtN       db "RIGHT", 0
    vkSpN       db "SPACE", 0
    vkEnN       db "ENTER", 0
    szTitle     db "T A N K   W A R   A S M", 0
    szItem1     db "START GAME", 0
    szItem2     db "SETTINGS", 0
    szItem3     db "LAN PLAY", 0
    szItem4     db "EXIT", 0
    szNumT      db "SELECT PLAYERS", 0
    szNumL      db "<<", 0
    szNumR      db ">>", 0
    szHint      db "ENTER: CONFIRM   ESC: BACK", 0
    szSetT      db "KEY SETTINGS", 0
    szSetH      db "ENTER: REBIND   ESC: BACK", 0
    szRebind    db " <- PRESS ANY KEY", 0
    szLanT      db "LAN PLAY", 0
    szLanB      db "BROADCASTING ON UDP PORT 28888 ...", 0
    szLanN      db "SEARCHING FOR PEERS ...", 0
    szLanF      db "PEER FOUND:", 0
    szLanS      db "ENTER: START MATCH   ESC: BACK", 0
    szFont      db "Arial", 0
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
    invoke CreateFontA, 30, 0, 0, 0, FW_NORMAL, 0, 0, 0,
           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
           DEFAULT_QUALITY, DEFAULT_PITCH, offset szFont
    mov menuFont, eax
    ret
UiInit endp

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
; UiTick -- 每逻辑 tick 调用
; ------------------------------------------------------------
UiTick proc uses ebx esi edi
    local upE:dword, dnE:dword, ltE:dword, rtE:dword
    local enE:dword, esE:dword, scanVk:dword

    ; ---------- 对局中：仅处理 Esc ----------
    .if gameState == ST_PLAY
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
            .if menuSel > 3
                mov menuSel, 0
            .endif
        .endif
        .if upE != 0
            .if menuSel == 0
                mov menuSel, 3
            .else
                dec menuSel
            .endif
        .endif
        .if enE != 0
            .if menuSel == 0
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
            .else
                invoke PostQuitMessage, NULL
            .endif
        .endif

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
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
            invoke GameInit
            mov netMode, 0
            mov gameState, ST_PLAY
        .endif
        .if esE != 0
            mov gameState, ST_MENU
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
                .if setSel > 19
                    mov setSel, 0
                .endif
            .endif
            .if upE != 0
                .if setSel == 0
                    mov setSel, 19
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
    local rowY:dword
    local txtLen:dword

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
        .if ebx == 0
            invoke UiTextZ, hdcBack, 440, rowY, offset szItem1, edx
        .elseif ebx == 1
            invoke UiTextZ, hdcBack, 440, rowY, offset szItem2, edx
        .elseif ebx == 2
            invoke UiTextZ, hdcBack, 440, rowY, offset szItem3, edx
        .else
            invoke UiTextZ, hdcBack, 440, rowY, offset szItem4, edx
        .endif
        pop ebx
        inc ebx
        .if ebx < 4
            jmp UM_Items
        .endif

    ; ---------- 人数选择 ----------
    .elseif gameState == ST_NUMSEL
        invoke UiTextZ, hdcBack, 420, 150, offset szNumT, colDark
        invoke UiTextZ, hdcBack, 410, 280, offset szNumL, colDark
        invoke UiTextZ, hdcBack, 545, 280, offset szNumR, colDark
        lea edi, uiBuf
        mov eax, numSel
        add eax, '0'
        mov [edi], al
        mov byte ptr [edi+1], 0
        invoke UiTextZ, hdcBack, 485, 272, offset uiBuf, 000000D0h
        invoke UiTextZ, hdcBack, 400, 400, offset szHint, colGray

    ; ---------- 按键设置 ----------
    .elseif gameState == ST_SET
        invoke UiTextZ, hdcBack, 420, 36, offset szSetT, colDark
        invoke UiTextZ, hdcBack, 380, 74, offset szSetH, colGray

        xor ebx, ebx
SS_Rows:
        .if ebx >= 20
            jmp SS_Done
        .endif
        ; 行文本: "P<p+1> <ACTION> : <KEY>"
        lea edi, uiBuf
        mov byte ptr [edi], 'P'
        mov eax, ebx
        xor edx, edx
        mov ecx, 5
        div ecx
        add al, '1'
        mov [edi+1], al
        mov byte ptr [edi+2], ' '
        add edi, 3
        mov esi, aTab[edx*4]            ; 动作名首址
        mov ecx, 8                      ; 上限 8 字节（名字均带 0 结尾）
SS_CopyAct:
        mov al, [esi]
        .if al == 0
            jmp SS_CopyDone
        .endif
        mov [edi], al
        inc esi
        inc edi
        dec ecx
        .if ecx != 0
            jmp SS_CopyAct
        .endif
SS_CopyDone:
        mov byte ptr [edi], ' '
        mov byte ptr [edi+1], ':'
        mov byte ptr [edi+2], ' '
        add edi, 3
        mov eax, ebx
        mov eax, keyTable[eax*4]
        invoke VkName, eax, edi
        add edi, eax
        .if rebindWait != 0 && ebx == setSel
            invoke StrCopy, offset szRebind, edi, 17
            add edi, 17
        .endif
        mov byte ptr [edi], 0
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
        invoke UiTextZ, hdcBack, 380, rowY, offset uiBuf, edx
        inc ebx
        jmp SS_Rows
SS_Done:

    ; ---------- 联机大厅 ----------
    .elseif gameState == ST_LAN
        invoke UiTextZ, hdcBack, 440, 130, offset szLanT, colDark
        invoke UiTextZ, hdcBack, 350, 220, offset szLanB, colGray
        .if peerKnown != 0
            invoke UiTextZ, hdcBack, 350, 280, offset szLanF, colFound
            invoke UiTextZ, hdcBack, 470, 280, offset peerIpBuf, colFound
        .else
            invoke UiTextZ, hdcBack, 350, 280, offset szLanN, colGray
        .endif
        invoke UiTextZ, hdcBack, 350, 360, offset szLanS, colDark
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
