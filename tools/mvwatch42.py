# -*- coding: utf-8 -*-
"""会话42：人机对局长时段运动观测（倒计时后是否追击）。"""
import sys, os, time, shutil, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots42"

def launch(args=None):
    p = subprocess.Popen([EXE] + (args or []))
    t0 = time.time()
    while time.time() - t0 < 8:
        h = U.find_hwnd(p.pid)
        if h:
            U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
            return p, h
        time.sleep(0.2)
    raise RuntimeError("window not found")

def main():
    p, h = launch(["bot"])
    for t, name in ((2.0, "mv_a"), (6.0, "mv_b"), (9.0, "mv_c"), (12.0, "mv_d")):
        now = time.time()
        wait = t - (now - (now - 0))  # placeholder unused
    T0 = time.time()
    marks = [("mv_a", 2.0), ("mv_b", 5.0), ("mv_c", 8.0), ("mv_d", 12.0)]
    for name, at in marks:
        d = T0 + at - time.time()
        if d > 0:
            time.sleep(d)
        U.grab(h).save(os.path.join(OUT, name + ".png"))
    p.kill()

main()
