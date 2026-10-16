# Thin-wall acceptance v3: single-capture screenshots. Capture once into a
# raw pixel buffer, check the CLIENT area is actually painted (not the
# blank white the VM display stack sometimes shows), only then save.
# ASCII only.
import ctypes, subprocess, sys, time, os, struct, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m1test as T

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
k32 = ctypes.windll.kernel32

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "tankwar.exe")
OUT = ROOT

class POINT(ctypes.Structure):
    _fields_ = [("X", ctypes.c_long), ("Y", ctypes.c_long)]

def grab(hwnd, use_screen):
    """Capture window into a 24bpp top-down buffer.
    use_screen=False -> PrintWindow (flaky in this VM, sometimes all-white)
    use_screen=True  -> BitBlt from screen DC (needs window foreground)"""
    r = T.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    cr = T.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(cr))
    pt = POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    cl, ct = pt.X - r.L, pt.Y - r.T
    cw, ch = cr.R - cr.L, cr.B - cr.T
    w, h = r.R - r.L, r.B - r.T
    hdc = user32.GetDC(0)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mdc, bmp)
    if use_screen:
        gdi32.BitBlt(mdc, 0, 0, w, h, hdc, r.L, r.T, 0x00CC0020)  # SRCCOPY
    else:
        user32.PrintWindow(hwnd, mdc, 2)

    class BMIH(ctypes.Structure):
        _fields_ = [("biSize", ctypes.c_uint32), ("biWidth", ctypes.c_int32),
                    ("biHeight", ctypes.c_int32), ("biPlanes", ctypes.c_uint16),
                    ("biBitCount", ctypes.c_uint16), ("biCompression", ctypes.c_uint32),
                    ("biSizeImage", ctypes.c_uint32), ("biXPels", ctypes.c_int32),
                    ("biYPels", ctypes.c_int32), ("biClrUsed", ctypes.c_uint32),
                    ("biClrImportant", ctypes.c_uint32)]
    bmi = BMIH()
    bmi.biSize = ctypes.sizeof(BMIH)
    bmi.biWidth = w
    bmi.biHeight = -h
    bmi.biPlanes = 1
    bmi.biBitCount = 24
    bmi.biCompression = 0
    row_size = (w * 3 + 3) & ~3
    buf = ctypes.create_string_buffer(row_size * h)
    gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(0, hdc)
    return raw_info(buf.raw, row_size, w, h, cl, ct, cw, ch)

def raw_info(raw, row_size, w, h, cl, ct, cw, ch):
    """Check paint state by sampling the client area; return (ok, raw...)."""
    cols = set()
    step = max(1, row_size // 97)
    y0 = ct + ch // 6
    y1 = ct + (ch * 5) // 6
    for y in range(y0, y1, max(1, (y1 - y0) // 12)):
        base = y * row_size
        for i in range(cl * 3 + 3, (cl + cw - 2) * 3, step * 3):
            cols.add(raw[base + i:i + 3])
    return len(cols) >= 4, raw, row_size, w, h

def save_png(path, raw, row_size, w, h):
    rows = []
    for y in range(h):
        row = raw[y * row_size:(y + 1) * row_size]
        px = bytearray(row)
        for x in range(w):
            i = x * 3
            px[i], px[i + 2] = px[i + 2], px[i]
        rows.append(bytes(px))
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    body = b"".join(b"\x00" + rr for rr in rows)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(body, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    print("saved", path)

def make_topmost(hwnd):
    """Put the game window above the user's windows WITHOUT stealing focus.
    (Screen BitBlt then captures the game, not the white UI covering it.)"""
    SWP_NOSIZE = 0x0001
    SWP_NOACTIVATE = 0x0010
    HWND_TOPMOST = -1
    user32.SetWindowPos(hwnd, HWND_TOPMOST, 40, 40, 0, 0,
                        SWP_NOSIZE | SWP_NOACTIVATE)

def capture_good(path, timeout=40):
    """Capture once; retry until client area is painted; save PNG.
    Handles: window minimized (restores it, no focus steal) and the game
    process having been closed (relaunches it)."""
    global proc
    topmost_done = False
    deadline = time.time() + timeout
    n = 0
    while time.time() < deadline:
        n += 1
        if proc.poll() is not None:          # closed (e.g. by the user)
            print("game closed (proc=", proc.poll(), ") -> relaunch")
            proc = subprocess.Popen([EXE, "play2"], cwd=ROOT)
            topmost_done = False
            time.sleep(1.5)
        hwnd = T.find_hwnd()
        wait = 0
        while not hwnd and wait < 6:
            time.sleep(0.5)
            wait += 0.5
            hwnd = T.find_hwnd()
        if not hwnd:
            print("window gone, proc =", proc.poll())
            sys.exit(1)
        if user32.IsIconic(hwnd):            # minimized -> restore, no focus
            user32.ShowWindow(hwnd, 4)       # SW_SHOWNOACTIVATE
            time.sleep(0.3)
        if not topmost_done:
            make_topmost(hwnd)
            topmost_done = True
            time.sleep(0.3)
        for use_screen in (False, True):
            ok, raw, rs, w, h = grab(hwnd, use_screen)
            if ok:
                save_png(path, raw, rs, w, h)
                return True
        time.sleep(0.5)
    print("STILL BLANK after", n, "tries:", path)
    return False

def snap(name):
    time.sleep(0.3)
    capture_good(os.path.join(OUT, name))
    print(name, "game_alive=", T.find_hwnd() is not None)

proc = subprocess.Popen([EXE, "play2"], cwd=ROOT)
time.sleep(1.5)

snap("w1_play_thinwall.png")

# P1 move right
time.sleep(0.2)
T.hold(0x44, 0.6)
snap("w2_p1_moved.png")

# P1 fire
T.tap(0x20)
time.sleep(0.35)
snap("w3_p1_fired.png")

# P2 move left
time.sleep(0.2)
T.hold(0x25, 0.6)
snap("w4_p2_moved.png")

proc.kill()
print("done")
