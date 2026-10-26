# -*- coding: utf-8 -*-
"""会话46 DEBUG：ctypes 最小调试器，抓 tankwar 首次未处理异常的
code/地址/关键寄存器，然后 kill。"""
import ctypes, ctypes.wintypes as wt, struct

k32 = ctypes.windll.kernel32

class CTX(ctypes.Structure):
    _fields_ = [("ctxflags", wt.DWORD)] + \
               [("dr%d" % i, wt.DWORD) for i in range(8)] + \
               [("rest", ctypes.c_byte * (0x98 - 4 - 32))] + \
               [("Eax", wt.DWORD), ("Ecx", wt.DWORD), ("Edx", wt.DWORD),
                ("Ebx", wt.DWORD), ("Esp", wt.DWORD), ("Ebp", wt.DWORD),
                ("Esi", wt.DWORD), ("Edi", wt.DWORD), ("Eip", wt.DWORD)]

class ER(ctypes.Structure):
    _fields_ = [("code", wt.DWORD), ("flags", wt.DWORD),
                ("rec", wt.DWORD), ("addr", wt.DWORD),
                ("nparams", wt.DWORD), ("params", wt.DWORD * 15)]

class EP(ctypes.Structure):
    _fields_ = [("rec", wt.DWORD), ("ctx", wt.DWORD)]

class EXCEPTION_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("ep", EP), ("first_chance", wt.DWORD)]

class EVENT(ctypes.Structure):
    _fields_ = [("code", wt.DWORD), ("dword", wt.DWORD),
                ("data", ctypes.c_byte * 168)]

STARTF_USESHOWWINDOW = 0x0002
DEBUG_PROCESS = 1
WAIT_TIMEOUT = 258
CONTINUE = 0x00010002
DBG_TERMINATE_PROCESS = 2

class SI(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("lpRes", wt.LPSTR), ("lpDS", wt.LPSTR),
                ("lpTitle", wt.LPSTR), ("dwX", wt.DWORD), ("dwY", wt.DWORD),
                ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
                ("dwXCount", wt.DWORD), ("dwYCount", wt.DWORD),
                ("dwBufSize", wt.DWORD), ("dwHBufSize", wt.DWORD),
                ("dwFill", wt.DWORD), ("dwFlags", wt.DWORD),
                ("wShow", wt.WORD), ("cbRSv", wt.WORD), ("lpRSv", wt.LPSTR),
                ("lpDT", wt.LPSTR), ("lpCS", wt.LPSTR), ("lpPDS", wt.LPSTR)]

class PI(ctypes.Structure):
    _fields_ = [("hP", wt.HANDLE), ("hT", wt.HANDLE), ("pid", wt.DWORD),
                ("tid", wt.DWORD)]

si = SI(); si.cb = ctypes.sizeof(SI); si.wShow = 0; si.dwFlags = STARTF_USESHOWWINDOW
pi = PI()
cmd = ctypes.create_string_buffer(rb"D:\tank-war-asm\tankwar.exe bot")
ok = k32.CreateProcessA(None, cmd, None, None, 0, DEBUG_PROCESS, None,
                        r"D:\tank-war-asm", ctypes.byref(si), ctypes.byref(pi))
assert ok, ctypes.get_last_error()
ev = EVENT()
deadline = 40
import time; t0 = time.time()
while time.time() - t0 < deadline:
    r = k32.WaitForDebugEvent(ctypes.byref(ev), 1000)
    if r == WAIT_TIMEOUT:
        continue
    if r == 0:
        break
    if ev.code == 1:  # EXCEPTION
        edi = EXCEPTION_DEBUG_INFO.from_buffer(ev.data)
        if not edi.first_chance:
            print("2nd chance code=%08x addr=%08x" % (edi.ep.rec, 0))
        er = ER(); k32.ReadProcessMemory(pi.hP, edi.ep.rec, ctypes.byref(er), ctypes.sizeof(ER), None)
        ctx = CTX(); k32.ReadProcessMemory(pi.hP, edi.ep.ctx, ctypes.byref(ctx), ctypes.sizeof(CTX), None)
        if er.code in (0x40010004, 0xE06D7363):
            k32.ContinueDebugEvent(ev.pid, ev.tid, CONTINUE); continue
        print("EXC %08x addr=%08x" % (er.code, er.addr))
        print(" eip=%08x eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x" %
              (ctx.Eip, ctx.Eax, ctx.Ecx, ctx.Edx, ctx.Ebx, ctx.Esp, ctx.Ebp, ctx.Esi, ctx.Edi))
        k32.TerminateProcess(pi.hP, 9)
        break
    k32.ContinueDebugEvent(ev.pid, ev.tid, CONTINUE)
    if ev.code == 6:  # EXIT_PROCESS
        print("exit code=%08x" % ctypes.c_uint.from_buffer(ev.data, 8).value)
        break
k32.CloseHandle(pi.hP); k32.CloseHandle(pi.hT)
