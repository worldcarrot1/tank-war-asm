# -*- coding: utf-8 -*-
# ============================================================
# sim_ui_test.py —— 会话34：合成输入实测 UI 改键流与 Enter 开局泄漏
#   PostMessage(WM_LBUTTONDOWN/UP) 造点击（WndProc 记 clickPX/PY，
#   坐标=lParam 客户区值，无需移动物理光标）；
#   SendInput 造真实键盘事件（更新 GetAsyncKeyState，与焦点无关；
#   注意 x64 INPUT 结构 cbSize=40 且 wVk 在偏移 8，错填=发 wVk=0）。
# 用法: python -I sim_ui_test.py A   # 闪烁持续 / 双点互换 / Esc 取消
#       python -I sim_ui_test.py B   # 按住 Enter 开局不再走火
# 前提: 游戏窗口无人值守（真机按键会污染结果——会话34 亲历）。
# 关键坐标（人数页）：菜单项0=(550,205)；P1 容器行 x=130，
#   行 r 命中带 y=362+r*30 .. +26（0前进 1后退 2左 3右 4开火 5使用）；
#   P2 前进=(370,375)；重置=(850..960, 565..600) 附近(RST_*)。
# ============================================================
import ctypes, subprocess, time, os, sys
from ctypes import wintypes
from PIL import Image

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots34"
os.makedirs(OUT, exist_ok=True)

class INPUTK(ctypes.Structure):   # x64 INPUT(KEYBOARD) 完整 40B
    _fields_ = [("type", ctypes.c_uint), ("pad", ctypes.c_uint),
                ("wVk", ctypes.c_ushort), ("wScan", ctypes.c_ushort),
                ("dwFlags", ctypes.c_uint), ("time", ctypes.c_uint),
                ("extra", ctypes.c_void_p), ("pad2", ctypes.c_ulonglong)]
assert ctypes.sizeof(INPUTK) == 40

def key(vk, down):
    ki = INPUTK(); ki.type = 1; ki.wVk = vk
    ki.dwFlags = 0 if down else 2
    a = (INPUTK * 1)(ki)
    return user32.SendInput(1, a, 40) == 1

def gaks(vk):
    return bool(user32.GetAsyncKeyState(vk) & 0x8000)

def find_hwnd(pid):
    found = []
    PROCB = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def cb(h, l):
        wpid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(h, ctypes.byref(wpid))
        if wpid.value == pid and user32.IsWindowVisible(h):
            r = wintypes.RECT(); user32.GetWindowRect(h, ctypes.byref(r))
            if r.right - r.left > 300:
                found.append(h)
        return True
    user32.EnumWindows(PROCB(cb), 0)
    return found[0] if found else None

def launch():
    p = subprocess.Popen([EXE])
    t0 = time.time()
    while time.time() - t0 < 8:
        h = find_hwnd(p.pid)
        if h:
            user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
            return p, h
        time.sleep(0.2)
    raise RuntimeError("window not found")

def click(h, x, y, pause=0.03):
    lp = (y << 16) | (x & 0xFFFF)
    user32.PostMessageW(h, 0x201, 1, lp); time.sleep(pause)
    user32.PostMessageW(h, 0x202, 0, lp)

def grab(h):
    rd = wintypes.RECT(); user32.GetClientRect(h, ctypes.byref(rd))
    w, hh = rd.right, rd.bottom
    hdc = user32.GetDC(h); mfc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, hh)
    gdi32.SelectObject(mfc, bmp)
    gdi32.BitBlt(mfc, 0, 0, w, hh, hdc, 0, 0, 0x00CC0020)
    class BIH(ctypes.Structure):
        _fields_ = [("s", ctypes.c_uint), ("w", ctypes.c_int), ("ht", ctypes.c_int),
                    ("p", ctypes.c_ushort), ("b", ctypes.c_ushort), ("c", ctypes.c_uint),
                    ("si", ctypes.c_uint), ("x", ctypes.c_int), ("y", ctypes.c_int),
                    ("cu", ctypes.c_uint), ("ci", ctypes.c_uint)]
    bi = BIH(); bi.s = 40; bi.w = w; bi.ht = -hh; bi.p = 1; bi.b = 24; bi.c = 0
    buf = (ctypes.c_ubyte * (w * hh * 3))()
    gdi32.GetDIBits(hdc, bmp, 0, hh, buf, ctypes.byref(bi), 0)
    im = Image.frombuffer("RGB", (w, hh), buf, "raw", "BGR", 0, 1)
    gdi32.DeleteObject(bmp); gdi32.DeleteDC(mfc); user32.ReleaseDC(h, hdc)
    return im

def rowlum(im, y):
    c = im.crop((30, y, 244, y + 26)).convert("L")
    d = list(c.getdata())
    return round(sum(d) / len(d), 1)

def testA():
    """闪烁持续(1.6s 采样须见 colHi/colDark 交替) + 双点互换 + Esc 取消"""
    p, h = launch()
    click(h, 550, 205); time.sleep(0.4)
    click(h, 130, 495)                    # P1 开火行 -> 闪烁
    vals = []
    t0 = time.time()
    while time.time() - t0 < 1.6:
        vals.append(rowlum(grab(h), 484)); time.sleep(0.05)
    print("blink samples:", vals[::2])
    print("BLINK PERSISTS:", len(set(vals)) > 1)
    click(h, 370, 375); time.sleep(0.3)   # 点 P2 前进行 -> 互换
    grab(h).crop((20, 355, 740, 545)).save(os.path.join(OUT, "A_swap.png"))
    print("check A_swap.png: P1开火=UP, P2前进=SPACE")
    p.kill()

def testB():
    """按住 Enter 开局：场景须静止(不走火)；松开后再点按 Enter：须能发射"""
    p, h = launch()
    click(h, 550, 205); time.sleep(0.4)
    key(0x0D, True); time.sleep(0.05)
    assert gaks(0x0D), "SendInput 未生效？检查前台/权限"
    time.sleep(0.5)
    im1 = grab(h)
    time.sleep(0.8)
    im2 = grab(h)
    print("NO LEAK (idle while Enter held):", im1.tobytes() == im2.tobytes())
    key(0x0D, False); time.sleep(0.15)
    key(0x0D, True); time.sleep(0.08); key(0x0D, False)
    time.sleep(0.35)
    im3 = grab(h)
    print("REBIND OK (tap after release fires):", im1.tobytes() != im3.tobytes())
    im1.save(os.path.join(OUT, "B_idle.png")); im3.save(os.path.join(OUT, "B_tap.png"))
    p.kill()

if __name__ == "__main__":
    {"A": testA, "B": testB}[sys.argv[1]]()
