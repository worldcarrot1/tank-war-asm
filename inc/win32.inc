; ============================================================
; win32.inc —— 本项目专用的精简 Win32 API 定义
; 只包含坦克大战用到的常量、结构体、函数原型，
; 不依赖 MASM32 SDK。所有导入函数使用 A（ANSI）后缀版本。
; ============================================================

; ---- 通用 ----
NULL        equ 0
FALSE       equ 0
TRUE        equ 1

; ---- 窗口类 / 窗口样式 ----
CS_HREDRAW          equ 0002h
CS_VREDRAW          equ 0001h
WS_OVERLAPPEDWINDOW equ 00CF0000h
WS_MAXIMIZEBOX      equ 00010000h
WS_THICKFRAME       equ 00040000h
CW_USEDEFAULT       equ 80000000h
SW_SHOW             equ 5
COLOR_WINDOW        equ 5
IDC_ARROW           equ 32512

; ---- 消息 ----
WM_DESTROY  equ 0002h
WM_PAINT    equ 000Fh
WM_QUIT     equ 0012h
PM_REMOVE   equ 0001h

; ---- 虚拟键码 ----
VK_SPACE    equ 020h
VK_A        equ 041h
VK_D        equ 044h
VK_R        equ 052h
VK_S        equ 053h
VK_W        equ 057h

; ---- GDI ----
SRCCOPY     equ 00CC0020h

; ---- Winsock ----
AF_INET         equ 2
SOCK_DGRAM      equ 2
IPPROTO_UDP     equ 17
FIONBIO         equ 8004667Eh
INADDR_ANY      equ 0
INVALID_SOCKET  equ -1
SOCKET_ERROR    equ -1

; ============================================================
; 结构体
; ============================================================
POINT STRUCT
    x       dd ?
    y       dd ?
POINT ENDS

MSG STRUCT
    hwnd    dd ?
    message dd ?
    wParam  dd ?
    lParam  dd ?
    time    dd ?
    pt      POINT <>
MSG ENDS

WNDCLASS STRUCT
    style          dd ?
    lpfnWndProc    dd ?
    cbClsExtra     dd ?
    cbWndExtra     dd ?
    hInstance      dd ?
    hIcon          dd ?
    hCursor        dd ?
    hbrBackground  dd ?
    lpszMenuName   dd ?
    lpszClassName  dd ?
WNDCLASS ENDS

RECT STRUCT
    left    dd ?
    top     dd ?
    right   dd ?
    bottom  dd ?
RECT ENDS

PAINTSTRUCT STRUCT
    hdc         dd ?
    fErase      dd ?
    rcPaint     RECT <>
    fRestore    dd ?
    fIncUpdate  dd ?
    rgbReserved db 32 dup(?)
PAINTSTRUCT ENDS

sockaddr_in STRUCT
    sin_family  dw ?
    sin_port    dw ?
    sin_addr    dd ?
    sin_zero    db 8 dup(?)
sockaddr_in ENDS

WSADATA STRUCT
    wVersion        dw ?
    wHighVersion    dw ?
    iMaxSockets     dw ?
    iMaxUdpDg       dw ?
    lpVendorInfo    dd ?
    szDescription   db 257 dup(?)
    szSystemStatus  db 129 dup(?)
WSADATA ENDS

; ============================================================
; 函数原型（全部 stdcall）
; ============================================================
; kernel32
GetModuleHandleA PROTO stdcall :DWORD
GetTickCount     PROTO stdcall
Sleep            PROTO stdcall :DWORD
ExitProcess      PROTO stdcall :DWORD

; user32
RegisterClassA     PROTO stdcall :DWORD
CreateWindowExA    PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
ShowWindow         PROTO stdcall :DWORD,:DWORD
UpdateWindow       PROTO stdcall :DWORD
PeekMessageA       PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD
TranslateMessage   PROTO stdcall :DWORD
DispatchMessageA   PROTO stdcall :DWORD
DefWindowProcA     PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD
PostQuitMessage    PROTO stdcall :DWORD
BeginPaint         PROTO stdcall :DWORD,:DWORD
EndPaint           PROTO stdcall :DWORD,:DWORD
GetAsyncKeyState   PROTO stdcall :DWORD
AdjustWindowRectEx PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD
LoadCursorA        PROTO stdcall :DWORD,:DWORD

; gdi32
GetDC                   PROTO stdcall :DWORD
ReleaseDC               PROTO stdcall :DWORD,:DWORD
CreateCompatibleDC      PROTO stdcall :DWORD
CreateCompatibleBitmap  PROTO stdcall :DWORD,:DWORD,:DWORD
SelectObject            PROTO stdcall :DWORD,:DWORD
DeleteObject            PROTO stdcall :DWORD
DeleteDC                PROTO stdcall :DWORD
CreateSolidBrush        PROTO stdcall :DWORD
FillRect                PROTO stdcall :DWORD,:DWORD,:DWORD
BitBlt                  PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD

; ws2_32（htons 实际参数是 16 位，这里按 32 位压栈，栈平衡不受影响）
WSAStartup      PROTO stdcall :DWORD,:DWORD
socket          PROTO stdcall :DWORD,:DWORD,:DWORD
ioctlsocket     PROTO stdcall :DWORD,:DWORD,:DWORD
htons           PROTO stdcall :DWORD
bind            PROTO stdcall :DWORD,:DWORD,:DWORD
sendto          PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
recvfrom        PROTO stdcall :DWORD,:DWORD,:DWORD,:DWORD,:DWORD,:DWORD
closesocket     PROTO stdcall :DWORD
WSACleanup      PROTO stdcall

; ---- 导入库（Windows SDK 的 um/x86 下可找到）----
INCLUDELIB kernel32.lib
INCLUDELIB user32.lib
INCLUDELIB gdi32.lib
INCLUDELIB ws2_32.lib
