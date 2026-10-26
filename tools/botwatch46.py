# -*- coding: utf-8 -*-
# 会话46：人机卡死角复现观测 —— `tankwar bot` 长跑，按秒截帧到 shots46/。
# 运动量化：取地图区 30..770 x 66..570，把每帧二值化后按 8px 网格聚出黑块
# （坦克/墙像素），比较相邻帧黑块质心位移；连续多帧位移≈0 即"卡死"证据。
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U
from PIL import Image

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots46"
os.makedirs(OUT, exist_ok=True)
DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 60
TAG = sys.argv[2] if len(sys.argv) > 2 else "r"

def grab_ok(h, tries=25):
    for k in range(tries):
        try:
            im = U.grab(h)
            if im.size[0] > 100 and im.size[1] > 100:
                return im
        except SystemError:
            pass
        time.sleep(0.2)
    raise RuntimeError('grab invalid')

def blackcells(im):
    """地图区暗像素 8px 网格计数 → dict[(cx,cy)]=count。墙是恒定的，
    坦克移动会让某些格计数变化；返回格集合+计数用于帧间 diff。"""
    g = im.convert("L").crop((30, 66, 770, 570))
    px = g.load()
    w, hh = g.size
    out = {}
    for by in range(0, hh - 7, 8):
        for bx in range(0, w - 7, 8):
            c = 0
            for y in range(by, by + 8):
                for x in range(bx, bx + 8):
                    if px[x, y] < 40:
                        c += 1
            if c >= 12:
                out[(bx, by)] = c
    return out

def diff_ratio(a, b):
    ka, kb = set(a), set(b)
    sym = len(ka ^ kb)
    changed = sum(1 for k in ka & kb if abs(a[k] - b[k]) >= 8)
    return sym + changed

def main():
    p = subprocess.Popen([EXE, "bot"])
    h = None
    t0 = time.time()
    while time.time() - t0 < 8:
        h = U.find_hwnd(p.pid)
        if h:
            U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
            break
        time.sleep(0.2)
    prev = None
    stall = 0
    worst = 0
    t0 = time.time()
    nxt = 2.0
    snapc = 0
    while time.time() - t0 < DUR:
        now = time.time() - t0
        if now >= nxt:
            im = grab_ok(h)
            cells = blackcells(im)
            d = diff_ratio(prev, cells) if prev is not None else 999
            prev = cells
            if d <= 1:                       # 帧间几乎无变化
                stall += 1
                worst = max(worst, stall)
                if stall in (4, 8, 16):      # 疑似卡死即留证截图
                    im.save(os.path.join(OUT, "%s_stall_%02ds.png" % (TAG, int(now))))
            else:
                stall = 0
            print("t=%5.1f d=%4d%s" % (now, d, "  STALLx%d" % stall if stall >= 3 else ""))
            if int(now) % 10 == 0 and now >= nxt:
                im.save(os.path.join(OUT, "%s_%02ds.png" % (TAG, int(now))))
            nxt = now + 1.5
            time.sleep(max(0, 1.5 - (time.time() - now)) if False else 0)
        time.sleep(0.05)
    grab_ok(h).save(os.path.join(OUT, "%s_end.png" % TAG))
    print("alive:", p.poll() is None, "worst_streak_frames:", worst)
    p.kill()

main()
