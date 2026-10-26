; ============================================================
; net.asm —— UDP 联机模块 v1（会话 36 全面重写，见 docs/PROTOCOL.md）
; 模型：P2P 状态同步 + 槽主权威（对手机甲是只读镜像：死亡/伤害由
; 受害方机器结算并经 flags bit1 广播，两端各自当真；镜像上的本地
; 命中只是观测显示，会被下一包权威状态覆盖校正）。
;   - NetInit:        WSAStartup -> socket -> bind 28888；失败退临时
;                     端口并 getsockname 回读（B1：同机双开 / 端口被占
;                     都能开局；真实端口大厅展示，供跨网手输分享）
;   - NetEnterLan:    进大厅（清对端/握手状态；lobbySeed=GetTickCount
;                     兼作 cookie 与握手种子分量；socket 不重建，端口稳定）
;   - NetLobbyTick:   大厅每 tick：排空收包（'T' 探测 / 'H' 握手分流，
;                     announce 回 reply 完成"临时端口反向发现"）、
;                     announce 周期（广播+环回；手动模式改单播目标）、
;                     HELLO/START 周期重发、掉线超时
;   - NetCanStart/NetSetStart/NetEnterMatch: 双 Enter 开局（B2：
;                     netSharedSeed=两端种子异或 -> SetNetSeed -> GameInit
;                     两端同图同出生点；序号在此统一归零）
;   - NetFlush:       对局每 tick：PackState（v1 26B 全字段+事件槽3连发）
;                     发送、'L' 激光折线包 3 连发、收包交 NetApplyRx、
;                     掉线检测（netLost 期间照发照收，一包即自愈）
;   - NetApplyRx:     无 socket 依赖的收包应用器（public：selftest 直喂）
;   - ParseIp/NetSetManual: 手输 IP:端口 直连（B8，配 docs/ONLINE_PLAY.md）
;   - 会话37 M3.5 中继联机（NetSetServer/ParseServerSpec）：大厅手输行
;     "服务器ip[:端口]#房间号" -> 双方各与公网中继服务器单播，服务器按房间
;     逐字节转发既有 'T'/'H'/'W'/'L'/'P' 包（协议零改动，天然穿一切 NAT，
;     含对称 NAT；见 docs/PROTOCOL.md v1.1 + server/relay_server.c）。
;     relayMode 下 peerAddr 恒=服务器（收包不覆写），'J' 包周期续租。
;   - 会话37 RTT 显示（'P' ping/pong）：peerKnown 后 0.5s 一发，大厅行+
;     对局 HUD 显示平滑 RTT；netdump T 行末列同值。
; 包字段偏移（小端，字节）：
;   NET_PKT 26B: 0 magic('W','T') 2 seq(w) 4 tx 8 ty 12 tdir 13 thp
;     14 flags(bit0开火 bit1死亡) 15 effOnLow 16 skillId 17 evtKind
;     18 evtSeq 20 evtX(w) 22 evtY(w)=发送者tag(lobbySeed低16,防自回声) 24 evtData
;   NET_PROBE 16B: 0 sig"TWNET01" 7 ver 8 ptype 9 start(myStart) 10 port(w) 12 cookie
;     会话36：本机 LSP 会破坏 'H' 包 -> 握手状态（种子/开始位）由探测包承载
;     会话36 实测：同一 LSP 把 NET_PKT 首 dw 字节序对调上线（57 54 -> 54 57），
;     载荷不位移；NetApplyRx/NetFlush 通吃两形态（跨网正常链路收 57 54 原样）
;   NET_HS    16B: 0 'H' 1 htype 4 seed 8 rounds 12 cookie
;   NET_LSR   48B: 0 'L' 1 npts 2 len(w) 4 seq(w) 6 skill 8 px[20](w 交替)
;   NET_JOIN  16B: 0 'J' 1 jtype 2 ver 3 st 4 room(dd) 8 cookie(dd) 会话37 中继
;   NET_PING  16B: 0 'P' 1 rep 4 ts(dd) 8 cookie(dd) 会话37 RTT 探测
;   NET_STUN  18B: 0 'S' 1 ver 4 peerIp(裸网络序) 8 peerPort(裸网络序) 10 room
;     14 cookie(收件人种子) 会话51 STUN步A：服务器反射对端观测端点，仅存储+显示
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

public NetInit
public NetFlush
public NetShutdown
public NetEnterLan
public NetLobbyTick
public NetCanStart
public NetLobbyState
public NetSetStart
public NetEnterMatch
public NetSetManual
public ParseIp
public NetSetServer                ; 会话37 M3.5：中继服务器模式（ip[:port]#room）
public ParseServerSpec             ; "a.b.c.d[:p]#room" 解析（selftest 直测）
public NetResetTargets             ; 从主菜单重进大厅时清手动/中继目标
public NetApplyRx
public NetApplyPacket                 ; selftest 便捷入口（仅 NET_PKT）
public NetMirrorExtrap                ; 会话39：镜像断包外推（selftest 直测）
public netTick                        ; 会话39：外推 selftest 需要推钟
public lastRxTick
public mirVX
public mirVY
public hSock
public peerAddr
public peerKnown
public netLost
public ownPort
public isFixedPort
public netSharedSeed
public netRole
public lobbySeed
public relayMode                   ; 1=中继模式（所有包经服务器转发）
public manualMode                  ; 1=定向单播（手动直连/中继共用）
public relayRoom
public relaySt                     ; 服务器 ack 状态 JOIN_ST_*
public netRtt                      ; 最近一次 RTT ms（会话37：大厅/HUD 显示）
public netRttOk
public netRttAvg                   ; EWMA 平滑 RTT
public stunIp                      ; 会话51 STUN步A：对端观测端点（裸网络序4B，可直进 sockaddr）
public stunPort                    ; 对端观测端口（主机序数值，显示/比对用）
public stunSeen                    ; 1=收过有效 'S'（三道闸后采信）
public NetFeedJP                   ; selftest 零 socket 直喂 'J'/'P'/'S'（pBuf, len）

; ---- game.asm ----
extern tanks         :TANK
extern bullets       :BULLET
extern fireHappened  :dword
extern seqSelf       :word
extern mineCell      :dword
extern mineArm       :dword
extern mineOwner     :dword
extern pickupType    :dword
extern pickupTimer   :dword
extern evtPend       :dword
extern evtPendSeq    :dword
extern evtPendX      :dword
extern evtPendData   :dword
extern evtPendTtl    :dword
extern laserPendTtl  :dword
extern laserEvSeq    :dword
extern laserN        :dword
extern laserX        :dword
extern laserY        :dword
extern laserLen      :dword
extern laserT        :dword
extern laserOwn      :dword          ; 会话40：激光归属（导入对端折线时钉 PLAYER_PEER）
extern laserD        :dword
extern laserHitMask  :dword
extern prevTank      :dword
extern prevN         :dword
extern netDumpOn     :dword
extern maxRounds     :dword
extern mapIndex      :dword
extern rngMatch      :dword
; ---- ui.asm ----
extern netMode       :dword
extern numPlayers    :dword
extern botMask      :dword        ; bot.asm（会话39：联机开局时清人机残留）
extern onlineBanT   :dword        ; ui.asm（会话39：新局清禁用技提示残留）

SpawnBullet   PROTO stdcall :DWORD
GameInit      PROTO
UiSyncBotName PROTO                ; ui.asm（会话38：槽1名 BLACK BOT<->P2）
SetNetSeed    PROTO :DWORD
SpawnIce2x2At PROTO stdcall :DWORD,:DWORD
; ---- 本模块内部 proc 前置声明（文件内前向调用）----
NetSendProbe  PROTO :DWORD,:DWORD
NetSendHS     PROTO :DWORD
NetSendJoin   PROTO                ; 会话37：'J' 加入包（中继模式）
NetSendPing   PROTO                ; 会话37：'P' RTT 探测包
NetTickClocks PROTO                ; 会话37：JOIN 续租/RTT 探测周期钟
NetHandleJP   PROTO :DWORD         ; 会话37：'J' ack / 'P' ping 共用处理（len）
NetCheckTimeout PROTO
NetMirrorExtrap PROTO                ; 会话39：镜像断包外推
PackState     PROTO
PackLaser     PROTO
StrCopySa     PROTO :DWORD,:DWORD
DpStart       PROTO
DpByte        PROTO :DWORD
DpTok         PROTO :DWORD
DpEol         PROTO
DumpWrt       PROTO :DWORD,:DWORD
DumpNum       PROTO :DWORD,:DWORD
NetDumpEnsure PROTO
NetDumpTick   PROTO

NET_VER      equ 1
NET_ANN_MANUAL equ 15               ; 手动模式 announce 周期（更快拿到反馈）
NET_PING_TICKS equ 30               ; 会话37：RTT 探测周期 0.5s（大厅+对局）
NET_JOIN_TICKS equ 60               ; 会话37：对局中 'J' 续注册周期 1s
NET_EXTRAP_MAX equ 3                ; 会话39：镜像外推最多 3 tick（4+=冻结好于假动）
NET_EXTRAP_CAP equ 4                ; 会话39：外推速度钳位 px/tick（氮气极速≈4.3，取4保守）

.data
    hSock       dd ?
    localAddr   sockaddr_in <>
    peerAddr    sockaddr_in <>       ; 对端地址（真实源端口，含临时端口）
                                     ; 会话37 中继模式：恒=服务器地址（收包不覆写）
    peerKnown   dd 0
    wsaData     WSADATA <?>
    recvBuf     db 64 dup (0)
    sendPkt     NET_PKT <>
    sendLsr     NET_LSR <>
    probeT      NET_PROBE <>
    hsT         NET_HS <>
    joinT       NET_JOIN <>          ; 会话37：中继加入/心跳暂存
    pingT       NET_PING <>          ; 会话37：RTT 探测暂存
    fromAddr    sockaddr_in <>
    fromLen     dd SIZEOF sockaddr_in
    tmpSa       sockaddr_in <>
    tmpSaLen    dd SIZEOF sockaddr_in
    zeroAddr    sockaddr_in <>       ; bind 临时端口用（family 运行期填）
    peerSeq     dw 0
    noBlock     dd 1
    oneVal      dd 1
    bcastAddr   sockaddr_in <>
    loopAddr    sockaddr_in <>
    ownPort     dd 0                 ; 主机序；大厅展示/分享手输
    isFixedPort dd 0

    ; ---- 大厅 FSM ----
    lobbySeed     dd 0               ; cookie + 握手种子分量
    lobbyTimer    dd 0
    gotHello      dd 0
    hsPeerSeed    dd 0
    hsPeerRounds  dd 0
    gotStart      dd 0
    myStart       dd 0
    netSharedSeed dd 0
    netRole       dd 0                ; 会话36：0=A端占出生点0 1=B端（lobbySeed 大者）
    manualMode    dd 0
    manualIp      dd 0               ; 网络序
    manualPort    dd 0               ; 主机序
    ; ---- 会话37 M3.5：中继服务器模式 + RTT ----
    relayMode     dd 0               ; 1=所有包走服务器转发（peerAddr 恒=服务器）
    relayRoom     dd 0               ; 房间号 1..999999
    stunIp        dd 0               ; 会话51 STUN步A：对端公网观测 IP 裸4字节（网络序）
    stunPort      dd 0               ; 对端观测端口（主机序数值；换算=ntohs 等价）
    stunSeen      dd 0               ; 1=已收有效 'S'（大厅显示行开关）
    relaySt       dd 0               ; 服务器 ack 状态 JOIN_ST_*（0=未收到）
    relaySeen     dd 0               ; 收到过 ack（仅诊断；UI 读 relaySt）
    srvIp         dd 0               ; ParseServerSpec 输出暂存（网络序）
    srvPort       dd 0               ; 主机序
    srvTmpIp      db 32 dup (0)      ; '#' 前 IP 段拷贝（ParseIp 输入）
    srvAccS       dd 0               ; 房间号累加器（勿用 ebp，会话36 教训）
    srvCntS       dd 0               ; 房间号位数
    srvColon      dd 0               ; IP 段是否含 ':'（决定默认端口）
    netRtt        dd 0               ; 最近一次 RTT ms
    netRttOk      dd 0               ; 1=至少测出过一次（0 显示 "--"）
    netRttAvg     dd 0               ; EWMA (3/4 旧 + 1/4 新)
    lastPingTs    dd 0               ; 在飞请求时间戳（pong 认账凭据）
    pingClock     dd 0               ; 探测周期计数
    joinClock     dd 0               ; 对局 'J' 心跳周期计数
    ; 会话37：握手尾巴——本机进局后 lobby FSM 停转，若对端尚未收到本机
    ; START（客机先见主机 START 抢先开局，其带 START 的 announce 未及送达），
    ; 主机永卡 ST_LAN。进局瞬间置 hsTail，NetFlush 内每 15tick 补发一发
    ; 带 myStart 的探测包（经中继=发服务器转发），300tick(5s) 后自然收敛。
    ; 收到对端首个 W（AR_Live）或重进大厅（NetEnterLan）即清零。
    hsTail        dd 0               ; 1=尾巴活跃
    hsTailT       dd 0               ; 剩余 tick（进局置 300，递减到 0 关闭）
    hsTailC       dd 0               ; 补发节拍计数（满 15 发一发并归零）
    ; ParseIp scratch（proc 内跨段共享，避开双寄存器索引非法）
    ; 会话36 T46 回归揪出：本 proc 原把 EBP 当段累加器（xor ebp,ebp 毁 MASM
    ; 帧指针 -> 之后访问 pIp/pPort=[ebp+8] 变 [8] 空指针 AV，手输 IP 连接必崩）。
    ; 累加器改全局暂存 segAccS，proc 不再 uses ebp。
    ipAccS    dd 0
    portAccS  dd 0
    inPortS   dd 0
    digitSeen dd 0
    segAccS   dd 0

    ; ---- 对局计时/掉线 ----
    netTick     dd 0
    lastRxTick  dd 0
    rxSeen      dd 0
    netLost     dd 0
    mirVX       dd 0                 ; 会话39：镜像速度估计（断包外推源）
    mirVY       dd 0
    lastEvtSeq  dd 0
    lastLsrSeq  dd 0
    lastSentLsr dd 0                  ; 会话36：本机末次发出的激光 seq（防自回声）
    lobbyDrain  dd 0

    ; ---- 诊断转储（netloop 验收；netDumpOn=1 才创建）----
    dumpHand    dd -1
    dumpCur     dd offset dumpBuf
    dumpName    db "netdump_guest.txt", 0
    dumpNameFix db "netdump_host.txt", 0
    dumpBuf     db 1024 dup (0)
    dumpTmp     db 16 dup (0)

.code

; ------------------------------------------------------------
; StrCopySa —— sockaddr_in 16B 拷贝
; ------------------------------------------------------------
StrCopySa proc uses esi edi ecx src: dword, dst: dword
    mov esi, src
    mov edi, dst
    mov ecx, SIZEOF sockaddr_in/4
    rep movsd
    ret
StrCopySa endp

; ------------------------------------------------------------
; NetInit —— Winsock + socket + bind（B1 退避）+ 非阻塞 + SO_BROADCAST
; 进程期仅建一次（大厅进出/对局切换不重建：端口稳定才可分享手输）
; ------------------------------------------------------------
NetInit proc
    .if hSock != 0 && hSock != INVALID_SOCKET
        ret
    .endif
    invoke WSAStartup, 0202h, addr wsaData
    .if eax != 0
        ret                          ; 失败：单机模式照常跑
    .endif
    invoke socket, AF_INET, SOCK_DGRAM, IPPROTO_UDP
    .if eax == INVALID_SOCKET
        ret
    .endif
    mov hSock, eax
    invoke ioctlsocket, hSock, FIONBIO, addr noBlock
    invoke setsockopt, hSock, SOL_SOCKET, SO_BROADCAST, addr oneVal, 4
    mov localAddr.sin_family, AF_INET
    invoke htons, NET_PORT
    mov localAddr.sin_port, ax
    mov localAddr.sin_addr, INADDR_ANY
    invoke bind, hSock, addr localAddr, SIZEOF sockaddr_in
    .if eax != SOCKET_ERROR
        mov isFixedPort, 1
        mov ownPort, NET_PORT
        jmp NI_Ready
    .endif
    ; B1 回退：绑固定口失败 -> 原 socket 直接改绑 0（会话36 实测：本机 LSP
    ; 对 closesocket 后新建 socket 执行 bind 报 WSAENOTSOCK 10038；原口重绑可用）
    mov zeroAddr.sin_family, AF_INET
    invoke bind, hSock, addr zeroAddr, SIZEOF sockaddr_in
    .if eax == SOCKET_ERROR
        mov isFixedPort, 0
        mov ownPort, 0
        jmp NI_Ready
    .endif
    invoke getsockname, hSock, addr tmpSa, addr tmpSaLen
    movzx eax, tmpSa.sin_port
    invoke ntohs, eax
    movzx eax, ax
    mov ownPort, eax
    mov isFixedPort, 0
NI_Ready:
    ; 周期目标：广播与环回的 28888（环回补"广播不过环"的同机双开死角）
    mov bcastAddr.sin_family, AF_INET
    invoke htons, NET_PORT
    mov bcastAddr.sin_port, ax
    mov bcastAddr.sin_addr, INADDR_BROADCAST
    mov loopAddr.sin_family, AF_INET
    mov loopAddr.sin_port, ax
    mov loopAddr.sin_addr, INADDR_LOOPBACK
    ret
NetInit endp

; ------------------------------------------------------------
; NetEnterLan —— 进/回大厅：清对端与握手状态（socket/端口不动）
; ------------------------------------------------------------
NetEnterLan proc
    mov peerKnown, 0
    mov gotHello, 0
    mov gotStart, 0
    mov myStart, 0
    mov netLost, 0
    mov rxSeen, 0
    mov mirVX, 0                 ; 会话39：回大厅清外推速度
    mov mirVY, 0
    mov lobbyTimer, 0
    mov hsPeerSeed, 0
    mov hsPeerRounds, 0
    mov lastEvtSeq, 0
    ; 会话37：回大厅重连保留 relayMode/manualMode/peerAddr（目标不丢，
    ; Esc 回厅即可原地重握手）；只清展示态与 RTT 读数
    mov relaySt, 0
    mov relaySeen, 0
    mov netRttOk, 0
    mov netRttAvg, 0
    mov pingClock, 0
    mov hsTail, 0
    mov hsTailT, 0
    mov hsTailC, 0
    invoke GetTickCount
    mov lobbySeed, eax
    .if eax == 0
        mov lobbySeed, 1             ; 0 留作"无"
    .endif
    .if netDumpOn != 0
        call NetDumpEnsure           ; 会话36：大厅开局即建文件（H 行含 pid）
    .endif
    ret
NetEnterLan endp

; ------------------------------------------------------------
; NetSendProbe —— ptype: 0=announce 1=reply；dst=sockaddr_in*
; ------------------------------------------------------------
NetSendProbe proc ptype: dword, dst: dword
    mov probeT.sig[0], 'T'
    mov probeT.sig[1], 'W'
    mov probeT.sig[2], 'N'
    mov probeT.sig[3], 'E'
    mov probeT.sig[4], 'T'
    mov probeT.sig[5], '0'
    mov probeT.sig[6], '1'
    mov probeT.ver, NET_VER
    mov eax, ptype
    mov probeT.ptype, al
    mov eax, myStart                 ; 会话36：握手状态搭载探测包（HS 不可靠兜底）
    mov probeT.start, al
    mov eax, ownPort
    invoke htons, eax
    mov probeT.port, ax
    mov eax, lobbySeed
    mov probeT.cookie, eax
    invoke sendto, hSock, addr probeT, SIZEOF NET_PROBE, 0, dst, SIZEOF sockaddr_in
    ret
NetSendProbe endp

; ------------------------------------------------------------
; NetSendHS —— htype: 0=HELLO 1=START（都带 seed/rounds，收端常取）
; ------------------------------------------------------------
NetSendHS proc htype: dword
    mov hsT.magic0, 'H'
    mov eax, htype
    mov hsT.htype, al
    mov hsT.ver, NET_VER
    mov eax, lobbySeed
    mov hsT.seed, eax
    mov eax, maxRounds
    mov hsT.rounds, eax
    mov eax, hsPeerSeed
    mov hsT.cookie, eax              ; 观测字段，v1 不校验
    invoke sendto, hSock, addr hsT, SIZEOF NET_HS, 0, addr peerAddr, SIZEOF sockaddr_in
    ret
NetSendHS endp

; ------------------------------------------------------------
; NetSendJoin —— 会话37：'J' join 包（注册/续租房间槽位，发往 peerAddr=服务器）
; ------------------------------------------------------------
NetSendJoin proc
    mov joinT.magic0, 'J'
    mov joinT.jtype, 0
    mov joinT.ver, NET_VER
    mov joinT.jst, 0
    mov eax, relayRoom
    mov joinT.room, eax
    mov eax, lobbySeed
    mov joinT.cookie, eax
    invoke sendto, hSock, addr joinT, SIZEOF NET_JOIN, 0, addr peerAddr, SIZEOF sockaddr_in
    ret
NetSendJoin endp

; ------------------------------------------------------------
; NetSendPing —— 会话37：'P' RTT 探测（ts=lastPingTs 由调用方先写入）
; ------------------------------------------------------------
NetSendPing proc
    mov pingT.magic0, 'P'
    mov pingT.pingRpl, 0
    mov eax, lastPingTs
    mov pingT.ts, eax
    mov eax, lobbySeed
    mov pingT.cookie, eax
    invoke sendto, hSock, addr pingT, SIZEOF NET_PING, 0, addr peerAddr, SIZEOF sockaddr_in
    ret
NetSendPing endp

; ------------------------------------------------------------
; NetTickClocks —— 会话37：大厅/对局共用的周期钟
;   joinClock：中继模式每 1s 续发 'J'（服务器槽位 10s 过期，3 倍冗余）
;   pingClock：peerKnown 后每 0.5s 一发 'P'（RTT 显示）
; ------------------------------------------------------------
NetTickClocks proc
    inc joinClock
    .if joinClock >= NET_JOIN_TICKS
        mov joinClock, 0
        .if relayMode != 0
            invoke NetSendJoin
        .endif
    .endif
    .if peerKnown != 0
        inc pingClock
        .if pingClock >= NET_PING_TICKS
            mov pingClock, 0
            invoke GetTickCount
            mov lastPingTs, eax
            invoke NetSendPing
        .endif
    .endif
    ret
NetTickClocks endp

; ------------------------------------------------------------
; NetHandleJP —— 'J' 服务器应答 + 'S' STUN 反射 + 'P' RTT 探测/应答（recvBuf 暂存）
;   'J'：仅 relayMode；仅 jtype=1(ack)、room 匹配自身才采信 relaySt
;        （自己 JOIN 的 LSP 回声 jtype=0，天然被这层滤掉）
;   'S'（会话51 STUN步A）：仅 relayMode；room==relayRoom ∧ cookie==本机
;        lobbySeed（服务器回显的是"收件人自己"JOIN 携带的种子，第三方无从伪造；
;        对端虽见得到本种子——握手已交换——但步A仅存储显示，伪造收益为零）。
;        采信后仅写 stunIp/stunPort/stunSeen：peerAddr 仍钉服务器，行为零变化
;        （直连升级=步B，须双向验证后才允许改道）。
;   'P'：请求（rep=0）原地回 pong（ts 回显、cookie 换本机种子）；
;        应答（rep=1）三道认账：cookie≠lobbySeed（滤自己 pong 回声）、
;        ts==lastPingTs（只认在飞的那一发，回声的"请求"变出的 pong 也滤掉）
;        → RTT=GetTickCount-ts，u32 回绕安全；EWMA 3/4旧+1/4新。
; ------------------------------------------------------------
NetHandleJP proc len: dword
    movzx eax, byte ptr recvBuf[0]
    .if eax == 'J'
        .if relayMode != 0 && len >= SIZEOF NET_JOIN
            cmp byte ptr recvBuf[1], 1
            jne HJP_Done
            mov edx, dword ptr recvBuf[4]
            cmp edx, relayRoom
            jne HJP_Done
            movzx edx, byte ptr recvBuf[3]
            mov relaySt, edx
            mov relaySeen, 1
        .endif
    .elseif eax == 'S'
        .if relayMode != 0 && len >= SIZEOF NET_STUN
            mov edx, dword ptr recvBuf[10]
            cmp edx, relayRoom
            jne HJP_Done
            mov edx, dword ptr recvBuf[14]
            cmp edx, lobbySeed
            jne HJP_Done
            mov eax, dword ptr recvBuf[4]
            mov stunIp, eax                  ; 裸网络序 4B 原样存（IpToStr 逐字节读）
            movzx eax, word ptr recvBuf[8]   ; 裸 BE 2B -> 主机序数值（.386 无 bswap：xchg al,ah）
            xchg al, ah
            mov stunPort, eax
            mov stunSeen, 1
        .endif
    .else
        .if len >= SIZEOF NET_PING
            movzx edx, byte ptr recvBuf[1]
            .if edx == 0
                mov byte ptr recvBuf[1], 1
                mov eax, lobbySeed
                mov dword ptr recvBuf[8], eax
                invoke sendto, hSock, addr recvBuf, SIZEOF NET_PING, 0, addr fromAddr, SIZEOF sockaddr_in
            .else
                mov eax, dword ptr recvBuf[8]
                cmp eax, lobbySeed
                je HJP_Done
                mov edx, dword ptr recvBuf[4]
                cmp edx, lastPingTs
                jne HJP_Done
                invoke GetTickCount
                ; GetTickCount 毁 EDX（volatile，本会话 ui 崩溃同教训）：
                ; 差值须从包头重装，不能跨 API 暂存 edx（实测曾算出开机时长）
                sub eax, dword ptr recvBuf[4]
                ; 样本未跨 tick 边界（GetTickCount 粒度 ~15.6ms）时按 1ms 计：
                ; 真实值落在 [0,16)，取下界上探 1，避免 EWMA 恒 0 无从判别链路
                .if eax == 0
                    mov eax, 1
                .endif
                mov netRtt, eax
                mov netRttOk, 1
                mov ecx, netRttAvg
                test ecx, ecx
                jz HJP_1st
                imul ecx, ecx, 3
                add ecx, eax
                shr ecx, 2
                mov netRttAvg, ecx
                jmp HJP_Done
            HJP_1st:
                mov netRttAvg, eax
            .endif
        .endif
    .endif
HJP_Done:
    ret
NetHandleJP endp

; ------------------------------------------------------------
; NetFeedJP —— selftest 入口（会话51 T54）：把 pBuf 起 len 字节灌进 recvBuf
; 再走 NetHandleJP。'S'/'J' 分支不触 socket（仅 'P' 请求分支会回 pong，
; 自测不喂 'P'），实现零 socket 验证。
; ------------------------------------------------------------
NetFeedJP proc uses esi edi pBuf: dword, len: dword
    mov esi, pBuf
    mov edi, offset recvBuf
    mov ecx, len
    cld
    rep movsb
    invoke NetHandleJP, len
    ret
NetFeedJP endp

; ------------------------------------------------------------
; NetLobbyTick —— 大厅每 tick（ui ST_LAN 调用）
; ------------------------------------------------------------
NetLobbyTick proc uses ebx esi
    inc netTick
    inc lobbyTimer
    ; ---- 排空收包（上限 16，防风暴卡帧）----
    mov lobbyDrain, 16
LB_Recv:
    mov fromLen, SIZEOF sockaddr_in
    invoke recvfrom, hSock, addr recvBuf, 64, 0, addr fromAddr, addr fromLen
    .if eax == SOCKET_ERROR
        jmp LB_Timers
    .endif
    mov ebx, eax                     ; 长度
    ; 会话36：本机 LSP 会把包首 dw 字节序对调；探测 sig "TWNET01" 首 dw 恰为
    ; 'T','W' 形态受影响最小，但仍容忍 esi∈{0,2} 两种起点以防链路再变形
    movzx eax, byte ptr recvBuf[0]
    mov ecx, 0
    .if eax == 'T'
        mov edx, dword ptr recvBuf[0]
        .if edx != 454E5754h
            mov edx, dword ptr recvBuf[2]
            .if edx == 454E5754h
                mov ecx, 2
            .endif
        .endif
    .endif
    .if eax == 'T' || ecx == 2
        mov esi, ecx
        lea ebx, [ebx+esi]            ; 长度判定按位移后口径
    .if ebx >= SIZEOF NET_PROBE
        .if dword ptr recvBuf[esi] == 454E5754h && byte ptr recvBuf[esi+4] == 'T'   ; "TWNET01" 头
            mov eax, dword ptr recvBuf[esi+12]
            cmp eax, lobbySeed                ; 自回声过滤
            je LB_Next
            ; 会话36：本机 LSP 让广播包的源端口不可回（随机化），对端真实
            ; 监听口取 announce 载荷里的 port 字段（网络序）。
            ; 会话37：中继模式下 peerAddr 恒=服务器，对端内网端口无意义，
            ; 覆写反而切断回程——relayMode 时整段跳过。
            .if relayMode == 0
                movzx eax, word ptr recvBuf[esi+10]
                invoke StrCopySa, addr fromAddr, addr peerAddr
                mov word ptr peerAddr.sin_port, ax
            .endif
            mov peerKnown, 1                  ; 真实源=可回地址（含临时端口）
            ; 会话36：本机 LSP 会改写/丢弃 'H' 包（实测首字节变 0x44），握手
            ; 状态改由探测包载荷承载：cookie=对端种子、start=对端已按开始
            mov eax, dword ptr recvBuf[esi+12]
            mov hsPeerSeed, eax
            mov gotHello, 1
            cmp byte ptr recvBuf[esi+9], 0
            je LB_P2
            mov gotStart, 1
        LB_P2:
            cmp byte ptr recvBuf[esi+8], 0    ; announce -> reply 单播回它
            jne LB_Next
            invoke NetSendProbe, 1, addr peerAddr
        .endif                          ; 收 magic 判定
    .endif                              ; 收长度判定
    .elseif eax == 'H' && ebx >= SIZEOF NET_HS
        mov edx, dword ptr recvBuf[4]
        cmp edx, lobbySeed                ; 自回声 HS：不当对端采纳（会话36）
        je LB_Next
        mov eax, dword ptr recvBuf[4]
        mov hsPeerSeed, eax                   ; HELLO/START 都带：常取
        mov eax, dword ptr recvBuf[8]
        mov hsPeerRounds, eax
        mov gotHello, 1
        cmp byte ptr recvBuf[1], 1
        jne LB_H1
        mov gotStart, 1
    LB_H1:
        .if relayMode == 0                ; 会话37：中继模式 peerAddr 恒=服务器不覆写
            invoke StrCopySa, addr fromAddr, addr peerAddr
        .endif
        mov peerKnown, 1
    .elseif eax == 'J' || eax == 'P' || eax == 'S'   ; 会话37 中继 ack/RTT；会话51 +'S'
        invoke NetHandleJP, ebx
    .endif
LB_Next:
    dec lobbyDrain
    .if lobbyDrain > 0
        jmp LB_Recv
    .endif

LB_Timers:
    ; ---- 周期 announce ----
    mov eax, NET_ANN_TICKS
    .if manualMode != 0
        mov eax, NET_ANN_MANUAL
    .endif
    .if lobbyTimer >= eax
        mov lobbyTimer, 0
        .if manualMode != 0
            invoke NetSendProbe, 0, addr peerAddr   ; 单播轰目标监听口
        .else
            invoke NetSendProbe, 0, addr bcastAddr
            invoke NetSendProbe, 0, addr loopAddr
        .endif
    .endif
    ; ---- 会话37：JOIN 续租 + RTT 探测周期钟（大厅/对局共用）----
    call NetTickClocks
    ; ---- 周期 HELLO（已按开始则同带 START）----
    .if peerKnown != 0
        mov eax, lobbyTimer
        xor edx, edx
        mov ecx, NET_HS_TICKS
        div ecx
        .if edx == 0
            invoke NetSendHS, 0
            .if myStart != 0
                invoke NetSendHS, 1
            .endif
        .endif
    .endif
    call NetCheckTimeout
    ; 会话36 诊断：大厅 FSM 快照行 "B hello start myStart peerKnown netTick"
    .if netDumpOn != 0
        mov eax, netTick
        and eax, 0Fh
        .if eax == 0
            call DpStart
            invoke DpByte, 'B'
            mov eax, gotHello
            invoke DpTok, eax
            mov eax, gotStart
            invoke DpTok, eax
            mov eax, myStart
            invoke DpTok, eax
            mov eax, peerKnown
            invoke DpTok, eax
            mov eax, netTick
            invoke DpTok, eax
            ; 会话51 STUN步A 追加列：stunSeen stunPort stunIp（交叉对账：本端
            ; stunPort 应恒等于对端 H 行自报监听口；stunIp=16777343 即环回）
            mov eax, stunSeen
            invoke DpTok, eax
            mov eax, stunPort
            invoke DpTok, eax
            mov eax, stunIp
            invoke DpTok, eax
            call DpEol
        .endif
    .endif
    ret
NetLobbyTick endp

; ------------------------------------------------------------
; NetCheckTimeout —— B4：2s 未收包 -> netLost（只作展示/暂停门；
; 照发照收，任何一包到达即自愈，不需要重进大厅）
; ------------------------------------------------------------
NetCheckTimeout proc
    .if rxSeen != 0 && netLost == 0
        mov eax, netTick
        sub eax, lastRxTick
        .if eax > NET_TIMEOUT
            mov netLost, 1
        .endif
    .endif
    ret
NetCheckTimeout endp

; ------------------------------------------------------------
; NetMirrorExtrap —— 会话39：断包空洞期内按衰减速度外推镜像位置。
; 门（全部满足才动）：netLost==0（netLost 时 netPaused 冻结玩法，画面本就定格）、
; peerKnown、rxSeen、delta=netTick-lastRxTick 在 1..NET_EXTRAP_MAX、镜像存活。
; 步长 = v >> (delta-1)：三档 v → v/2 → v/4 递减，长断包越推越收敛到停，不假冲刺；
; 之后不再补推，等 NET_TIMEOUT 弹层/自愈兜底。下一包到达由 NetApplyRx 权威覆写纠偏。
; 正常串流每 tick 都有包：收包在同一次 NetFlush 内先于本函数，delta=0 恒不触发
; （回环自检/双机零回归）。
; ------------------------------------------------------------
NetMirrorExtrap proc
    .if netLost == 0 && peerKnown != 0 && rxSeen != 0
        mov eax, netTick
        sub eax, lastRxTick
        .if eax > 0 && eax <= NET_EXTRAP_MAX
            .if tanks[PLAYER_PEER*SIZEOF TANK].alive != 0
                mov ecx, eax
                dec ecx                    ; shift = delta-1
                mov edx, mirVX
                mov eax, mirVY
NME_Decay:
                test ecx, ecx
                jz NME_Apply
                sar edx, 1
                sar eax, 1
                dec ecx
                jmp NME_Decay
NME_Apply:
                add edx, tanks[PLAYER_PEER*SIZEOF TANK].x
                add eax, tanks[PLAYER_PEER*SIZEOF TANK].y
                ; 越界钳位同用手写有符号比较（.if reg<0 无符号恒假）
                test edx, edx
                jns NME_XHi
                xor edx, edx
                jmp NME_YChk
NME_XHi:
                cmp edx, MAP_W - TANK_SIZE
                jle NME_YChk
                mov edx, MAP_W - TANK_SIZE
NME_YChk:
                test eax, eax
                jns NME_YHi
                xor eax, eax
                jmp NME_Store
NME_YHi:
                cmp eax, MAP_H - TANK_SIZE
                jle NME_Store
                mov eax, MAP_H - TANK_SIZE
NME_Store:
                mov tanks[PLAYER_PEER*SIZEOF TANK].x, edx
                mov tanks[PLAYER_PEER*SIZEOF TANK].y, eax
            .endif
        .endif
    .endif
    ret
NetMirrorExtrap endp

; ------------------------------------------------------------
; NetLobbyState —— bit0=peerKnown bit1=gotHello bit2=myStart bit3=gotStart
; ------------------------------------------------------------
NetLobbyState proc
    xor eax, eax
    .if peerKnown != 0
        or eax, 1
    .endif
    .if gotHello != 0
        or eax, 2
    .endif
    .if myStart != 0
        or eax, 4
    .endif
    .if gotStart != 0
        or eax, 8
    .endif
    ret
NetLobbyState endp

NetCanStart proc                  ; 双 Enter 且握手齐才开局（修单边开局）
    mov eax, 0
    .if peerKnown != 0 && gotHello != 0 && gotStart != 0 && myStart != 0
        mov eax, 1
    .endif
    ret
NetCanStart endp

NetSetStart proc
    mov myStart, 1
    ret
NetSetStart endp

; ------------------------------------------------------------
; ParseIp —— "a.b.c.d[:p]" -> (网络序 ip, 主机序 port)
; 返回 eax=1 成功 / 0 非法（尾随空格容错；"256.1.1.1" 拒；":0" 拒；
; "1.2.3.4:28888" 收；缺省端口 = NET_PORT）
; 纯整数扫描无 CRT；寄存器吃紧（4 段状态）故用静态 scratch
; ------------------------------------------------------------
ParseIp proc uses ebx esi edi pBuf: dword, pIp: dword, pPort: dword
    mov esi, pBuf
    xor ebx, ebx                   ; 游标
    xor edi, edi                   ; 已并入八位组数（':' 后置 4）
    mov segAccS, 0                 ; 当前段累积（会话36：原用 ebp 毁帧指针，改内存暂存）
    mov ipAccS, 0
    mov portAccS, 0
    mov inPortS, 0
    mov digitSeen, 0
PI_Loop:
    movzx eax, byte ptr [esi+ebx]
    .if eax == 0
        jmp PI_Finish
    .endif
    .if eax == ' ' || eax == 9
        jmp PI_Space
    .endif
    .if eax == ':'
        .if edi != 3 || inPortS != 0
            jmp PI_Bad
        .endif
        .if digitSeen == 0
            jmp PI_Bad             ; 末八位组为空 "1.2.3.:"
        .endif
        mov eax, segAccS
        shl eax, 24
        or ipAccS, eax             ; 末段并入
        mov inPortS, 1
        mov edi, 4
        mov segAccS, 0
        mov digitSeen, 0
        inc ebx
        jmp PI_Loop
    .endif
    .if eax == '.'
        .if inPortS != 0 || edi >= 3 || digitSeen == 0
            jmp PI_Bad
        .endif
        mov eax, segAccS
        mov ecx, edi
        shl ecx, 3
        shl eax, cl
        or ipAccS, eax
        inc edi
        mov segAccS, 0
        mov digitSeen, 0
        inc ebx
        jmp PI_Loop
    .endif
    .if eax < '0' || eax > '9'
        jmp PI_Bad
    .endif
    sub eax, '0'
    mov digitSeen, 1
    mov ecx, segAccS
    imul ecx, ecx, 10
    add ecx, eax
    mov segAccS, ecx
    mov eax, ecx
    .if inPortS == 0
        .if eax > 255
            jmp PI_Bad
        .endif
    .else
        .if eax > 65535
            jmp PI_Bad
        .endif
    .endif
    inc ebx
    jmp PI_Loop
PI_Space:
    inc ebx
    movzx eax, byte ptr [esi+ebx]
    .if eax == ' ' || eax == 9
        jmp PI_Space
    .endif
    .if eax == 0
        jmp PI_Finish
    .endif
    jmp PI_Bad
PI_Finish:
    .if digitSeen == 0
        jmp PI_Bad                 ; 空尾段（"1.2.3." / ":28888 "前无数字）
    .endif
    .if inPortS == 0
        .if edi != 3
            jmp PI_Bad             ; 不足 4 段
        .endif
        mov eax, segAccS
        shl eax, 24
        or ipAccS, eax
        mov eax, pPort
        mov dword ptr [eax], NET_PORT
    .else
        mov eax, segAccS
        .if eax == 0
            jmp PI_Bad             ; 端口 0 非法
        .endif
        mov ecx, eax
        mov eax, pPort
        mov dword ptr [eax], ecx
    .endif
    mov eax, pIp
    mov ecx, ipAccS
    mov dword ptr [eax], ecx
    mov eax, 1
    ret
PI_Bad:
    xor eax, eax
    ret
ParseIp endp

; ------------------------------------------------------------
; NetSetManual —— ui 手动连接确认：解析并预置直连目标
; 成功后 announce 转单播该地址；对方回 reply/HELLO 即进握手流程
; 返回 eax=1 成功 / 0 解析失败（界面红字，peerAddr 不动）
; ------------------------------------------------------------
NetSetManual proc pBuf: dword
    invoke ParseIp, pBuf, addr manualIp, addr manualPort
    .if eax == 0
        ret
    .endif
    mov manualMode, 1
    ; 会话37：手输纯 IP=退回直连语义，中继模式关闭（两者互斥，后设者赢）
    mov relayMode, 0
    mov relaySt, 0
    mov relayRoom, 0
    mov peerAddr.sin_family, AF_INET
    mov eax, manualIp
    mov peerAddr.sin_addr, eax
    mov eax, manualPort
    invoke htons, eax
    mov peerAddr.sin_port, ax
    mov peerKnown, 0
    mov gotHello, 0
    mov gotStart, 0
    mov myStart, 0
    mov lobbyTimer, NET_ANN_TICKS     ; 下个周期立即发 announce
    mov eax, 1
    ret
NetSetManual endp

; ------------------------------------------------------------
; ParseServerSpec —— 会话37："a.b.c.d[:p]#room" -> (ip网络序, 端口主机序, 房间)
; 房间 1..6 位数字且值 1..999999；IP 段缺 ':' 端口默认 NET_SRV_PORT(28900)；
; 任一段非法整体拒绝（不写输出参数）。纯整数扫描，静态 scratch（勿用 ebp）。
; ------------------------------------------------------------
ParseServerSpec proc uses ebx esi pBuf: dword, pIp: dword, pPort: dword, pRoom: dword
    mov esi, pBuf
    xor ebx, ebx
    xor ecx, ecx                     ; IP 段拷贝写指针
PS_Scan:
    movzx eax, byte ptr [esi+ebx]
    .if eax == '#'
        mov byte ptr srvTmpIp[ecx], 0
        inc ebx
        jmp PS_Room
    .endif
    .if eax == 0
        xor eax, eax
        ret                          ; 缺 '#'
    .endif
    .if ecx >= 30
        xor eax, eax
        ret                          ; IP 段超长
    .endif
    mov srvTmpIp[ecx], al
    inc ecx
    inc ebx
    jmp PS_Scan
PS_Room:
    mov srvColon, 0                  ; IP 段是否自带端口
    xor ecx, ecx
PS_Cln:
    movzx eax, byte ptr srvTmpIp[ecx]
    .if eax == 0
        jmp PS_Dig
    .endif
    .if eax == ':'
        mov srvColon, 1
    .endif
    inc ecx
    jmp PS_Cln
PS_Dig:
    mov srvAccS, 0
    mov srvCntS, 0
PS_Dloop:
    movzx eax, byte ptr [esi+ebx]
    .if eax < '0' || eax > '9'
        .if eax == 0
            jmp PS_Dfin
        .endif
        xor eax, eax
        ret                          ; 房间号只允许数字（严格口径，无尾随容忍）
    .endif
    .if srvCntS >= 6
        xor eax, eax
        ret
    .endif
    sub eax, '0'
    mov ecx, srvAccS
    imul ecx, ecx, 10
    add ecx, eax
    mov srvAccS, ecx
    inc srvCntS
    inc ebx
    jmp PS_Dloop
PS_Dfin:
    .if srvCntS == 0
        xor eax, eax
        ret                          ; '#' 后为空
    .endif
    mov eax, srvAccS
    .if eax == 0
        xor eax, eax
        ret                          ; 房间号 0 非法
    .endif
    invoke ParseIp, addr srvTmpIp, pIp, pPort
    .if eax == 0
        xor eax, eax
        ret
    .endif
    .if srvColon == 0
        mov eax, pPort
        mov dword ptr [eax], NET_SRV_PORT
    .endif
    mov eax, pRoom
    mov ecx, srvAccS
    mov dword ptr [eax], ecx
    mov eax, 1
    ret
ParseServerSpec endp

; ------------------------------------------------------------
; NetSetServer —— 会话37：连接中继服务器 "ip[:port]#room"（大厅手动行带 '#'）
; 成功：manualMode+relayMode=1，peerAddr=服务器；announce 转定向单播（经
; 转发即为对端可达）；立即发 'J' 注册（不等周期）。失败不改任何状态。
; 返回 eax=1/0（界面红字）
; ------------------------------------------------------------
NetSetServer proc pBuf: dword
    invoke ParseServerSpec, pBuf, addr srvIp, addr srvPort, addr relayRoom
    .if eax == 0
        ret
    .endif
    mov manualMode, 1
    mov relayMode, 1
    mov relaySt, 0
    mov relaySeen, 0
    mov stunIp, 0                     ; 会话51：换目标即清观测点（防陈旧显示/陈旧步B原料）
    mov stunPort, 0
    mov stunSeen, 0
    mov peerAddr.sin_family, AF_INET
    mov eax, srvIp
    mov peerAddr.sin_addr, eax
    mov eax, srvPort
    invoke htons, eax
    mov peerAddr.sin_port, ax
    mov peerKnown, 0
    mov gotHello, 0
    mov gotStart, 0
    mov myStart, 0
    mov lobbyTimer, NET_ANN_TICKS     ; 立即补一发 announce（打开对端回程）
    invoke NetSendJoin
    mov eax, 1
    ret
NetSetServer endp

; ------------------------------------------------------------
; NetResetTargets —— 会话37：主菜单重进大厅清"目标"（手动/中继模式与房间号），
; 区别于 NetEnterLan（对局 Esc 回厅保留目标原地重连）
; ------------------------------------------------------------
NetResetTargets proc
    mov relayMode, 0
    mov manualMode, 0
    mov relayRoom, 0
    mov relaySt, 0
    mov relaySeen, 0
    mov stunIp, 0                     ; 会话51：目标清零连带清观测点
    mov stunPort, 0
    mov stunSeen, 0
    ret
NetResetTargets endp

; ------------------------------------------------------------
; NetEnterMatch —— ui 在 NetCanStart 后调用：共享种子 -> 开局
; ------------------------------------------------------------
NetEnterMatch proc
    ; 会话38/39：联机局绝不带人机残留（挑战/补位->大厅->联机的防御路径）
    cmp botMask, 0
    je NEM_Role
    mov botMask, 0
    invoke UiSyncBotName
NEM_Role:
    mov eax, lobbySeed
    xor eax, hsPeerSeed
    .if eax == 0
        mov eax, 1                   ; 双端同 ms 撞种子 -> 避免 0
    .endif
    mov netSharedSeed, eax
    ; 出生角色：两端 slot0 都是"自机"，若共用出生点0则同点重叠（会话36 回环
    ; 实测 x0 双方=67,291）。lobbySeed 大者=B 端，出生索引 0<->3 对角互换。
    mov eax, lobbySeed
    .if eax > hsPeerSeed
        mov netRole, 1
    .else
        mov netRole, 0
    .endif
    mov eax, netSharedSeed
    invoke SetNetSeed, eax
    mov eax, hsPeerRounds            ; 局数取小
    .if eax != 0
        .if eax < maxRounds
            mov maxRounds, eax
        .endif
    .endif
    mov numPlayers, 2
    mov netMode, 1
    invoke GameInit                  ; 内含 InputArmHold（会话34 防进场走火）
    ; 序号/事件去重归一（B7：联机局此后跨回合单调，ResetTanks 已门禁）
    mov seqSelf, 0
    mov peerSeq, 0
    mov lastEvtSeq, 0
    mov lastLsrSeq, 0
    mov evtPend, 0
    mov evtPendTtl, 0
    mov laserPendTtl, 0
    mov rxSeen, 0
    mov netLost, 0
    mov eax, netTick
    mov lastRxTick, eax
    mov mirVX, 0                 ; 会话39：外推估计随新局清零（防陈旧速度带镜像漂移）
    mov mirVY, 0
    mov onlineBanT, 0            ; 会话39：新局清禁用技提示残留
    ; 会话37：启动握手尾巴（见 .data 注释），把慢半拍的对端拉进对局
    mov hsTail, 1
    mov hsTailT, 300
    mov hsTailC, 0
    .if netDumpOn != 0
        call NetDumpEnsure
        ; G 行：共享种子 / 局数 / 首张图号（两端应全等 -> 握手证据）
        call DpStart
        invoke DpByte, 'G'
        mov eax, netSharedSeed
        invoke DpTok, eax
        mov eax, maxRounds
        invoke DpTok, eax
        mov eax, mapIndex
        invoke DpTok, eax
        call DpEol
    .endif
    ret
NetEnterMatch endp

; ------------------------------------------------------------
; PackState —— 本端状态 -> sendPkt（v1 26B；magic 'WT' 内存 'W','T'）
; ------------------------------------------------------------
PackState proc
    mov sendPkt.magic, 'WT'
    inc seqSelf
    mov ax, seqSelf
    mov sendPkt.seq, ax
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].x
    mov sendPkt.tx, eax              ; v1 全 32 位（v0 截字隐患根除）
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].y
    mov sendPkt.ty, eax
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].dir
    imul eax, eax, 256
    add eax, 128
    mov ecx, 360
    xor edx, edx
    div ecx                          ; q=(ang*256+128)/360
    mov sendPkt.tdir, al
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].hp
    mov sendPkt.thp, al
    ; flags：bit0 开火（消费 fireHappened）；bit1 死亡（B6 根修）
    mov eax, 0
    mov ecx, fireHappened
    .if ecx != 0
        or eax, PKT_FIRE
        mov fireHappened, 0
    .endif
    cmp tanks[PLAYER_SELF*SIZEOF TANK].alive, 0
    jne PS_Alive
    or eax, PKT_DEAD
PS_Alive:
    mov sendPkt.flags, al
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].effOn
    mov sendPkt.effOnLow, al
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].skill
    mov sendPkt.skillId, al
    ; 事件槽 3 连发（接收端按 evtSeq 去重，只认一次）
    mov sendPkt.evtKind, 0
    ; 会话36：22 evtY 转作"发送者 tag"=lobbySeed 低 16 位（evtY 原语义作废：
    ; 所有事件生产者 py 恒 0，收侧从不读 evtY）。自回声必携带本机 tag，
    ; 收侧据此丢弃，防 peerSeq 被自己的序号顶前 -> 对端真包永久落窗外。
    mov eax, lobbySeed
    mov sendPkt.evtY, ax
    mov eax, evtPendTtl
    .if eax > 0
        dec eax
        mov evtPendTtl, eax
        mov eax, evtPend
        mov sendPkt.evtKind, al
        mov eax, evtPendSeq
        mov sendPkt.evtSeq, al
        mov eax, evtPendX
        mov sendPkt.evtX, ax
        mov eax, evtPendData
        mov sendPkt.evtData, al
    .endif
    ret
PackState endp

; ------------------------------------------------------------
; PackLaser —— laser 全局快照 -> sendLsr（发射端 3 连发共用同一路径）
; ------------------------------------------------------------
PackLaser proc uses ebx ecx
    mov sendLsr.magic0, 'L'
    mov eax, laserN
    mov sendLsr.npts, al
    mov eax, laserLen
    mov sendLsr.len, ax
    mov eax, laserEvSeq
    mov sendLsr.seq, ax
    mov lastSentLsr, eax               ; 会话36：自回声识别用（收侧比对 seq）
    mov sendLsr.skill, 0
    xor ebx, ebx
PL_Loop:
    mov ecx, laserN
    .if ebx >= ecx
        jmp PL_Done
    .endif
    mov eax, laserX[ebx*4]
    mov sendLsr.px[ebx*4], ax
    mov eax, laserY[ebx*4]
    mov sendLsr.px[ebx*4+2], ax
    inc ebx
    jmp PL_Loop
PL_Done:
    ret
PackLaser endp

; ------------------------------------------------------------
; NetApplyRx —— 收包应用器（public：selftest 零 socket 直喂）
; 入参 pBuf=包体, pFrom=源 sockaddr_in*；返回 eax=1 应用 / 0 丢弃
; ------------------------------------------------------------
NetApplyRx proc uses ebx esi edi pBuf: dword, pFrom: dword
    mov esi, pBuf
    ; 会话36 实测（Z 转储 54570100 83010000 E3000000）：本机 LSP 不剥/不加前缀，
    ; 而是把状态包首 dw 字节序对调（内存 'W','T' -> 线上 'T','W'），载荷不位移。
    ; 接收端把对调头归一化回 'W' 照常解析；sig "TWNET01" 探测（byte[2]=='N'）除外，
    ; 归大厅 FSM 处理。跨网正常链路收到 57 54 走原路，两形态通吃。
    cmp byte ptr [esi], 'T'
    jne AR_NoFix
    cmp byte ptr [esi+1], 'W'
    jne AR_Drop
    cmp byte ptr [esi+2], 'N'
    je AR_Drop
    mov byte ptr [esi], 'W'
AR_NoFix:
    movzx eax, byte ptr [esi]
    .if eax == 'W'
        ; ---- 自回声防线（会话36）：本机 LSP 会把单播包回灌发送者；回声的
        ; tag(evtY 低16=lobbySeed) 必等于本机，先于 seq 窗丢弃。回声若被采信
        ; 会把 peerSeq 顶到对端真实序号之前 -> 此后真包全落窗外=永久 netLost
        ; 死锁（回环实测）。selftest 直喂时 lobbySeed=0 -> 防线旁路。
        mov eax, lobbySeed
        test eax, eax
        jz AR_TagOk
        movzx edx, word ptr [esi+22]
        cmp dx, ax
        je AR_Drop
AR_TagOk:
        ; ---- seq 循环窗口判新（B7：替无符号 jbe，65535 回绕不丢包）----
        movzx ecx, word ptr [esi+2]
        mov ax, peerSeq
        sub cx, ax
        cmp cx, 8000h
        jae AR_Drop
        movzx ecx, word ptr [esi+2]      ; sub 毁掉了低 16 位，重取绝对序号
        mov peerSeq, cx
        ; ---- 外推速度估计（会话39）：两包位置差钳位 ±NET_EXTRAP_CAP，须在覆写位置前取 ----
        ; 正常串流下每 tick 收包 delta=0，外推门不点亮，此估计只在断包时生效；回环/自检零回归。
        ; 注意：MASM .if 对 寄存器<负常量 按无符号比较（3 < -4 为真!），钳位必须手写有符号 jmp。
        mov eax, dword ptr [esi+4]
        sub eax, tanks[PLAYER_PEER*SIZEOF TANK].x
        cmp eax, NET_EXTRAP_CAP
        jle NVX_Lo
        mov eax, NET_EXTRAP_CAP
        jmp NVX_St
NVX_Lo:
        cmp eax, -NET_EXTRAP_CAP
        jge NVX_St
        mov eax, -NET_EXTRAP_CAP
NVX_St:
        mov mirVX, eax
        mov eax, dword ptr [esi+8]
        sub eax, tanks[PLAYER_PEER*SIZEOF TANK].y
        cmp eax, NET_EXTRAP_CAP
        jle NVY_Lo
        mov eax, NET_EXTRAP_CAP
        jmp NVY_St
NVY_Lo:
        cmp eax, -NET_EXTRAP_CAP
        jge NVY_St
        mov eax, -NET_EXTRAP_CAP
NVY_St:
        mov mirVY, eax
        ; ---- 镜像覆盖：位置/朝向/血量/存活/效果/持技 ----
        mov eax, dword ptr [esi+4]
        mov tanks[PLAYER_PEER*SIZEOF TANK].x, eax
        mov eax, dword ptr [esi+8]
        mov tanks[PLAYER_PEER*SIZEOF TANK].y, eax
        movzx eax, byte ptr [esi+12]
        imul eax, eax, 360
        add eax, 128
        shr eax, 8                   ; ang=(q*360+128)>>8，误差<=0.7 度
        mov tanks[PLAYER_PEER*SIZEOF TANK].dir, eax
        movzx eax, byte ptr [esi+13]
        mov tanks[PLAYER_PEER*SIZEOF TANK].hp, eax
        movzx edx, byte ptr [esi+14]
        test edx, PKT_DEAD
        .if ZERO?
            mov eax, 1
        .else
            xor eax, eax
            mov tanks[PLAYER_PEER*SIZEOF TANK].hp, 0
        .endif
        mov tanks[PLAYER_PEER*SIZEOF TANK].alive, eax
        movzx eax, byte ptr [esi+15]
        mov tanks[PLAYER_PEER*SIZEOF TANK].effOn, eax
        movzx eax, byte ptr [esi+16]
        mov tanks[PLAYER_PEER*SIZEOF TANK].skill, eax
        ; ---- 事件槽分发（seq 相同只认一次）----
        movzx eax, byte ptr [esi+17]
        .if eax != EVT_NONE
            movzx ebx, byte ptr [esi+18]
            cmp ebx, lastEvtSeq
            je AR_SkipEvt
            mov lastEvtSeq, ebx
            .if eax == EVT_MINE
                movzx ecx, word ptr [esi+20]  ; 中心格 index
                xor edx, edx
AR_MineSlot:
                .if edx >= MAX_MINES
                    jmp AR_SkipEvt
                .endif
                cmp mineCell[edx*4], -1
                je AR_MinePut
                inc edx
                jmp AR_MineSlot
AR_MinePut:
                mov mineCell[edx*4], ecx
                mov mineArm[edx*4], MINE_ARM_TICKS
                mov mineOwner[edx*4], PLAYER_PEER
            .elseif eax == EVT_LASER_PREV
                movzx ecx, byte ptr [esi+24]
                mov tanks[PLAYER_PEER*SIZEOF TANK].aimSkill, ecx
                mov tanks[PLAYER_PEER*SIZEOF TANK].aimT, LASER_FIRE_TICKS
            .elseif eax == EVT_PICK
                mov pickupType, 0
                mov eax, PICKUP_PERIOD
                mov pickupTimer, eax
            .elseif eax == EVT_ICE
                movzx eax, word ptr [esi+20]
                xor edx, edx
                mov ebx, COLS
                div ebx                  ; eax=行 edx=列
                invoke SpawnIce2x2At, edx, eax
            .endif
AR_SkipEvt:
        .endif
        ; ---- 开火位 -> 镜像弹（位置已更新，弹道本地演算）----
        movzx edx, byte ptr [esi+14]
        test edx, PKT_FIRE
        jz AR_Live
        invoke SpawnBullet, PLAYER_PEER
AR_Live:
        mov eax, netTick
        mov lastRxTick, eax
        mov rxSeen, 1
        mov netLost, 0               ; 掉线自愈（B4）
        mov hsTail, 0                ; 会话37：对端已在局（W 到达）→ 尾巴收工
            .if peerKnown == 0
            .if relayMode == 0        ; 会话37：中继模式不覆写（pFrom=服务器地址）
                invoke StrCopySa, pFrom, addr peerAddr
            .endif
            mov peerKnown, 1
        .endif
        mov eax, 1
        ret
    .elseif eax == 'L'
        ; ---- 防自回声（会话36）：seq 与本机末次发出相同 -> 链路回灌，丢弃
        movzx edx, word ptr [esi+4]
        cmp dx, word ptr lastSentLsr
        je AR_Drop
        ; ---- 折线包：去重后照抄路径 + 清镜像瞄准（防二次起爆）----
        movzx eax, byte ptr [esi+1]
        .if eax > MAX_LASER_PTS
            jmp AR_Drop            ; 坏包折点数异常，整包丢弃
        .endif
        mov laserN, eax
        movzx ecx, word ptr [esi+4]
        cmp ecx, lastLsrSeq
        je AR_Drop
        mov lastLsrSeq, ecx
        movzx ecx, word ptr [esi+2]
        mov laserLen, ecx
        mov laserOwn, PLAYER_PEER    ; 会话40：对端折线归属登记（成就伤害结算读；actor 闸自然拒记）
        xor ecx, ecx
AR_LsrCopy:
        cmp ecx, laserN
        jae AR_LsrDone
        movzx eax, word ptr [esi+8+ecx*4]
        mov laserX[ecx*4], eax
        movzx eax, word ptr [esi+8+ecx*4+2]
        mov laserY[ecx*4], eax
        inc ecx
        jmp AR_LsrCopy
AR_LsrDone:
        mov laserD, 0
        mov laserT, 48
        mov laserHitMask, 0
        mov tanks[PLAYER_PEER*SIZEOF TANK].aimSkill, SKILL_NONE
        mov tanks[PLAYER_PEER*SIZEOF TANK].aimT, 0
        mov prevTank, -1
        mov prevN, 0
        jmp AR_Live
    .endif
AR_Drop:
    xor eax, eax
    ret
NetApplyRx endp

; ------------------------------------------------------------
; NetApplyPacket —— selftest 便捷入口：只喂 NET_PKT（源=现有 peerAddr）
; ------------------------------------------------------------
NetApplyPacket proc pBuf: dword
    invoke NetApplyRx, pBuf, addr fromAddr
    ret
NetApplyPacket endp

; ------------------------------------------------------------
; NetFlush —— 对局每 tick（主循环 netMode!=0 时调用）
; ------------------------------------------------------------
NetFlush proc uses ebx ecx edi
    inc netTick
    call NetTickClocks               ; 会话37：JOIN 续租 + RTT 探测
    .if peerKnown != 0
        call PackState
        invoke sendto, hSock, addr sendPkt, NET_PKT_SIZE, 0, addr peerAddr, SIZEOF sockaddr_in
        .if laserPendTtl > 0
            call PackLaser
            invoke sendto, hSock, addr sendLsr, NET_LSR_SIZE, 0, addr peerAddr, SIZEOF sockaddr_in
            mov eax, laserPendTtl
            dec eax
            mov laserPendTtl, eax
        .endif
    .else
        ; 从未联上/断后重连前：丢弃陈年动作，防恢复瞬间重播
        mov fireHappened, 0
        mov evtPendTtl, 0
        mov laserPendTtl, 0
    .endif
    ; ---- 会话37 握手尾巴：本机已进局但对端可能还卡在大厅（START 包
    ;      竞态丢失）。每 15tick 补发一发带 myStart 的 announce（直连=直达
    ;      对端 / 中继=服务器转发），收端 lobby 'T' 分支置 gotStart 即开局；
    ;      对局期收端 NF_Recv 对 'T' 探测本就忽略，多发无害。收到对端首个
    ;      W（AR_Live 路径）或 5s 超时后关闭。----
    .if hsTail != 0
        dec hsTailT
        .if hsTailT <= 0
            mov hsTail, 0
        .else
            inc hsTailC
            .if hsTailC >= 15
                mov hsTailC, 0
                invoke NetSendProbe, 0, addr peerAddr
            .endif
        .endif
    .endif
    ; ---- 排空收包 ----
    mov lobbyDrain, 16
NF_Recv:
    mov fromLen, SIZEOF sockaddr_in
    invoke recvfrom, hSock, addr recvBuf, 64, 0, addr fromAddr, addr fromLen
    .if eax == SOCKET_ERROR
        jmp NF_Timeout
    .endif
    mov ebx, eax
    movzx eax, byte ptr recvBuf[0]
    .if eax == 'T'                     ; 会话36：LSP magic 字节对调形态并入 'W' 类
        cmp byte ptr recvBuf[1], 'W'
        jne NF_Next
        cmp byte ptr recvBuf[2], 'N'   ; "TWNET01" 探测：对局期不处理，忽略
        je NF_Next
        mov eax, 'W'
    .endif
    .if eax == 'W'
        .if ebx >= NET_PKT_SIZE
            invoke NetApplyRx, addr recvBuf, addr fromAddr
        .endif
    .elseif eax == 'L'
        .if ebx >= NET_LSR_SIZE
            invoke NetApplyRx, addr recvBuf, addr fromAddr
        .endif
    .elseif eax == 'J' || eax == 'P' || eax == 'S'   ; 会话37 ack/RTT；会话51 +'S'
        invoke NetHandleJP, ebx
    .endif
NF_Next:
    dec lobbyDrain
    .if lobbyDrain > 0
        jmp NF_Recv
    .endif
NF_Timeout:
    call NetCheckTimeout
    call NetMirrorExtrap             ; 会话39：断包空洞期镜像外推（正常 delta=0 空转）
    .if netDumpOn != 0
        call NetDumpTick
    .endif
    ret
NetFlush endp

; ------------------------------------------------------------
; NetShutdown —— 清理 socket 与转储文件
; ------------------------------------------------------------
NetShutdown proc
    .if hSock != 0 && hSock != INVALID_SOCKET
        invoke closesocket, hSock
        invoke WSACleanup
        mov hSock, 0
    .endif
    .if dumpHand != -1 && dumpHand != INVALID_HANDLE_VALUE
        invoke CloseHandle, dumpHand
        mov dumpHand, -1
    .endif
    ret
NetShutdown endp

; ------------------------------------------------------------
; 诊断转储（netloop 自动化验收，见 tools/net_loopback_test.py）
;   H 固定性 cookie 端口 pid —— 开文件即写
;   B hello start myStart peerKnown netTick stunSeen stunPort stunIp —— 大厅期每
;     16 tick（会话51 尾三列；快开局实例可能整局 0 行，证据以 T 行为准）
;   G 种子 局数 首图       —— NetEnterMatch 写（握手同种子证据）
;   T tick rx lost pk x0 y0 mx my a0 a1 hp1 sk1 ef1 aim1 b0 b1 m0 m1 pick rngm rtt
;     stunSeen stunPort stunIp       —— 每 tick 一行（对账：镜像跟随/技能镜像/
;                             弹雷计数/掉线位/公共流种子/会话37 平滑RTT/
;                             会话51 STUN观测点=对端公网端点交叉对账）
; ------------------------------------------------------------
DumpNum proc uses ebx ecx edx esi value: dword, pBuf: dword
    mov esi, pBuf
    mov eax, value
    .if eax == 0
        mov byte ptr [esi], '0'
        mov eax, 1
        ret
    .endif
    xor ecx, ecx
DN_Dig:
    .if eax == 0
        jmp DN_Out
    .endif
    xor edx, edx
    mov ebx, 10
    div ebx
    add dl, '0'
    mov dumpTmp[ecx], dl
    inc ecx
    jmp DN_Dig
DN_Out:
    xor eax, eax
DN_Wr:
    .if eax >= ecx
        jmp DN_Done
    .endif
    mov edx, ecx
    sub edx, eax
    dec edx
    movzx edx, byte ptr dumpTmp[edx]
    mov byte ptr [esi+eax], dl
    inc eax
    jmp DN_Wr
DN_Done:
    ret
DumpNum endp

DpStart proc
    mov dumpCur, offset dumpBuf
    ret
DpStart endp

DpByte proc b: dword
    mov ecx, dumpCur
    mov eax, b
    mov byte ptr [ecx], al
    inc ecx
    mov dumpCur, ecx
    ret
DpByte endp

DpTok proc v: dword
    mov ecx, dumpCur
    invoke DumpNum, v, ecx
    add dumpCur, eax
    mov ecx, dumpCur
    mov byte ptr [ecx], ' '
    inc ecx
    mov dumpCur, ecx
    ret
DpTok endp

DpEol proc
    mov ecx, dumpCur
    mov byte ptr [ecx], 10
    inc ecx
    mov eax, ecx
    sub eax, offset dumpBuf
    push eax
    push offset dumpBuf
    call DumpWrt
    call DpStart
    ret
DpEol endp

DumpWrt proc pBuf: dword, len: dword
    .if dumpHand != -1 && dumpHand != INVALID_HANDLE_VALUE
        invoke WriteFile, dumpHand, pBuf, len, NULL, NULL
    .endif
    ret
DumpWrt endp

NetDumpEnsure proc
    .if dumpHand == -1
        mov eax, offset dumpName
        .if isFixedPort != 0
            mov eax, offset dumpNameFix
        .endif
        invoke CreateFileA, eax, GENERIC_WRITE, 1, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
        mov dumpHand, eax
        call DpStart
        invoke DpByte, 'H'
        mov eax, isFixedPort
        invoke DpTok, eax
        mov eax, lobbySeed
        invoke DpTok, eax
        mov eax, ownPort
        invoke DpTok, eax
        invoke GetCurrentProcessId
        invoke DpTok, eax
        call DpEol
    .endif
    ret
NetDumpEnsure endp

NetDumpTick proc
    call NetDumpEnsure
    call DpStart
    invoke DpByte, 'T'
    mov eax, netTick
    invoke DpTok, eax
    mov eax, rxSeen
    invoke DpTok, eax
    mov eax, netLost
    invoke DpTok, eax
    mov eax, peerKnown
    invoke DpTok, eax
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].x
    invoke DpTok, eax
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].y
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].x
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].y
    invoke DpTok, eax
    mov eax, tanks[PLAYER_SELF*SIZEOF TANK].alive
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].alive
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].hp
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].skill
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].effOn
    invoke DpTok, eax
    mov eax, tanks[PLAYER_PEER*SIZEOF TANK].aimT
    invoke DpTok, eax
    ; 弹计数（按 owner）
    xor ecx, ecx
    xor eax, eax
DT_B0:
    .if ecx >= MAX_BULLETS
        jmp DT_B1
    .endif
    mov edx, ecx
    imul edx, edx, SIZEOF BULLET
    add edx, offset bullets
    cmp (BULLET ptr [edx]).active, 0
    je DT_B0n
    cmp (BULLET ptr [edx]).owner, 0
    jne DT_B0n
    inc eax
DT_B0n:
    inc ecx
    jmp DT_B0
DT_B1:
    invoke DpTok, eax
    mov ecx, 0
    mov eax, 0
DT_B2:
    .if ecx >= MAX_BULLETS
        jmp DT_M0
    .endif
    mov edx, ecx
    imul edx, edx, SIZEOF BULLET
    add edx, offset bullets
    cmp (BULLET ptr [edx]).active, 0
    je DT_B2n
    cmp (BULLET ptr [edx]).owner, 1
    jne DT_B2n
    inc eax
DT_B2n:
    inc ecx
    jmp DT_B2
DT_M0:
    invoke DpTok, eax
    mov ecx, 0
    mov eax, 0
DT_M1:
    .if ecx >= MAX_MINES
        jmp DT_M2
    .endif
    .if mineCell[ecx*4] != -1
        .if mineOwner[ecx*4] == 0
            inc eax
        .endif
    .endif
    inc ecx
    jmp DT_M1
DT_M2:
    invoke DpTok, eax
    mov ecx, 0
    mov eax, 0
DT_M3:
    .if ecx >= MAX_MINES
        jmp DT_P
    .endif
    .if mineCell[ecx*4] != -1
        .if mineOwner[ecx*4] == 1
            inc eax
        .endif
    .endif
    inc ecx
    jmp DT_M3
DT_P:
    invoke DpTok, eax
    mov eax, pickupType
    invoke DpTok, eax
    mov eax, rngMatch
    invoke DpTok, eax
    mov eax, netRttAvg               ; 会话37：末列平滑 RTT ms（旧解析器忽略尾列兼容）
    invoke DpTok, eax
    mov eax, stunSeen                ; 会话51 STUN步A：再追三列（对局内也可见证据，
    invoke DpTok, eax                ;   大厅 B 行对快开局实例可能一次不发）
    mov eax, stunPort
    invoke DpTok, eax
    mov eax, stunIp
    invoke DpTok, eax
    call DpEol
    ret
NetDumpTick endp

end
