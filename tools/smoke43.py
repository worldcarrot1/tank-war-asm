# -*- coding: utf-8 -*-
"""会话43：CC0 采样音效实机冒烟——bot 局跑 14 秒（开炮/爆炸/拾取/号角都会
触发 PlaySound），验证进程存活、窗口在、截图正常、无 AV 弹窗。"""
import sys, os, time, subprocess
sys.path.insert(0, r"D:\tank-war-asm\tools")
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots43"
os.makedirs(OUT, exist_ok=True)

def main():
    p = subprocess.Popen([EXE, "bot"])
    t0 = time.time()
    h = None
    while time.time() - t0 < 8:
        h = U.find_hwnd(p.pid)
        if h:
            break
        time.sleep(0.2)
    assert h, "window not found"
    U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
    for at in (6, 10, 14):
        d = t0 + at - time.time()
        if d > 0:
            time.sleep(d)
        alive = p.poll() is None
        print("t=%2ds alive=%s hwnd=%s" % (at, alive, bool(U.find_hwnd(p.pid))))
        if alive:
            U.grab(h).save(os.path.join(OUT, "s43_%02d.png" % at))
    code = p.poll()
    if code is None:
        time.sleep(1)
        p.kill()
        print("OK: survived 14s of sample playback, killed by harness")
    else:
        print("FAIL: process exited early with code %s" % code)

main()
