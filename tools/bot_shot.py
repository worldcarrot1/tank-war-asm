# 会话38 冒烟：直开人机局，截客户区，确认黑色人机坦克已渲染（数近黑像素+导出PNG）
import ctypes as C, struct, zlib, subprocess, time, sys

u32 = C.windll.user32
gdi = C.windll.gdi32

class RECT(C.Structure):
    _fields_ = [("l", C.c_long), ("t", C.c_long), ("r", C.c_long), ("b", C.c_long)]

class BIH(C.Structure):
    _fields_ = [("s", C.c_uint), ("w", C.c_int), ("h", C.c_int), ("pl", C.c_ushort),
                ("cb", C.c_ushort), ("comp", C.c_uint), ("siz", C.c_uint),
                ("xr", C.c_uint), ("yr", C.c_uint), ("clu", C.c_uint), ("ciu", C.c_uint)]

def find_hwnd(pid):
    res = []
    EnumWindows = u32.EnumWindows
    CBTYPE = C.WINFUNCTYPE(C.c_bool, C.c_void_p, C.c_void_p)
    def cb(h, l):
        p = C.c_ulong()
        u32.GetWindowThreadProcessId(h, C.byref(p))
        if p.value == pid:
            r = RECT(); u32.GetClientRect(h, C.byref(r))
            if r.r > 300: res.append(h)
        return True
    EnumWindows(CBTYPE(cb), 0)
    return res[0] if res else None

def grab_png(h, path):
    r = RECT(); u32.GetClientRect(h, C.byref(r)); w, hh = r.r, r.b
    hdc = u32.GetDC(h); mfc = gdi.CreateCompatibleDC(hdc)
    bmp = gdi.CreateCompatibleBitmap(hdc, w, hh)
    gdi.SelectObject(mfc, bmp)
    gdi.BitBlt(mfc, 0, 0, w, hh, hdc, 0, 0, 0x00CC0020)
    bi = BIH(); bi.s = C.sizeof(bi); bi.w = w; bi.h = -hh; bi.pl = 1; bi.cb = 32
    buf = C.create_string_buffer(w*hh*4)
    gdi.GetDIBits(mfc, bmp, 0, hh, buf, C.byref(bi), 0)
    gdi.DeleteDC(mfc); gdi.DeleteObject(bmp); u32.ReleaseDC(h, hdc)
    px = buf.raw
    dark = 0
    rows = bytearray()
    for y in range(hh):
        rows += b"\x00"
        for x in range(w):
            i = (y*w+x)*4
            b, g, rr = px[i], px[i+1], px[i+2]
            # bot 刷色 000C0C0C → BGR(12,12,0)：近黑且蓝绿≥红（排除纯黑HUD字/边框用宽松阈）
            if b < 40 and g < 40 and rr < 40:
                dark += 1
            rows += bytes((rr, g, b))
    raw = bytes(rows)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, hh, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    open(path, "wb").write(png)
    return dark, w, hh

p = subprocess.Popen([r"D:\tank-war-asm\tankwar.exe", "bot"])
time.sleep(2.5)
try:
    h = find_hwnd(p.pid)
    if not h:
        print("NO WINDOW"); sys.exit(1)
    dark, w, hh = grab_png(h, r"D:\tank-war-asm\shots38_bot.png")
    print(f"window=0x{h:x} client={w}x{hh} dark_pixels={dark}")
finally:
    p.kill()
