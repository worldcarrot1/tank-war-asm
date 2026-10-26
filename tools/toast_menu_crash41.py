# -*- coding: utf-8 -*-
# 会话41 DBG3：toast 活跃窗口内回主菜单 -> 是否必死（3 轮）
import sys, os, struct, time, ctypes
from ctypes import wintypes
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U
user32 = ctypes.windll.user32
DAT = r"D:\tank-war-asm\achv.dat"

def one(run):
    b = bytearray(196)
    struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
    open(DAT, 'wb').write(bytes(b))
    p, h = U.launch()
    time.sleep(0.6)
    U.click(h, 550, 253); time.sleep(1.3)
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)   # ~T+1.9 解锁, toast 活到 ~T+5.9
    time.sleep(1.0)                                            # T+2.9 toast 正活跃
    U.key(0x1B, True); time.sleep(0.08); U.key(0x1B, False)
    time.sleep(0.3)
    U.click(h, 500, 445)                                       # 退出 -> 菜单（toast 仍活）
    time.sleep(0.8)
    rd = wintypes.RECT()
    user32.GetClientRect(h, ctypes.byref(rd))
    alive = p.poll() is None
    print("run%d alive=%s IsWin=%d rect=%dx%d" % (run, alive, user32.IsWindow(h), rd.right, rd.bottom), flush=True)
    if alive and rd.right > 10:
        try:
            U.grab(h).save(r'D:\tank-war-asm\shots41\dbg3_menu_toast_%d.png' % run)
        except Exception as e:
            print("  grab fail", e)
    if alive:
        p.kill()
    time.sleep(0.5)

for r in range(3):
    one(r)
