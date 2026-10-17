# Targeted capture: demo page 4 water-walk badge frames (tt 300..388 window).
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m1test as T
import wallshot as W

W.ARGS = []
W.launch()
T.tap(0x28); time.sleep(0.3)
T.tap(0x0D)                       # enter demo, demoT=0
for _ in range(3):
    T.tap(0x27); time.sleep(0.25) # page 3
for i in range(8):                # sweep tt ~ 60..520 in 30-tick steps
    time.sleep(0.5)
    W.snap("s18b_w_%d.png" % i)
W.proc.kill()
print("done")
