# -*- coding: utf-8 -*-
# 会话41 DBG2：完整复刻 smoke 步序（含画廊段），每步验窗口句柄健康
import sys, os, struct, time, ctypes
from ctypes import wintypes
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U
user32 = ctypes.windll.user32
OUT = r"D:\tank-war-asm\shots41"
DAT = r"D:\tank-war-asm\achv.dat"
b = bytearray(196)
struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
open(DAT, 'wb').write(bytes(b))

def st(tag, h, p):
    rd = wintypes.RECT()
    user32.GetClientRect(h, ctypes.byref(rd))
    print("%-16s alive=%s IsWin=%d Vis=%d Rect=%dx%d" % (
        tag, p.poll() is None, user32.IsWindow(h), user32.IsWindowVisible(h),
        rd.right, rd.bottom), flush=True)

def shot(h, name):
    rd = wintypes.RECT()
    user32.GetClientRect(h, ctypes.byref(rd))
    if rd.right < 100:
        st("!!GRAB0 " + name, h, p)
        return
    U.grab(h).save(os.path.join(OUT, name))

p, h = U.launch()
time.sleep(0.6); st('launch', h, p)
U.click(h, 550, 483); time.sleep(0.5)           # 进画廊
shot(h, "t1_gal_p1.png"); st('gallery', h, p)
for _ in range(3):
    U.click(h, 880, 300); time.sleep(0.25)      # p4
shot(h, "t2_gal_p4.png"); st('p4', h, p)
U.key(0x33, True); time.sleep(0.08); U.key(0x33, False)
time.sleep(0.25); shot(h, "t3_gal_p3.png"); st('key3', h, p)
U.key(0x31, True); time.sleep(0.08); U.key(0x31, False)
time.sleep(0.25)
U.click(h, 500, 534); time.sleep(0.4); st('backmenu', h, p)
U.click(h, 550, 253); time.sleep(1.3); st('botmatch', h, p)
U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
time.sleep(5.0); st('fired', h, p)
shot(h, "t4_toast.png")
U.key(0x1B, True); time.sleep(0.08); U.key(0x1B, False); time.sleep(0.4); st('paused', h, p)
U.click(h, 500, 445); time.sleep(0.6); st('quitmenu', h, p)
shot(h, "t5_menu_badge.png"); st('g5done', h, p)
p.kill()
