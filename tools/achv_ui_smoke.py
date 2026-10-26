# -*- coding: utf-8 -*-
# 会话40：成就图鉴 UI 冒烟 v2 —— 全部用消息坐标点击（键盘边沿采样有双计，弃用）
# 菜单项矩形: y=190+i*46 .. +34, x 440..660。i: 0 START 1 BOT 2 DEMO 3 SKILL
#             4 SET 5 LAN 6 ACH 7 EXIT 8 LANG
import sys, os, time
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

OUT = r"D:\tank-war-asm\shots40"
os.makedirs(OUT, exist_ok=True)

def shot(h, name, tries=6):
    for k in range(tries):
        im = U.grab(h)
        if im.size[0] > 100 and im.size[1] > 100:
            im.save(os.path.join(OUT, name))
            return im
        time.sleep(0.3)
    raise RuntimeError('grab size invalid: %s' % (im.size,))

def main():
    dat = r"D:\tank-war-asm\achv.dat"
    if os.path.exists(dat):
        os.remove(dat)
    p, h = U.launch()
    time.sleep(0.5)
    U.click(h, 550, 483); time.sleep(0.5)                 # ACHIEVEMENTS
    assert p.poll() is None, 'dead entering gallery'
    shot(h, "v2_gal_p1.png")
    U.click(h, 880, 300); time.sleep(0.3)
    shot(h, "v2_gal_p2.png")
    U.click(h, 880, 300); time.sleep(0.2)
    U.click(h, 880, 300); time.sleep(0.2)                 # -> p4 (末页)
    shot(h, "v2_gal_p4.png")
    U.click(h, 880, 300); time.sleep(0.2)                 # 越界点击应无效
    U.click(h, 108, 300); time.sleep(0.2)
    U.click(h, 108, 300); time.sleep(0.2)
    U.click(h, 108, 300); time.sleep(0.2)
    U.click(h, 108, 300); time.sleep(0.2)                 # 回 p1（第一下应停在 p1）
    shot(h, "v2_gal_p1_again.png")
    U.click(h, 500, 534); time.sleep(0.4)                 # 返回按钮
    assert p.poll() is None, 'dead after back'
    shot(h, "v2_menu_back.png")
    # —— 黑色人机直开局，开一火 → 首开锋芒解锁弹层 ——
    U.click(h, 550, 253); time.sleep(1.3)
    assert p.poll() is None, 'dead entering bot match'
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
    time.sleep(0.35)
    im = shot(h, "v2_play_full.png")
    im.crop((296, 36, 692, 100)).resize((792, 128)).save(os.path.join(OUT, "v2_toast.png"))
    print("achv.dat exists:", os.path.exists(dat))
    print("window alive (no AV):", p.poll() is None)
    p.kill()

main()
