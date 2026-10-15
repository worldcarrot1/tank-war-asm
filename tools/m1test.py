# M1 acceptance test helper: screenshot the game window and inject keys.
# Pure stdlib (ctypes + zlib PNG writer). ASCII only.
import ctypes, struct, zlib, time, sys

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.SetProcessDPIAware()

TITLE = "Tank War ASM M1 - P1: WASD+SPACE | P2: Arrows+ENTER | R restart"

class RECT(ctypes.Structure):
    _fields_ = [("L", ctypes.c_long), ("T", ctypes.c_long),
                ("R", ctypes.c_long), ("B", ctypes.c_long)]

def find_hwnd():
    h = user32.FindWindowW(None, TITLE)
    return h

def key(vk, down):
    user32.keybd_event(vk, 0, 0 if down else 2, None)

def hold(vk, secs):
    key(vk, True); time.sleep(secs); key(vk, False)

k32 = ctypes.windll.kernel32

def focus_window():
    """Force game window to foreground so injected keys land there."""
    hwnd = find_hwnd()
    if not hwnd:
        return
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)   # SW_RESTORE
    fg = user32.GetForegroundWindow()
    cur = k32.GetCurrentThreadId()
    other = user32.GetWindowThreadProcessId(fg, None)
    if other and other != cur:
        user32.AttachThreadInput(other, cur, True)
    user32.SetForegroundWindow(hwnd)
    user32.SetFocus(hwnd)
    if other and other != cur:
        user32.AttachThreadInput(other, cur, False)

def shot(path):
    focus_window()
    time.sleep(0.15)
    hwnd = find_hwnd()
    if not hwnd:
        print("window not found"); sys.exit(1)
    r = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.R - r.L, r.B - r.T
    hdc = user32.GetDC(0)
    mdc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mdc, bmp)
    # PrintWindow: captures window content even when occluded
    user32.PrintWindow(hwnd, mdc, 2)   # 2 = PW_RENDERFULLCONTENT

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
    bmi.biHeight = -h          # top-down
    bmi.biPlanes = 1
    bmi.biBitCount = 24
    bmi.biCompression = 0
    row_size = (w * 3 + 3) & ~3
    buf = ctypes.create_string_buffer(row_size * h)
    gdi32.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
    raw = buf.raw
    rows = []
    for y in range(h):
        row = raw[y*row_size:(y+1)*row_size]
        # BGR -> RGB
        px = bytearray(row)
        for x in range(w):
            i = x*3
            px[i], px[i+2] = px[i+2], px[i]
        rows.append(bytes(px))
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mdc)
    user32.ReleaseDC(0, hdc)

    # minimal PNG writer
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    body = b"".join(b"\x00" + r for r in rows)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(body, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    print("saved", path, w, "x", h)

def tap(vk):
    key(vk, True); time.sleep(0.05); key(vk, False)

def diag():
    hwnd = find_hwnd()
    info = {"hwnd": hwnd}
    if hwnd:
        r = RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(r))
        info["rect"] = (r.L, r.T, r.R, r.B)
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        info["pid"] = pid.value
        info["visible"] = bool(user32.IsWindowVisible(hwnd))
    return info

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "shot":
        shot(sys.argv[2])
    elif cmd == "hold":
        hold(int(sys.argv[2], 0), float(sys.argv[3]))
        print("held")
    elif cmd == "tap":
        tap(int(sys.argv[2], 0))
        print("tapped")
    elif cmd == "diag":
        print(diag())
