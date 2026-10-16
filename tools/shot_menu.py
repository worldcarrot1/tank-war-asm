# Acceptance: bilingual main menu (EN + CN toggle) + all-thin walls match.
# ASCII only. Run from tools/.
import ctypes, sys, time, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m1test as T
import wallshot as W

user32 = ctypes.windll.user32

# ---- part 1: main menu EN -> toggle LANGUAGE -> CN ----
W.ARGS = []                          # no args -> main menu
W.launch()
W.snap("m1_menu_en.png")

# menu order: 0 START, 1 SETTINGS, 2 LAN, 3 EXIT, 4 LANGUAGE
# single UP from item 0 wraps to item 4 (fewer keypresses = fewer lost edges)
T.tap(0x26)                          # UP -> LANGUAGE
time.sleep(0.5)
T.tap(0x0D)                          # Enter -> toggle CN
time.sleep(0.6)
W.snap("m2_menu_cn.png")

W.proc.kill()
time.sleep(0.8)

# ---- part 2: all-thin-wall match, longer barrel ----
W.ARGS = ["play2"]
W.launch()
W.snap("g1_all_thin.png")

# P1 turn up + fire (shows longer barrel + bullet)
T.tap(0x26)                          # P1 up (W)
time.sleep(0.3)
T.tap(0x20)                          # fire
time.sleep(0.4)
W.snap("g2_fire_barrel.png")

W.proc.kill()
print("done")
