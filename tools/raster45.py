# -*- coding: utf-8 -*-
"""会话45：game-icons SVG -> 24x24x4级覆盖字节 -> inc/achvicons.inc + 预览拼图 PNG。

自研最小 SVG 栅格化器（不跑任何下载的二进制、无第三方依赖）：
  * 解析 <path d>：M m L l H h V v C c S s Z z A a；
  * 椭圆弧 endpoint->center 参数化 + 均匀细分；S 用反射控制点；
  * 丢弃全画布背景方块路径；
  * 384x384（24*16）nonzero 绕数扫描线填充，16x16 盒式降采样量化 4 级；
  * 输出：inc/achvicons.inc（每行像素独立 db 24 数——本 ml 对续行/大操作数 db 报 A2042）。
读的全是下载解压产物，故本脚本按隔离要求用 python -I 运行。"""
import glob, math, os, re, struct, zlib

SRC = r"D:\tank-war-asm\dl\achv45\picked"
INC = r"D:\tank-war-asm\inc\achvicons.inc"
PREV = r"D:\tank-war-asm\dl\achv45\preview45.png"
N = 24           # 目标边长
SS = 16          # 每像素线性采样数
R = N * SS       # 光栅分辨率 384
ICON_SZ = N * N  # 576 字节/图标

def arc_cubics(x1, y1, rx, ry, phi_deg, fa, fs, x2, y2):
    """SVG 弧：端点参数化 -> 中心参数化 -> 离散点列（含首不含尾）。"""
    if rx == 0 or ry == 0:
        return [(x2, y2)]
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    rx, ry = abs(rx), abs(ry)
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        rx *= math.sqrt(lam); ry *= math.sqrt(lam)
    num = max(0.0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = (math.sqrt(num / den) if den else 0.0) * (-1 if (fa == 0) == (fs == 0) else 1)
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cp * cxp - sp * cyp + (x1 + x2) / 2
    cy = sp * cxp + cp * cyp + (y1 + y2) / 2
    def ang(ux, uy, vx, vy):
        l = math.sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy)) or 1.0
        a = math.acos(max(-1.0, min(1.0, (ux * vx + uy * vy) / l)))
        return -a if ux * vy - uy * vx < 0 else a
    v1 = ((x1p - cxp) / rx, (y1p - cyp) / ry)
    v2 = ((-x1p - cxp) / rx, (-y1p - cyp) / ry)
    th1 = ang(1, 0, *v1)
    dth = ang(*v1, *v2)
    if fs == 0 and dth > 0:
        dth -= 2 * math.pi
    if fs != 0 and dth < 0:
        dth += 2 * math.pi
    segs = max(2, int(abs(dth) / (math.pi / 12)) + 1)
    pts = []
    for i in range(segs):
        t = th1 + dth * i / segs
        ex, ey = rx * math.cos(t), ry * math.sin(t)
        pts.append((cp * ex - sp * ey + cx, sp * ex + cp * ey + cy))
    return pts

def parse_path(d, sx, sy, ox, oy):
    """返回多边形列表（每子路径一环比，映射到光栅坐标域）。"""
    polys = []
    poly = []
    toks = re.findall(r'[MmLlHhVvCcSsZzAa]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?', d)
    i = 0
    cx = cy = 0.0
    px = py = None
    def mp(x, y):
        poly.append((x * sx + ox, y * sy + oy))
    def num():
        nonlocal i
        v = float(toks[i]); i += 1
        return v
    while i < len(toks):
        c = toks[i]
        if not re.match(r'[MmLlHhVvCcSsZzAa]$', c):
            raise ValueError('expected cmd, got ' + c)
        i += 1
        low = c.islower()
        C = c.upper()
        if C == 'M':
            if len(poly) > 2:
                polys.append(poly)
            poly = []
            x, y = num(), num()
            if low: x += cx; y += cy
            cx, cy = x, y
            mp(x, y)
            px = py = None
            while i < len(toks) and not re.match(r'[MmLlHhVvCcSsZzAa]$', toks[i]):
                x, y = num(), num()
                if low: x += cx; y += cy
                cx, cy = x, y
                mp(x, y)
            continue
        if C == 'Z':
            if len(poly) > 2:
                polys.append(poly)
            poly = []
            px = py = None
            continue
        while i < len(toks) and not re.match(r'[MmLlHhVvCcSsZzAa]$', toks[i]):
            if C == 'L':
                x, y = num(), num()
                if low: x += cx; y += cy
                cx, cy = x, y
                mp(x, y); px = py = None
            elif C == 'H':
                x = num()
                if low: x += cx
                cx = x; mp(cx, cy); px = py = None
            elif C == 'V':
                y = num()
                if low: y += cy
                cy = y; mp(cx, cy); px = py = None
            elif C in ('C', 'S'):
                if C == 'C':
                    x1, y1, x2, y2, x, y = num(), num(), num(), num(), num(), num()
                else:
                    x2, y2, x, y = num(), num(), num(), num()
                    x1, y1 = (cx, cy) if px is None else (2 * cx - px, 2 * cy - py)
                if low:
                    x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
                for s in range(1, 9):
                    t = s / 8.0
                    mt = 1 - t
                    mp(mt*mt*mt*cx + 3*mt*mt*t*x1 + 3*mt*t*t*x2 + t*t*t*x,
                       mt*mt*mt*cy + 3*mt*mt*t*y1 + 3*mt*t*t*y2 + t*t*t*y)
                px, py = x2, y2
                cx, cy = x, y
            elif C == 'A':
                rx, ry, rot = num(), num(), num()
                fa, fs = num(), num()
                x, y = num(), num()
                if low: x += cx; y += cy
                for pt in arc_cubics(cx, cy, rx, ry, rot, fa, fs, x, y):
                    mp(*pt)
                cx, cy = x, y
                px = py = None
            else:
                raise ValueError('cmd ' + C)
    if len(poly) > 2:
        polys.append(poly)
    return polys

def load_polys(path):
    s = open(path, encoding='utf-8').read()
    vb = re.search(r'viewBox="([^"]+)"', s)
    x0, y0, w, h = [float(t) for t in vb.group(1).replace(',', ' ').split()]
    scale = R / w
    out = []
    for m in re.finditer(r'<path\b([^>]*)>', s):
        d = re.search(r'\sd="([^"]+)"', m.group(1))
        if not d:
            continue
        polys = parse_path(d.group(1), scale, scale, -x0 * scale, -y0 * scale)
        if len(polys) == 1:      # 全画布背景方块丢弃
            xs = [p[0] for p in polys[0]]; ys = [p[1] for p in polys[0]]
            if min(xs) <= 1 and min(ys) <= 1 and max(xs) >= R - 1 and max(ys) >= R - 1:
                continue
        out.extend(polys)
    return out

def render_rows(polys):
    """nonzero 绕数扫描线：yield 每行 crossings (x, dir) 已排序。"""
    rows = []
    for j in range(R):
        ys = j + 0.5
        xs = []
        for poly in polys:
            n = len(poly)
            for k in range(n):
                x1, y1 = poly[k]
                x2, y2 = poly[(k + 1) % n]
                if (y1 <= ys < y2) or (y2 <= ys < y1):
                    dirn = 1 if y2 > y1 else -1
                    t = (ys - y1) / (y2 - y1)
                    xs.append((x1 + t * (x2 - x1), dirn))
        xs.sort(key=lambda e: e[0])
        row = bytearray(R)
        w = 0
        sstart = 0
        for xc, dirn in xs:
            prev = w
            w += dirn
            if prev == 0 and w != 0:
                sstart = int(math.ceil(xc - 0.5))
            elif prev != 0 and w == 0:
                send = int(math.ceil(xc - 0.5))
                for xi in range(max(0, sstart), min(R, send)):
                    row[xi] = 1
        rows.append(row)
    return rows

def quantize(rows):
    out = bytearray(ICON_SZ)
    for iy in range(N):
        base = iy * N
        for ix in range(N):
            hits = 0
            bx = ix * SS
            for dy in range(SS):
                r = rows[iy * SS + dy]
                hits += sum(r[bx:bx + SS])
            cov = hits / (SS * SS)
            out[base + ix] = 0 if cov < 0.10 else (1 if cov < 0.40 else (2 if cov < 0.72 else 3))
    return out

def write_png(path, w, h, getpx):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(getpx(x, y))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b''))
    open(path, 'wb').write(png)

def main():
    files = sorted(glob.glob(os.path.join(SRC, '*.svg')))
    assert len(files) == 28, len(files)
    tabs = []
    for f in files:
        name = os.path.basename(f)[:-4]
        polys = load_polys(f)
        if not polys:
            raise SystemExit('no usable path: ' + name)
        q = quantize(render_rows(polys))
        tabs.append((name, q))
        ink = sum(1 for v in q if v)
        assert ink > ICON_SZ * 6 // 100, 'raster empty: ' + name
        print('%-26s ink=%d%%' % (name, ink * 100 // ICON_SZ))
    # ---- 预览拼图 7列x4行 单元格72px（1x 深灰底、1x 白、2x 品阶色示意）----
    COLS, ROWS, CELL = 7, 4, 96
    def gp(x, y):
        col, row = x // CELL, y // CELL
        k = row * COLS + col
        if k >= 28:
            return (0, 0, 0)
        q = tabs[k][1]
        sub = 1 if x % CELL < 48 else 2          # 左半灰阶 2x / 右半彩色 2x
        lx = min((x % 48) // 2, 23)
        ly = min((y % CELL) // 2, 23)
        v = q[ly * 24 + lx]
        if sub == 1:
            c = {0: 255, 1: 150, 2: 80, 3: 20}[v]   # 白底反相预览
            return (c, c, c)
        return ({0: 245, 1: 45, 2: 95, 3: 165}[v],   # 金色阶示意
                {0: 245, 1: 35, 2: 85, 3: 175}[v],
                {0: 245, 1: 25, 2: 95, 3: 195}[v])
    write_png(PREV, COLS * CELL, ROWS * CELL + ROWS, gp)
    # ---- inc：每图标独立 db 语句 ----
    header = ('; ============================================================\n'
              '; achvicons.inc —— 会话45 成就图鉴像素图标（ui.asm .data include）\n'
              '; 来源：https://github.com/game-icons/icons（game-icons.net，CC BY 3.0）。\n'
              '; 作者 lorc / delapouite / skoll / badges 名下 28 件；tools/raster45.py\n'
              '; 自研扫描线栅格器 -> 24x24，字节值 0=透明 1=暗 2=中 3=满。\n'
              '; 索引 0..23 对应 achvDefs 顺序；24..27=品阶徽章 普通/稀有/史诗/传奇。\n'
              '; 归属与许可详见 README「成就图标」条。重生成：tools/pick45.py + raster45.py。\n'
              '; ============================================================\n')
    with open(INC, 'w', encoding='utf-8', newline='\r\n') as fo:
        fo.write(header)
        fo.write('\nalign 4\n\nachvIconTab label byte\n')
        for name, q in tabs:
            fo.write('; ---- %s ----\n' % name)
            # 本 ml.exe 对反斜杠续行的多操作数语句报 A2042；照 sfxdata 惯例每行独立 db
            for iy in range(N):
                row = ','.join(str(v) for v in q[iy * N:iy * N + N])
                fo.write('    db %s\n' % row)
    print('INC %s: 28 icons x %dB = %dB; PREVIEW %s' % (INC, ICON_SZ, 28 * ICON_SZ, PREV))

main()
