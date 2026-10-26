# -*- coding: utf-8 -*-
# 会话46b：EN 其余屏复现（设置/技能/大厅/暂停/HUD）。启动即点 LANG 切 EN。
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

p = subprocess.Popen([EXE])   # 正常到主菜单
h = None
t0 = time.time()
while time.time() - t0 < 8 and h is None:
    h = U.find_hwnd(p.pid)
    if h is None: time.sleep(0.2)
U.user32.SetWindowPos(h, 0, 100, 60, 0, 0, 0x0001 | 0x0040)
time.sleep(1.0)
U.click(h, 550, 529); time.sleep(0.3)                 # LANG -> EN
shot(h, "b_menu_en.png")
U.click(h, 550, 299); time.sleep(0.4); shot(h, "b_skill_en.png")   # i=2 SKILL y=282..316
U.click(h, 550, 299); time.sleep(0.3)
U.key(0x1B, True); time.sleep(0.05); U.key(0x1B, False); time.sleep(0.3)  # 回菜单
shot(h, "b_menu_en2.png")
U.click(h, 550, 345); time.sleep(0.4); shot(h, "b_set_en.png")     # i=3 SETTING y=328..362
U.key(0x1B, True); time.sleep(0.05); U.key(0x1B, False); time.sleep(0.3)
U.click(h, 550, 391); time.sleep(0.6); shot(h, "b_lan_en.png")     # i=4 LAN y=374..408
U.key(0x1B, True); time.sleep(0.05); U.key(0x1B, False); time.sleep(0.4)
shot(h, "b_lan_en2.png")
U.key(0x1B, True); time.sleep(0.05); U.key(0x1B, False); time.sleep(0.4)
shot(h, "b_menu_en3.png")
U.click(h, 550, 207); time.sleep(0.5); shot(h, "b_numply_en.png")  # START -> 人数页
U.click(h, 550, 300); time.sleep(0.6); shot(h, "b_hud_en.png")     # 1P? 点开局区域(容错)
print("alive:", p.poll() is None)
p.kill()
