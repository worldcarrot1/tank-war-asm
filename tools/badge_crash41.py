# -*- coding: utf-8 -*-
# 会话41 DBG：定位 bot局->暂停->退出主菜单->(新)角标菜单 渲染是否崩溃
import sys, os, struct, time
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U
DAT = r"D:\tank-war-asm\achv.dat"
b = bytearray(196)
struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
open(DAT, 'wb').write(bytes(b))
p, h = U.launch()
time.sleep(0.8)
print('alive menu:', p.poll() is None)
U.click(h, 550, 253); time.sleep(1.3)          # BOT 对战
U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)  # 开火解锁 -> unseen=1
time.sleep(5.0)                                 # 等弹层走完
print('alive match:', p.poll() is None)
U.key(0x1B, True); time.sleep(0.08); U.key(0x1B, False)  # Esc 暂停
time.sleep(0.5)
U.click(h, 500, 445); time.sleep(1.0)          # 退出游戏 -> 主菜单（渲染新角标）
print('alive back-menu:', p.poll() is None, 'exit=%s' % p.poll())
if p.poll() is None:
    im = U.grab(h)
    im.save(r'D:\tank-war-asm\shots41\dbg_menu_badge.png')
    print('grab size', im.size)
    p.kill()
