# -*- coding: utf-8 -*-
# 会话46：英文模式文字错位复现 —— 切 EN 后逐屏截图（菜单/图鉴/HUD/暂停/技能/设置）。
import sys, os, time, subprocess
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

EXE = r"D:\tank-war-asm\tankwar.exe"
OUT = r"D:\tank-war-asm\shots46en"
os.makedirs(OUT, exist_ok=True)

def shot(h, name, tries=25):
    for k in range(tries):
        im = U.grab(h)
        if im.size[0] > 100 and im.size[1] > 100:
            im.save(os.path.join(OUT, name))
            return im
        time.sleep(0.4)
    raise RuntimeError('grab invalid')

def key(h, vk, dn):
    U.key(vk, dn)   # SendInput：GetAsyncKeyState 轮询输入必须真实注入

p = subprocess.Popen([EXE, "bot"])
h = None
t0 = time.time()
while time.time() - t0 < 8 and h is None:
    h = U.find_hwnd(p.pid)
    if h is None: time.sleep(0.2)
U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
time.sleep(1.0)
key(h,0x20,True); time.sleep(0.05); key(h,0x20,False)  # 开火解锁 idx0
time.sleep(0.4)
shot(h, "hud_cn.png")
time.sleep(4.2)
key(h,0x1B,True); time.sleep(0.06); key(h,0x1B,False)  # Esc 暂停层
time.sleep(0.4)
shot(h, "pause_cn.png")
U.click(h, 500, 445); time.sleep(0.8)                    # 退出游戏 -> 主菜单
shot(h, "menu_cn.png")
U.click(h, 550, 529); time.sleep(0.4)                    # LANG 行（i=7）切英文
shot(h, "menu_en.png")
U.click(h, 550, 436); time.sleep(0.5)                    # 成就图鉴
shot(h, "gal_en_p1.png")
U.click(h, 880, 300); time.sleep(0.3)                    # 下一页
shot(h, "gal_en_p2.png")
for pg in range(3):
    U.click(h, 40, 300); time.sleep(0.2)                 # 上一页回 p1
key(h,0x1B,True); time.sleep(0.05); key(h,0x1B,False); time.sleep(0.4)  # 回菜单
shot(h, "menu_en2.png")
U.click(h, 550, 253); time.sleep(0.4)                    # SET 设置页（i=3 y236+?）试
shot(h, "set_en.png")
U.click(h, 550, 529); time.sleep(0.3)                    # 若在菜单点LANG再切回；此处可能无效
print("alive:", p.poll() is None)
p.kill()
