# -*- coding: utf-8 -*-
# 会话41 DBG：定位 grab 0x0 的确切时点（每步 IsWindow/IsWindowVisible/GetClientRect）
import sys, os, struct, time, ctypes
from ctypes import wintypes
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U
user32 = ctypes.windll.user32
DAT = r"D:\tank-war-asm\achv.dat"
b = bytearray(196)
struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
open(DAT, 'wb').write(bytes(b))

def st(tag, h):
    rd = wintypes.RECT()
    user32.GetClientRect(h, ctypes.byref(rd))
    print("%-14s IsWin=%d Vis=%d Min=%d Rect=%dx%d" % (
        tag, user32.IsWindow(h), user32.IsWindowVisible(h),
        user32.IsIconic(h), rd.right, rd.bottom))

p, h = U.launch()
time.sleep(0.8); st('launch', h)
U.click(h, 550, 253); time.sleep(1.3); st('botmatch', h)
U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
time.sleep(5.0); st('fired', h)
U.key(0x1B, True); time.sleep(0.08); U.key(0x1B, False); time.sleep(0.5); st('paused', h)
U.click(h, 500, 445); time.sleep(1.0); st('quitmenu', h)
im = U.grab(h); print('grab', im.size)
im.save(r'D:\tank-war-asm\shots41\dbg_menu_badge.png')
st('saved', h)
p.kill()
