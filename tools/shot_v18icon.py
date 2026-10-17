# Session 18 acceptance: demo page 4 terrain animation + redesigned skill icons.
# ASCII only. Run from anywhere (paths resolved from __file__).
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m1test as T
import wallshot as W

# ---- part 1: demo page 4 (terrain), burst across the 480-tick loop ----
W.ARGS = []
W.launch()
T.tap(0x28)                     # DOWN -> GAMEPLAY DEMO item
time.sleep(0.3)
T.tap(0x0D)                     # ENTER (demoT resets to 0 here)
for _ in range(3):              # RIGHT x3 -> page index 3 ("4 / 6")
    T.tap(0x27)
    time.sleep(0.25)
for i in range(6):              # ~80 ticks apart: mud/ice/bump/walk/ground
    time.sleep(1.33)
    W.snap("s18_terrain_%d.png" % i)
W.proc.kill()
time.sleep(0.8)

# ---- part 2: skill guide pages (big icons, scale 3) ----
# NB: taps must be >1 UI poll apart or the menu eats both edges into one
# move (that bug made the first run land on GAMEPLAY DEMO instead).
W.ARGS = []
W.launch()
T.tap(0x28)
time.sleep(0.4)
T.tap(0x28)                     # DOWN, DOWN -> SKILL GUIDE item
time.sleep(0.4)
T.tap(0x0D)                     # ENTER -> page 0 (ice shield)
time.sleep(0.5)
W.snap("s18_icon1_shield.png")
pages = [(1, "icon2_laser"), (3, "icon4_ghost"), (4, "icon5_mine"),
         (7, "icon8_water"), (8, "icon9_phantom")]
cur = 0
for target, name in pages:
    for _ in range(target - cur):
        T.tap(0x27)             # RIGHT next page
        time.sleep(0.25)
    cur = target
    time.sleep(0.4)
    W.snap("s18_%s.png" % name)
W.proc.kill()
print("done")
