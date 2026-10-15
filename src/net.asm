; ============================================================
; net.asm —— 局域网 UDP 联机模块
; 模型：P2P 状态同步（见 docs/PROTOCOL.md）
;   - NetInit:   WSAStartup -> UDP socket -> bind NET_PORT
;   - NetFlush:  每 tick 由主循环调用：
;       1) 把本端坦克状态 + 开火事件打包成 NET_PKT
;       2) sendto 给对方地址（首次由对方广播/手输 IP 建立）
;       3) recvfrom 非阻塞收包，比对本端 seq 丢弃旧包，
;          把对方坦克状态覆盖写入 tanks[PLAYER_PEER]
;   - 阶段 4 增加：UDP 广播发现对方（255.255.255.255:NET_PORT）
; ============================================================

.386
.model flat, stdcall
option casemap:none

include windows.inc
include kernel32.inc
include ws2_32.inc
includelib kernel32.lib
includelib ws2_32.lib

include ..\inc\game.inc

extern tanks       :TANK
extern fireHappened :dword
extern SpawnBullet :proc

.data
    hSock       dd ?                 ; UDP socket 句柄
    localAddr   sockaddr_in <>       ; bind 用的本机地址
    peerAddr    sockaddr_in <>       ; 对方地址（联机建立后填充）
    peerKnown   dd 0                 ; 是否已知道对方地址
    wsaData     WSADATA <?>
    recvBuf     db NET_PKT_SIZE dup (0)
    sendPkt     NET_PKT <>
    fromAddr    sockaddr_in <>
    fromLen     dd SIZEOF sockaddr_in
    peerSeq     dw 0                 ; 对方最新包序号（丢弃乱序旧包）
    noBlock     dd 1                 ; FIONBIO 参数：1 = 非阻塞

.code

; ------------------------------------------------------------
; NetInit —— Winsock 初始化 + 建socket + bind
; 阶段 4 会在此处增加「等待对方广播」或「手输对方 IP」入口
; ------------------------------------------------------------
NetInit proc
    invoke WSAStartup, 0202h, addr wsaData
    .if eax != 0
        ret                          ; 初始化失败：单机模式继续跑
    .endif

    invoke socket, AF_INET, SOCK_DGRAM, IPPROTO_UDP
    .if eax == INVALID_SOCKET
        ret
    .endif
    mov hSock, eax

    ; 设为非阻塞，recvfrom 立即返回，不卡主循环
    invoke ioctlsocket, hSock, FIONBIO, addr noBlock

    ; bind 到本机所有网卡的 NET_PORT
    mov localAddr.sin_family, AF_INET
    invoke htons, NET_PORT
    mov localAddr.sin_port, ax
    mov localAddr.sin_addr, INADDR_ANY
    invoke bind, hSock, addr localAddr, SIZEOF sockaddr_in
    ret
NetInit endp

; ------------------------------------------------------------
; PackState —— 把本端状态写进 sendPkt
; ------------------------------------------------------------
PackState proc
    mov sendPkt.magic, 'WT'          ; 'T','W' 小端存放
    inc seqSelf
    mov ax, seqSelf
    mov sendPkt.seq, ax
    mov ax, word ptr tanks[PLAYER_SELF*SIZEOF TANK].x
    mov sendPkt.tx, ax
    mov ax, word ptr tanks[PLAYER_SELF*SIZEOF TANK].y
    mov sendPkt.ty, ax
    mov al, byte ptr tanks[PLAYER_SELF*SIZEOF TANK].dir
    mov sendPkt.tdir, al
    mov al, byte ptr tanks[PLAYER_SELF*SIZEOF TANK].hp
    mov sendPkt.thp, al
    mov eax, fireHappened
    mov sendPkt.flags, al
    ret
PackState endp

; ------------------------------------------------------------
; NetFlush —— 每 tick：发包 + 收包
; ------------------------------------------------------------
NetFlush proc
    ; ---- 1) 发送状态包 ----
    .if peerKnown != 0
        call PackState
        invoke sendto, hSock, addr sendPkt, NET_PKT_SIZE, 0,
               addr peerAddr, SIZEOF sockaddr_in
    .endif

    ; ---- 2) 非阻塞收包（每次可能积压多包，循环收干）----
RecvLoop:
    mov fromLen, SIZEOF sockaddr_in
    invoke recvfrom, hSock, addr recvBuf, NET_PKT_SIZE, 0,
           addr fromAddr, addr fromLen
    .if eax == SOCKET_ERROR
        jmp RecvDone                 ; 无更多包
    .endif
    ; 校验 magic
    mov ax, word ptr recvBuf[0]
    .if ax == 'WT'
        ; 丢弃乱序旧包
        movzx eax, word ptr recvBuf[2]
        movzx edx, peerSeq
        .if ax > dx
            mov peerSeq, ax
            ; 对方坦克状态直接覆盖（状态同步）
            movzx edx, word ptr recvBuf[4]
            mov tanks[PLAYER_PEER*SIZEOF TANK].x, edx
            movzx edx, word ptr recvBuf[6]
            mov tanks[PLAYER_PEER*SIZEOF TANK].y, edx
            movzx edx, byte ptr recvBuf[8]
            mov tanks[PLAYER_PEER*SIZEOF TANK].dir, edx
            movzx edx, byte ptr recvBuf[9]
            mov tanks[PLAYER_PEER*SIZEOF TANK].hp, edx
            mov tanks[PLAYER_PEER*SIZEOF TANK].alive, 1
            ; 对方本 tick 开火 -> 本地也生成一颗子弹
            movzx edx, byte ptr recvBuf[10]
            .if edx & 1
                invoke SpawnBullet, PLAYER_PEER
            .endif
        .endif
    .endif
    jmp RecvLoop
RecvDone:
    ret
NetFlush endp

; ------------------------------------------------------------
; NetShutdown —— 清理 socket
; ------------------------------------------------------------
NetShutdown proc
    invoke closesocket, hSock
    invoke WSACleanup
    ret
NetShutdown endp

end
