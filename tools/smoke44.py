# -*- coding: utf-8 -*-
"""会话44：效用评分人机实机冒烟。

`tankwar bot` 开一局，用 SendInput 给玩家槽喂键盘（WASD 走位 + 空格连射），
让场内真的飞弹——检验 BotUtu 威胁场在实机路径下不崩、不卡死：
  1) 进程 20 秒存活（无 AV / 无僵死窗口）；
  2) 人机坦克（近黑块）在相邻两张截图间发生位移（不是钉死在原地）；
  3) 截图存档 shots44/ 供肉眼复查。
GetAsyncKeyState 读键，故必须 SendInput（真注入）而非 PostMessage。"""
import ctypes, os, sys, time

sys.path.insert(0, r"D:\tank-war-asm\tools")
from sim_ui_test import find_hwnd, key, grab, user32

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots44"
DUR = 20


def bot_boxes(im):
    """粗找：把近黑像素聚成 32px 网格，返回格坐标集合（人机车体所在）。"""
    g = {}
    px = im.load()
    w, hh = im.size
    for y in range(0, hh, 2):
        for x in range(0, w, 2):
            r, gg, b = px[x, y][:3]
            if r < 40 and gg < 40 and b < 40:
                g[(x // 32, y // 32)] = g.get((x // 32, y // 32), 0) + 1
    return set(k for k, v in g.items() if v >= 12)


def main():
    os.makedirs(OUT, exist_ok=True)
    import subprocess
    p = subprocess.Popen([EXE, "bot"])
    t0 = time.time()
    h = None
    while time.time() - t0 < 8:
        h = find_hwnd(p.pid)
        if h:
            break
        time.sleep(0.2)
    assert h, "window not found"
    user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
    user32.SetForegroundWindow(h)
    time.sleep(0.4)

    keys = ["w", "a", "s", "d"]
    vkw = {"w": 0x57, "a": 0x41, "s": 0x53, "d": 0x44}
    seq = ["w", "d", "s", "a"]
    i = 0
    prev = None
    moved = 0
    snaps = []
    while time.time() - t0 < DUR:
        now = time.time() - t0
        # 每 0.5s 换一个移动键，全程按住空格连射
        vk = vkw[seq[i % 4]]
        old = vkw[keys[(i - 1) % 4]] if i else None
        if old and old != vk:
            key(old, False)
        key(vk, True)
        key(0x20, True)
        i += 1
        time.sleep(0.5)
        if int(now) in (5, 10, 15, 19) and int(now) not in snaps:
            snaps.append(int(now))
            if p.poll() is None:
                im = grab(h)
                im.save(os.path.join(OUT, "s44_%02d.png" % int(now)))
                boxes = bot_boxes(im)
                if prev is not None and boxes != prev:
                    moved += 1
                prev = boxes
                print("t=%2ds alive=True black_cells=%d" % (int(now), len(boxes)))
    for vk in vkw.values():
        key(vk, False)
    key(0x20, False)
    code = p.poll()
    if code is not None:
        print("FAIL: process exited early, code=%s" % code)
        return 1
    p.kill()
    ok = moved >= 1
    print("OK" if ok else "FAIL: 人机像素全程未变（疑似钉死）")
    return 0 if ok else 1


sys.exit(main())
