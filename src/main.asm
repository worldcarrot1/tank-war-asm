; ============================================================
; main.asm —— 程序入口：Win32 窗口 + 主循环
; 主循环结构（固定步长）：
;   [循环] 取系统时间 -> 到达下一 tick 了吗？
;          是 -> InputSample -> GameUpdate -> (NetFlush)
;          每帧 -> GfxRender -> Sleep 让出 CPU
; 逻辑固定 60Hz，渲染尽力而为，二者解耦，联机同步才稳定。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include windows.inc
include user32.inc
include kernel32.inc
include gdi32.inc
include ws2_32.inc
includelib user32.lib
includelib kernel32.lib
includelib gdi32.lib
includelib ws2_32.lib

include ..\inc\game.inc

; ---- 外部模块接口 ----
extern GfxInit       :proc        ; gfx.asm  创建内存 DC / 加载资源
extern GfxRender     :proc        ; gfx.asm  绘制一帧
extern GfxShutdown   :proc        ; gfx.asm  释放 GDI 资源
extern InputSample   :proc        ; input.asm 采样键盘到输入快照
extern GameInit      :proc        ; game.asm 初始化地图/坦克/子弹
extern GameUpdate    :proc        ; game.asm 推进一个逻辑 tick
extern NetInit       :proc        ; net.asm  Winsock 初始化 + 绑定端口
extern NetFlush      :proc        ; net.asm  发送状态包 + 收包应用
extern NetShutdown   :proc        ; net.asm  关闭 socket

.data
    className   db "TankWarAsmWnd", 0
    appName     db "Tank War ASM", 0
    hInstance   dd ?
    hWnd        dd ?
    msg         MSG <?>
    wc          WNDCLASS <?>
    ps          PAINTSTRUCT <?>
    nextTick    dd ?                ; 下一个逻辑 tick 的目标时间

.code

; ------------------------------------------------------------
; WndProc —— 窗口过程
; 只处理最小集合：PAINT（交给 GfxRender）、DESTROY（退出）
; 键盘输入统一在 InputSample 里用 GetAsyncKeyState 采样，
; 不走 WM_KEYDOWN，避免消息延迟影响手感。
; ------------------------------------------------------------
WndProc proc hWin:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
    .if uMsg == WM_DESTROY
        invoke PostQuitMessage, NULL
        xor eax, eax
    .elseif uMsg == WM_PAINT
        invoke BeginPaint, hWin, addr ps
        invoke EndPaint, hWin, addr ps
        xor eax, eax
    .else
        invoke DefWindowProc, hWin, uMsg, wParam, lParam
    .endif
    ret
WndProc endp

; ------------------------------------------------------------
; WinMain —— 注册窗口类、创建窗口、进入主循环
; ------------------------------------------------------------
WinMain proc
    invoke GetModuleHandle, NULL
    mov hInstance, eax

    mov wc.style, CS_HREDRAW or CS_VREDRAW
    mov wc.lpfnWndProc, offset WndProc
    mov wc.hInstance, eax
    mov wc.hbrBackground, COLOR_WINDOW + 1
    mov wc.lpszClassName, offset className
    invoke RegisterClass, addr wc

    ; 按客户区尺寸反推窗口外框尺寸
    invoke CreateWindowEx, NULL, addr className, addr appName,
           WS_OVERLAPPEDWINDOW and not (WS_MAXIMIZEBOX or WS_THICKFRAME),
           CW_USEDEFAULT, CW_USEDEFAULT, WND_W, WND_H,
           NULL, NULL, hInstance, NULL
    mov hWnd, eax
    invoke ShowWindow, hWnd, SW_SHOW
    invoke UpdateWindow, hWnd

    ; ---- 各模块初始化 ----
    call GfxInit
    call GameInit
    call NetInit

    ; ---- 主循环：固定步长逻辑 + 每帧渲染 ----
    invoke GetTickCount
    mov nextTick, eax

MainLoop:
    ; 处理所有待处理消息（不阻塞）
    invoke PeekMessage, addr msg, NULL, 0, 0, PM_REMOVE
    .if eax != 0
        .if msg.message == WM_QUIT
            jmp ExitLoop
        .endif
        invoke TranslateMessage, addr msg
        invoke DispatchMessage, addr msg
        jmp Render
    .endif

    ; 到达下一逻辑 tick 才推进游戏状态
    invoke GetTickCount
    .if eax >= nextTick
        add nextTick, TICK_MS
        call InputSample          ; 1. 采样键盘
        call GameUpdate           ; 2. 推进游戏逻辑
        call NetFlush             ; 3. 发状态包 + 收对方包
    .endif

Render:
    call GfxRender                ; 4. 绘制当前帧
    invoke Sleep, 1               ; 让出 CPU 片
    jmp MainLoop

ExitLoop:
    call NetShutdown
    call GfxShutdown
    invoke ExitProcess, 0
WinMain endp

start:
    invoke WinMain
end start
