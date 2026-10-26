# -*- coding: utf-8 -*-
"""会话42：40 秒长窗观测人机是否最终逼近/命中静止玩家。"""
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots46"

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
    T0 = time.time()
    for at in (16, 22, 28, 34, 40):
        d = T0 + at - time.time()
        if d > 0:
            time.sleep(d)
        U.grab(h).save(os.path.join(OUT, "lv_%02d.png" % at))
    print("done elapsed=%.1f" % (time.time() - T0))
    p.kill()

main()
