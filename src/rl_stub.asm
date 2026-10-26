; ============================================================
; rl_stub.asm —— 会话47：RL 训练 DLL 的桩模块
; tankwar_rl.dll 只链接 game/bot/achv/input + 本文件 + rl.asm。
; game.asm 引用了 ui.asm/net.asm/sound.asm 的数据与过程（联机与
; 音频在训练环境里不存在），此处统一提供零值/空操作实现。
; 桩签名必须与 game.asm 里的 PROTO 完全一致（stdcall 修饰名匹配）。
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

.data
    public netMode
    public numPlayers
    public onlineBanT
    public netRole
    public lobbySeed
    public relayMode
    public manualMode
    public relayRoom
    public netTick
    public lastRxTick
    public mirVX
    public mirVY
    public peerKnown
    public netLost
    netMode     dd 0
    numPlayers  dd 2
    onlineBanT  dd 0
    netRole     dd 0
    lobbySeed   dd 0
    relayMode   dd 0
    manualMode  dd 0
    relayRoom   dd 0
    netTick     dd 0
    lastRxTick  dd 0
    mirVX       dd 0
    mirVY       dd 0
    peerKnown   dd 0
    netLost     dd 0

.code

; ---- sound.asm 桩：训练环境不出声 ----
SndPlay proc stdcall uses ecx sndId:DWORD
    ret
SndPlay endp

; ---- net.asm 桩：单机训练路径本就跳过，防御性给恒等返回 ----
NetApplyPacket proc stdcall uses ecx apply:DWORD
    xor eax, eax
    ret
NetApplyPacket endp

NetMirrorExtrap proc stdcall
    ret
NetMirrorExtrap endp

ParseIp proc stdcall uses ecx pStr:DWORD, pIp:DWORD, pPort:DWORD
    xor eax, eax
    ret
ParseIp endp

ParseServerSpec proc stdcall uses ecx pStr:DWORD, pIp:DWORD, pPort:DWORD, pRoom:DWORD
    xor eax, eax
    ret
ParseServerSpec endp

NetSetServer proc stdcall uses ecx pSpec:DWORD
    xor eax, eax
    ret
NetSetServer endp

NetResetTargets proc stdcall
    ret
NetResetTargets endp

end
