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
SelfTestRun PROTO                   ; game.asm 无头自测（tankwar selftest）
UiForcePlay2 PROTO                  ; ui.asm 直入 2P 对局（tankwar play2）
UiForceNumSel PROTO                 ; ui.asm 直入人数选择页（tankwar numsel）
UiInit    PROTO                     ; ui.asm 界面
UiTick    PROTO
UiRender  PROTO
UiForceLanAuto PROTO                ; ui.asm 自动大厅 netloop
UiOnChar  PROTO :DWORD              ; ui.asm WM_CHAR 转发（手输 IP 编辑）
extern gameState :dword
extern netMode   :dword
extern netPaused :dword
extern pauseMode :dword
extern volumeLvl :dword
extern clickEvt  :dword
extern clickPX   :dword
extern clickPY   :dword
SndInit    PROTO
SndBgmStart PROTO
SndVolume  PROTO :DWORD

.data
    public hWnd                 ; gfx.asm / net.asm 需要引用主窗口句柄
    className   db "TankWarAsmWnd", 0
    appName     db "Tank War ASM M1 - P1: WASD+SPACE | P2: Arrows+ENTER | R restart", 0
    selftestArg db "selftest"
    play2Arg    db "play2"
    numselArg   db "numsel"
    netloopArg  db "netloop"
    play2Mode   dd 0
    numselMode  dd 0
    netloopMode dd 0
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
    ; "tankwar play2"：跳过菜单直接开 2P 本地对局
    .if play2Mode != 0
        invoke UiForcePlay2
    .endif
    ; "tankwar numsel"：直入人数选择页（截图验收）
    .if numselMode != 0
        invoke UiForceNumSel
    .endif
    ; "tankwar netloop"：直入联机大厅并自动握手开局（回环验收）
    .if netloopMode != 0
        invoke UiForceLanAuto
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
    invoke NetShutdown
    invoke GfxShutdown
    invoke ExitProcess, 0
WinMain endp

start:
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
    invoke WinMain
end start
