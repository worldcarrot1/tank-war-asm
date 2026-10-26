# -*- coding: utf-8 -*-
"""会话42：临时清 achv.dat 复现首开锋芒弹层全生命周期（用毕还原）。"""
import sys, os, time, shutil, struct, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
DAT = r"D:\tank-war-asm\achv.dat"
BAK = r"D:\tank-war-asm\achv.dat.bak42"
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
    if os.path.exists(DAT):
        shutil.copy2(DAT, BAK)
        os.remove(DAT)
    try:
        p, h = launch(["bot"])
        time.sleep(1.5)
        U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
        for i in range(12):
            time.sleep(0.35)
            im = U.grab(h)
            im.save(os.path.join(OUT, "t42_%02d.png" % i))
        p.kill()
        print("shots done")
    finally:
        if os.path.exists(BAK):
            shutil.move(BAK, DAT)
            print("achv.dat restored")

main()
