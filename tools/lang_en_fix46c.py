# -*- coding: utf-8 -*-
# 会话46c：英文错位修复验收 —— 人数页 ROUNDS « / 图鉴页眉行 / 行首品阶词×chip。
# 两条链：EN（点 LANG 后 START→人数页、ESC 回、ACH→图鉴 1/2 页）与 CN 同路径回归。
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots46en"

def shot(h, name, tries=25):
    for k in range(tries):
        im = U.grab(h)
        if im.size[0] > 100 and im.size[1] > 100:
            im.save(os.path.join(OUT, name)); return im
        time.sleep(0.4)
    raise RuntimeError('grab invalid')

def esc(h, d=0.4):
    U.key(0x1B, True); time.sleep(0.05); U.key(0x1B, False); time.sleep(d)

def run(tag, en):
    p = subprocess.Popen([EXE])
    h = None
    t0 = time.time()
    while time.time() - t0 < 8 and h is None:
        h = U.find_hwnd(p.pid)
        if h is None: time.sleep(0.2)
    U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
    time.sleep(1.0)
    if en:
        U.click(h, 550, 529); time.sleep(0.3)          # LANG -> EN
    U.click(h, 550, 207); time.sleep(0.5)
    shot(h, "%s_numply.png" % tag)                      # START -> 人数页
    esc(h)                                              # 回主菜单
    U.click(h, 550, 436); time.sleep(0.5)
    shot(h, "%s_gal_p1.png" % tag)                      # ACH -> 图鉴 p1
    U.click(h, 880, 300); time.sleep(0.4)
    shot(h, "%s_gal_p2.png" % tag)                      # 下一页
    print(tag, "alive:", p.poll() is None)
    p.kill()

run("fix_en", True)
run("fix_cn", False)
