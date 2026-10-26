; ============================================================
; main.asm —— 程序入口：Win32 窗口 + 主循环
; 主循环结构（固定步长）：
;   [循环] 取系统时间 -> 到达下一 tick 了吗？
;          是 -> InputSample -> GameUpdate -> NetFlush
;          每帧 -> GfxRender -> Sleep 让出 CPU
; 逻辑固定 60Hz，渲染尽力而为，二者解耦，联机同步才稳定。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

; ---- 外部模块接口 ----
GfxInit     PROTO                   ; gfx.asm  创建内存 DC / 加载资源
GfxRender   PROTO                   ; gfx.asm  绘制一帧
GfxShutdown PROTO                   ; gfx.asm  释放 GDI 资源
InputSample PROTO                   ; input.asm 采样键盘到输入快照
GameInit    PROTO                   ; game.asm 初始化地图/坦克/子弹
GameUpdate  PROTO                   ; game.asm 推进一个逻辑 tick
NetInit     PROTO                   ; net.asm  Winsock 初始化 + 绑定端口
NetFlush    PROTO                   ; net.asm  发送状态包 + 收包应用
NetShutdown PROTO                   ; net.asm  关闭 socket
AchvInit    PROTO                   ; achv.asm 读成就档（会话40）
AchvSave    PROTO                   ; achv.asm 退出兜底落盘（会话40）
SelfTestRun PROTO                   ; game.asm 无头自测（tankwar selftest）
RlHostMain  PROTO                   ; rlhost.asm 训练管道宿主（tankwar rlhost，会话47）
RlRecInit   PROTO :DWORD            ; rlhost.asm 实时对战推流初始化（tankwar rlrec，会话47）
RlRecPump   PROTO                   ; rlhost.asm 每逻辑 tick 推一帧采集数据报
UiForcePlay2 PROTO
UiForceBotMatch PROTO              ; ui.asm（会话38：人机挑战局入口）                  ; ui.asm 直入 2P 对局（tankwar play2）
UiForceNumSel PROTO                 ; ui.asm 直入人数选择页（tankwar numsel）
UiInit    PROTO                     ; ui.asm 界面
UiTick    PROTO
UiRender  PROTO
UiForceLanAuto PROTO                ; ui.asm 自动大厅 netloop
UiForceRelayAuto PROTO :DWORD       ; ui.asm 直入中继模式 netrelay（会话37）
UiOnChar  PROTO :DWORD              ; ui.asm WM_CHAR 转发（手输 IP 编辑）
extern gameState :dword
extern netMode   :dword
extern netPaused :dword
extern pauseMode :dword
extern volumeLvl :dword
extern clickEvt  :dword
extern clickPX   :dword
extern clickPY   :dword
extern botTrEn   :dword                ; 会话46：bottrace 仪表开关（bot.asm）
extern rlBotMask :dword                ; 会话47：NN 接管槽位图（rlbot.asm）
extern rlBotTrEn :dword                ; 会话47：rlbotdump 轨迹开关（rlbot.asm）
SndInit    PROTO
SndBgmStart PROTO
SndVolume  PROTO :DWORD

.data
    public hWnd                 ; gfx.asm / net.asm 需要引用主窗口句柄
    className   db "TankWarAsmWnd", 0
    appName     db "Tank War ASM M1 - P1: WASD+SPACE | P2: Arrows+ENTER | R restart", 0
    selftestArg db "selftest"
    rlhostArg   db "rlhost", 0      ; 会话47：RL 训练管道宿主
    rlrecArg    db "rlrec"          ; 会话47：实时对战推流（5 字符不含 NUL，可接 ":ip:port"）
    play2Arg    db "play2"
    botArg      db "bot", 0         ; 会话38：直开黑色人机挑战局
    botTrArg    db "bottrace", 0    ; 会话46：人机决策逐 tick CSV 仪表
    rlbotArg    db "rlbot", 0       ; 会话47 Phase3：槽0 换 NN 蒸馏网络
    rlbotDumpArg db "rlbotdump", 0  ; 会话47 Phase3：NN 决策二进制轨迹
    numselArg   db "numsel"
    netloopArg  db "netloop"
    netrelayArg db "netrelay"
    play2Mode   dd 0
    rlRecFlag   dd 0                ; 会话47：命令行命中 rlrec
    rlRecSpecP  dd 0                ; 会话47："rlrec:ip:port" 冒号后指针（0=默认回环）
    botModeArg  dd 0                ; 会话38："bot" 参数命中
    rlBotModeArg dd 0               ; 会话47："rlbot" 参数命中
    numselMode  dd 0
    netloopMode dd 0
    netrelayMode dd 0
    netrelayBuf db 32 dup (0)         ; "tankwar netrelay ip:port#room" 参数词（会话37）
    hInstance   dd ?
    hWnd        dd ?
    msg         MSG <?>
    wc          WNDCLASS <>
    ps          PAINTSTRUCT <>
    nextTick    dd ?                ; 下一个逻辑 tick 的目标时间
    winStyle    dd ?

.code

; ------------------------------------------------------------
; WndProc —— 窗口过程
; 只处理最小集合：PAINT（交给 GfxRender）、DESTROY（退出）
; 键盘输入统一在 InputSample 里用 GetAsyncKeyState 采样，
; 不走 WM_KEYDOWN，避免消息延迟影响手感。
; ------------------------------------------------------------
WndProc proc hWin:DWORD, uMsg:DWORD, wParam:DWORD, lParam:DWORD
    .if uMsg == WM_DESTROY
        invoke PostQuitMessage, NULL
        xor eax, eax
    .elseif uMsg == 201h                  ; WM_LBUTTONDOWN：点击坐标入队
        mov eax, lParam                   ; 客户区虚拟化坐标（DPI/多屏恒正确）
        and eax, 0FFFFh
        mov clickPX, eax
        mov eax, lParam
        shr eax, 16
        mov clickPY, eax
        mov clickEvt, 1
        xor eax, eax
    .elseif uMsg == WM_CHAR             ; 会话36：大厅手输 IP（ui 自行门控）
        invoke UiOnChar, wParam
        xor eax, eax
    .elseif uMsg == WM_PAINT
        invoke BeginPaint, hWin, addr ps
        invoke EndPaint, hWin, addr ps
        xor eax, eax
    .else
        invoke DefWindowProcA, hWin, uMsg, wParam, lParam
    .endif
    ret
WndProc endp

; ------------------------------------------------------------
; WinMain —— 注册窗口类、创建窗口、进入主循环
; ------------------------------------------------------------
WinMain proc
    local wr:RECT

    invoke GetModuleHandleA, NULL
    mov hInstance, eax

    mov winStyle, WS_OVERLAPPEDWINDOW and not (WS_MAXIMIZEBOX or WS_THICKFRAME)

    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, offset WndProc
    mov wc.hInstance, eax
    invoke LoadCursorA, NULL, IDC_ARROW
    mov wc.hCursor, eax
    mov wc.hbrBackground, COLOR_WINDOW + 1
    mov wc.lpszClassName, offset className
    invoke RegisterClassA, addr wc

    ; 按客户区 640x480 反推窗口外框尺寸
    mov wr.left, 0
    mov wr.top, 0
    mov wr.right, WND_W
    mov wr.bottom, WND_H
    invoke AdjustWindowRectEx, addr wr, winStyle, FALSE, NULL
    mov eax, wr.right
    sub eax, wr.left                     ; 外框宽
    mov edx, wr.bottom
    sub edx, wr.top                      ; 外框高
    invoke CreateWindowExA, NULL, addr className, addr appName,
           winStyle, CW_USEDEFAULT, CW_USEDEFAULT,
           eax, edx, NULL, NULL, hInstance, NULL
    mov hWnd, eax
    invoke ShowWindow, hWnd, SW_SHOW
    invoke UpdateWindow, hWnd

    ; ---- 各模块初始化 ----
    invoke GfxInit
    invoke UiInit
    invoke GameInit
    invoke NetInit
    invoke SndInit                    ; 程序化音频（BGM 文件 + 音效内存）
    invoke SndVolume, volumeLvl
    invoke SndBgmStart
    invoke AchvInit                 ; 会话40：成就档读入（无档/坏档静默零态；须晚于 SndInit 供解锁号角）
    ; "tankwar play2"：跳过菜单直接开 2P 本地对局
    .if play2Mode != 0
        invoke UiForcePlay2
    .endif
    ; "tankwar bot"：直开黑色人机挑战局（会话38）
    .if botModeArg != 0
        invoke UiForceBotMatch
        .if rlBotModeArg != 0
            or rlBotMask, 1 shl 0      ; 会话47 Phase3：NN 接管槽0=训练谱系 ego 槽
        .endif                         ;  （槽0 玩家物理/左侧出生；槽1 留启发式 BOT 物理对手）
    .endif
    ; "tankwar numsel"：直入人数选择页（截图验收）
    .if numselMode != 0
        invoke UiForceNumSel
    .endif
    ; "tankwar netloop"：直入联机大厅并自动握手开局（回环验收）
    .if netloopMode != 0
        invoke UiForceLanAuto
    .endif
    ; "tankwar netrelay ip:port#room"：直入大厅并连中继服务器（会话37 M3.5）
    .if netrelayMode != 0
        invoke UiForceRelayAuto, offset netrelayBuf
    .endif

    ; ---- 主循环：固定步长逻辑 + 每帧渲染 ----
    invoke GetTickCount
    mov nextTick, eax

MainLoop:
    ; ---- 全量抽取消息队列（会话 20 修复）----
    ; 旧版每轮只处理 1 条消息并 jmp Render，当轮逻辑 tick 被整轮跳过。
    ; 同时按住两键时按键自动重复约 60 条消息/秒（WM_KEYDOWN+WM_CHAR），
    ; 16ms 的 tick 近半被吞，表现为"转向+前进不能同时生效"。
    ; 输入本就由 GetAsyncKeyState 电平轮询（不依赖消息队列），
    ; tick 不被吞后多键并行自然恢复。
ML_Pump:
    invoke PeekMessageA, addr msg, NULL, 0, 0, PM_REMOVE
    .if eax != 0
        .if msg.message == WM_QUIT
            jmp ExitLoop
        .endif
        invoke TranslateMessage, addr msg
        invoke DispatchMessageA, addr msg
        jmp ML_Pump
    .endif

    ; 到达下一逻辑 tick 才推进游戏状态
    invoke GetTickCount
    .if eax >= nextTick
        add nextTick, TICK_MS
        .if eax > nextTick            ; 落后过多（渲染卡顿等）：基准直接跳到
            mov nextTick, eax         ; 当前时刻，不逐 tick 快进追帧
        .endif
        invoke UiTick              ; 1. 界面状态机（菜单/联机/对局切换）
        .if gameState == ST_PLAY   ; 2. 仅对局状态推进玩法（暂停时冻结）
            mov eax, pauseMode
            .if eax == 0
                .if netPaused != 0
                    invoke NetFlush    ; 会话36 掉线冻结：玩法停、收包继续（自愈）
                .else
                    invoke InputSample
                    invoke GameUpdate
                    invoke RlRecPump        ; 会话47：对局逐 tick 推流采集（未开 rlrec 时空转返回）
                    mov eax, netMode
                    .if eax != 0
                        invoke NetFlush    ; 3. 联机对局：交换状态包
                    .endif
                .endif
            .endif
        .endif
    .endif

Render:
    invoke UiRender                ; 4. 绘制（菜单或对局画面）
    invoke Sleep, 1                ; 让出 CPU 片
    jmp MainLoop

ExitLoop:
    invoke AchvSave                 ; 会话40：退出兜底落盘（自测中 achvNoSave=1 自动跳过）
    invoke NetShutdown
    invoke GfxShutdown
    invoke ExitProcess, 0
WinMain endp

start:
    ; ---- 会话47：命令行含 "rlhost" -> 进训练管道宿主后退出（从不建窗口）----
    invoke GetCommandLineA
    mov edi, eax
ArgScanRl:
    movzx eax, byte ptr [edi]
    .if eax == 0
        jmp NoRlHost
    .endif
    mov ebx, edi
    mov esi, offset rlhostArg
    mov ecx, 6        ; 会话47E修复：原为7（含串尾NUL）——rlhost 后再接任何
                      ;  参数词第7字节即错位永不命中、静默落穿 GUI 消息循环；
                      ;  改 6 字符子串匹配，与 rlbot/rlrec 扫描同风格
ArgCmpRl:
    mov al, [ebx]
    cmp al, [esi]
    jne ArgNextRl
    inc ebx
    inc esi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRl
    .endif
    ; ---- 会话47 Phase3："rlhost rlbot" -> 训练管内启用 NN（槽0 接管）；
    ;      "rlbotdump" 再叠落盘。与 GUI 分支同义：子串匹配，dump 必带 rlbot。
    ;      目的=同管道同 tick 直接对拍 asm obs 与 python build_obs。----
    invoke GetCommandLineA
    mov esi, eax
ArgScanRlbH:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoRlbH
    .endif
    mov ebx, esi
    mov edi, offset rlbotArg
    mov ecx, 5
ArgCmpRlbH:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNextRlbH
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRlbH
    .endif
    or rlBotMask, 1 shl 0
    jmp NoRlbH
ArgNextRlbH:
    inc esi
    jmp ArgScanRlbH
NoRlbH:
    invoke GetCommandLineA
    mov esi, eax
ArgScanRlbdH:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoRlBdH
    .endif
    mov ebx, esi
    mov edi, offset rlbotDumpArg
    mov ecx, 9
ArgCmpRlbdH:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNextRlbdH
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRlbdH
    .endif
    mov rlBotTrEn, 1
    jmp NoRlBdH
ArgNextRlbdH:
    inc esi
    jmp ArgScanRlbdH
NoRlBdH:
    ; ---- 会话50：rlhost 模式内 "bottrace" 子串 → 开启发式 bot 逐 tick CSV
    ;      仪表（botTrEn）。诊断 botAggro 用：los/dct/patrol/evOwn/inFire
    ;      逐闸可见。GUI 分支不受影响（此路只在管道模式走到）。----
    invoke GetCommandLineA
    mov esi, eax
ArgScanBtH:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoBtH
    .endif
    mov ebx, esi
    mov edi, offset botTrArg
    mov ecx, 8
ArgCmpBtH:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNextBtH
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmpBtH
    .endif
    mov botTrEn, 1
    jmp NoBtH
ArgNextBtH:
    inc esi
    jmp ArgScanBtH
NoBtH:
    invoke RlHostMain
    invoke ExitProcess, 0
ArgNextRl:
    inc edi
    jmp ArgScanRl
NoRlHost:
    ; ---- 会话47：命令行含 "rlrec" -> 开实时对战推流（可带 ":ip:port"）----
    invoke GetCommandLineA
    mov edi, eax
ArgScanRc:
    movzx eax, byte ptr [edi]
    .if eax == 0
        jmp NoRec
    .endif
    mov ebx, edi
    mov esi, offset rlrecArg
    mov ecx, 5
ArgCmpRc:
    mov al, [ebx]
    cmp al, [esi]
    jne ArgNextRc
    inc ebx
    inc esi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRc
    .endif
    mov rlRecFlag, 1
    movzx eax, byte ptr [ebx]           ; 紧邻冒号=自定义目标地址
    .if eax == ':'
        lea eax, [ebx + 1]
        mov rlRecSpecP, eax
    .endif
    jmp NoRec
ArgNextRc:
    inc edi
    jmp ArgScanRc
NoRec:
    ; 命令行含 "selftest" -> 跑无头自测后退出
    invoke GetCommandLineA
    mov esi, eax
ArgScan:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoSelfTest
    .endif
    mov ebx, esi
    mov edi, offset selftestArg
    mov ecx, 8
ArgCmp:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp
    .endif
    invoke SelfTestRun
    invoke ExitProcess, 0
ArgNext:
    inc esi
    jmp ArgScan
NoSelfTest:
    ; 再扫 "play2" -> 置直入对局标志
    invoke GetCommandLineA
    mov esi, eax
ArgScan2:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoPlay2
    .endif
    mov ebx, esi
    mov edi, offset play2Arg
    mov ecx, 5
ArgCmp2:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext2
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp2
    .endif
    mov play2Mode, 1
    jmp NoPlay2
ArgNext2:
    inc esi
    jmp ArgScan2
NoPlay2:
    ; 再扫 "numsel" -> 直入人数页标志
    invoke GetCommandLineA
    mov esi, eax
ArgScan3:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoNumSel
    .endif
    mov ebx, esi
    mov edi, offset numselArg
    mov ecx, 6
ArgCmp3:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext3
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp3
    .endif
    mov numselMode, 1
    jmp NoNumSel
ArgNext3:
    inc esi
    jmp ArgScan3
NoNumSel:
    ; 再扫 "netloop" -> 自动联机回环标志（会话36 双开验收）
    invoke GetCommandLineA
    mov esi, eax
ArgScan4:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoNetLoop
    .endif
    mov ebx, esi
    mov edi, offset netloopArg
    mov ecx, 7
ArgCmp4:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext4
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp4
    .endif
    mov netloopMode, 1
    jmp NoNetLoop
ArgNext4:
    inc esi
    jmp ArgScan4
NoNetLoop:
    ; 再扫 "netrelay" -> 中继直连标志，并从匹配处之后提取参数词入 netrelayBuf（会话37）
    invoke GetCommandLineA
    mov esi, eax
ArgScan5:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoNetRelay
    .endif
    mov ebx, esi
    mov edi, offset netrelayArg
    mov ecx, 8
ArgCmp5:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext5
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp5
    .endif
    mov netrelayMode, 1
    ; ebx 现指向 "netrelay" 之后：跳过 ' ' 与 '"'，拷贝至下一个分隔符（最长31字符）
    mov edi, offset netrelayBuf
    mov ecx, 31
RlySkip:
    movzx eax, byte ptr [ebx]
    .if eax == ' '
        inc ebx
        jmp RlySkip
    .endif
    .if eax == '"'
        inc ebx
        jmp RlySkip
    .endif
    jmp RlyCopy
RlyCopy:
    movzx eax, byte ptr [ebx]
    .if eax == 0
        jmp RlyDone
    .endif
    .if eax == ' '
        jmp RlyDone
    .endif
    .if eax == '"'
        jmp RlyDone
    .endif
    mov [edi], al
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp RlyCopy
    .endif
RlyDone:
    mov byte ptr [edi], 0
    jmp NoNetRelay
ArgNext5:
    inc esi
    jmp ArgScan5
NoNetRelay:
    ; ---- 会话38："tankwar bot" -> 直开黑色人机挑战局 ----
    invoke GetCommandLineA
    mov esi, eax
ArgScan6:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoBot
    .endif
    mov ebx, esi
    mov edi, offset botArg
    mov ecx, 3                      ; 会话46：只比 "bot" 三字符，终止符改看后继字节
ArgCmp6:                            ; （旧版比 "bot\0" 4字节，"bot bottrace" 中间
    mov al, [ebx]                   ;  的空格令匹配失败 -> bot 模式没进、仪表没数据）
    cmp al, [edi]
    jne ArgNext6
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp6
    .endif
    movzx eax, byte ptr [ebx]
    .if eax == 0 || eax == ' '
        mov botModeArg, 1
        jmp NoBot
    .endif
    jmp ArgNext6
ArgNext6:
    inc esi
    jmp ArgScan6
NoBot:
    ; ---- 会话46："tankwar bot bottrace" -> 人机决策逐 tick 写 tankwar_bottrace.csv ----
    invoke GetCommandLineA
    mov esi, eax
ArgScan7:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoBotTr
    .endif
    mov ebx, esi
    mov edi, offset botTrArg
    mov ecx, 8
ArgCmp7:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNext7
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmp7
    .endif
    mov botTrEn, 1
    jmp NoBotTr
ArgNext7:
    inc esi
    jmp ArgScan7
NoBotTr:
    ; ---- 会话47 Phase3："tankwar rlbot [rlbotdump]" -> 槽0换 NN 蒸馏网络 ----
    ; "rlbot" 子串匹配（不看终止符）：rlbotdump 亦命中 -> 自动带 bot 局
    invoke GetCommandLineA
    mov esi, eax
ArgScanRlb:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoRlBot
    .endif
    mov ebx, esi
    mov edi, offset rlbotArg
    mov ecx, 5
ArgCmpRlb:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNextRlb
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRlb
    .endif
    mov rlBotModeArg, 1
    mov botModeArg, 1                  ; rl 局也是 bot 挑战局（botMask 置位由 UiForceBotMatch 链）
    jmp NoRlBot
ArgNextRlb:
    inc esi
    jmp ArgScanRlb
NoRlBot:
    ; "rlbotdump" -> 逐 tick 决策轨迹二进制（rlbot.asm RlDump）
    invoke GetCommandLineA
    mov esi, eax
ArgScanRlbd:
    movzx eax, byte ptr [esi]
    .if eax == 0
        jmp NoRlBotDump
    .endif
    mov ebx, esi
    mov edi, offset rlbotDumpArg
    mov ecx, 9
ArgCmpRlbd:
    mov al, [ebx]
    cmp al, [edi]
    jne ArgNextRlbd
    inc ebx
    inc edi
    dec ecx
    .if ecx != 0
        jmp ArgCmpRlbd
    .endif
    mov rlBotTrEn, 1
    jmp NoRlBotDump
ArgNextRlbd:
    inc esi
    jmp ArgScanRlbd
NoRlBotDump:
    .if rlRecFlag != 0
        invoke RlRecInit, rlRecSpecP    ; 失败不拦游戏，仅 rlRecOn 保持 0
    .endif
    invoke WinMain
end start
