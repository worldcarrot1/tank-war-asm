# -*- coding: utf-8 -*-
# 会话45：成就 UI 图标化冒烟 —— 图鉴（锁定/解锁行 24px 图标+chip）、页眉品阶徽标、
# 解锁弹层（横幅加宽 252..740 + 左侧图标）。
# 会话42 起主菜单 8 项（无人机行）：i: 0 START 1 DEMO 2 SKILL 3 SET 4 LAN 5 ACH 6 EXIT 7 LANG
# 菜单项矩形 y=190+i*46..+34, x 440..660；ACH 点击坐标 = 550, 436。
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots45"
os.makedirs(OUT, exist_ok=True)

def shot(h, name, tries=25):
    for k in range(tries):
        im = U.grab(h)
        if im.size[0] > 100 and im.size[1] > 100:
            im.save(os.path.join(OUT, name))
            return im
        time.sleep(0.4)
    raise RuntimeError('grab size invalid: %s' % (im.size,))

def main():
    dat = r"D:\tank-war-asm\achv.dat"
    if os.path.exists(dat):
        os.remove(dat)                       # 全新档：仅首开锋芒会点亮
    p = subprocess.Popen([EXE, "bot"])       # 直开人机局
    h = None
    t0 = time.time()
    while time.time() - t0 < 8 and h is None:
        h = U.find_hwnd(p.pid)
        if h is None:
            time.sleep(0.2)
    U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
    time.sleep(0.8)
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)   # 开火 → 解锁 idx0
    time.sleep(0.35)
    im = shot(h, "play_toast.png")
    im.crop((252, 28, 740, 100)).resize((976, 144)).save(os.path.join(OUT, "toast_crop.png"))
    time.sleep(4.2)                          # 弹层 240tick 走完
    U.key(0x1B, True); time.sleep(0.06); U.key(0x1B, False)   # Esc → 暂停层
    time.sleep(0.4)
    U.click(h, 500, 445); time.sleep(0.8)    # 退出游戏 → 主菜单
    assert p.poll() is None, 'dead returning to menu'
    U.click(h, 550, 436); time.sleep(0.5)    # 成就图鉴（i=5）
    assert p.poll() is None, 'dead entering gallery (icons?)'
    shot(h, "gal_p1_mixed.png")              # 首行解锁点亮 + 其余锁定灰
    U.click(h, 880, 300); time.sleep(0.3)
    shot(h, "gal_p2_locked.png")
    U.click(h, 880, 300); time.sleep(0.2)
    U.click(h, 880, 300); time.sleep(0.3)
    shot(h, "gal_p4_locked.png")             # 末页（计数类）
    im = U.grab(h)
    im.crop((130, 100, 858, 160)).save(os.path.join(OUT, "badges_crop.png"))  # 页眉徽标带
    # —— 深夜主题：设置(550,343) → 深夜切换钮(540,406) → 返回(500,480) → 图鉴 ——
    U.click(h, 500, 534); time.sleep(0.4)                 # 图鉴返回
    U.click(h, 550, 190 + 3 * 46 + 16); time.sleep(0.4)   # 设置
    U.click(h, 540, 406); time.sleep(0.3)                 # 深夜模式 开
    U.click(h, 500, 480); time.sleep(0.4)                 # 返回主菜单
    U.click(h, 550, 436); time.sleep(0.5)                 # 图鉴（夜）
    assert p.poll() is None, 'dead in night gallery'
    shot(h, "gal_night_p1.png")
    print("achv.dat exists:", os.path.exists(dat))
    print("window alive (no AV):", p.poll() is None)
    p.kill()

main()
