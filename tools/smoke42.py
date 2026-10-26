# -*- coding: utf-8 -*-
"""会话42 冒烟：主菜单 8 项无“人机”行 / 图鉴可达 / bot CLI 开局 /
弹层滑入-驻留-滑出无闪烁 / 人机同命。"""
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots42"
os.makedirs(OUT, exist_ok=True)

def find_hwnd(pid):
    return U.find_hwnd(pid)

def launch(args=None):
    p = subprocess.Popen([EXE] + (args or []))
    t0 = time.time()
    while time.time() - t0 < 8:
        h = find_hwnd(p.pid)
        if h:
            U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
            return p, h
        time.sleep(0.2)
    raise RuntimeError("window not found")

def main():
    # ---- 1 主菜单 ----
    p, h = launch()
    time.sleep(0.8)
    U.grab(h).save(os.path.join(OUT, "menu.png"))
    # 键盘走到底再越界：8 项 mod 回绕（第9次 Down 应回到首项=开始游戏）
    for i in range(9):
        U.key(0x28, True); time.sleep(0.04); U.key(0x28, False)
        time.sleep(0.06)
    U.grab(h).save(os.path.join(OUT, "menu_wrap9.png"))
    # 成就图鉴行（item5 y=190+5*46 .. +34）
    U.click(h, 550, 190 + 5 * 46 + 16)
    time.sleep(0.5)
    U.grab(h).save(os.path.join(OUT, "gallery.png"))
    U.key(0x1B, True); time.sleep(0.04); U.key(0x1B, False)   # Esc 回菜单
    time.sleep(0.3)
    p.kill()
    time.sleep(0.4)

    # ---- 2 bot CLI 直开 + 弹层时间线 ----
    p, h = launch(["bot"])
    T0 = time.time()
    time.sleep(1.5)
    U.grab(h).save(os.path.join(OUT, "botmatch.png"))
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)   # 开火=首开锋芒解锁
    time.sleep(0.10)
    U.grab(h).save(os.path.join(OUT, "toast_slidein.png"))    # ~6 tick 已滑入大半
    time.sleep(1.0)
    U.grab(h).save(os.path.join(OUT, "toast_hold.png"))       # 驻留中段
    time.sleep(3.75)
    U.grab(h).save(os.path.join(OUT, "toast_out1.png"))       # ~236: 滑出启动
    time.sleep(0.07)
    U.grab(h).save(os.path.join(OUT, "toast_out2.png"))       # ~240: 完全滑出
    print("alive=%s elapsed=%.2fs" % (h != 0 and U.user32.IsWindow(h), time.time() - T0))
    p.kill()

main()
