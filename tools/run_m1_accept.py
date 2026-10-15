# M1 acceptance driver: launch game, take screenshots with key input, kill.
import ctypes, subprocess, sys, time, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m1test as T

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "tankwar.exe")
OUT = ROOT

proc = subprocess.Popen([EXE], cwd=ROOT)
time.sleep(1.5)

def snap(name):
    time.sleep(0.2)
    d = T.diag()
    print(name, d, "game_alive=", proc.poll() is None)
    if d.get("hwnd") and d.get("visible"):
        T.shot(os.path.join(OUT, name))
    else:
        print("  -> skip screenshot (window missing)")

# 1. initial map
snap("t1_initial.png")

# 2. P1 hold D (move right), then screenshot
T.hold(0x44, 0.7)
snap("t2_p1_moved.png")

# 3. P1 fire (space), let bullet fly, screenshot
T.tap(0x20)
time.sleep(0.5)
snap("t3_p1_fired.png")

# 4. P2 hold Left, screenshot
T.hold(0x25, 0.7)
snap("t4_p2_moved.png")

# 5. P2 fire (Enter), screenshot
T.tap(0x0D)
time.sleep(0.5)
snap("t5_p2_fired.png")

# 6. bullet lifetime check: fire again then wait > 10.5s, screenshot
T.tap(0x20)
time.sleep(10.8)
snap("t6_bullet_expired.png")

proc.kill()
print("DRIVER DONE")
