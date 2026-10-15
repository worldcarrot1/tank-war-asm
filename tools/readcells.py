# Decode our own PNG output (8-bit RGB, filter 0) and classify map cells.
import struct, zlib, sys

def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    pos = 8
    w = h = 0
    idat = b""
    while pos < len(d):
        ln, typ = struct.unpack(">I4s", d[pos:pos+8])
        data = d[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, bit, ctype = struct.unpack(">IIBB", data[:10])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w*3
    rows = []
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        row = bytearray(raw[p:p+stride]); p += stride
        # only filter 0 was used by our writer
        rows.append(bytes(row))
    return w, h, rows

# reference colors (RGB)
COLORS = {
    "STEEL": (160,160,160), "BRICK": (128,64,0), "WATER": (16,64,192),
    "ICE": (216,232,240), "P1": (240,128,0), "P2": (0,128,240),
    "BULLET": (255,255,255),
}

def classify(px):
    best, bd = "?", 1e9
    for name, c in COLORS.items():
        dd = sum((a-b)**2 for a, b in zip(px, c))
        if dd < bd:
            bd, best = dd, name
    if bd > 3500:          # not close to any -> black/empty
        return "."
    return {"STEEL":"#","BRICK":"b","WATER":"~","ICE":"-","P1":"1","P2":"2","BULLET":"*"}[best]

def main(path, cell=None, ox=None, oy=None):
    w, h, rows = read_png(path)
    px = lambda x, y: rows[y][x*3:x*3+3]
    def is_black(x, y):
        r, g, b = px(x, y)
        return r < 24 and g < 24 and b < 24
    col_black = [sum(1 for y in range(0, h, 4) if is_black(x, y)) for x in range(w)]
    row_black = [sum(1 for x in range(0, w, 4) if is_black(x, y)) for y in range(h)]
    xs = [x for x in range(w) if col_black[x] > (h//4)//3]
    ys = [y for y in range(h) if row_black[y] > (w//4)//3]
    ox, oy = min(xs), min(ys)
    cw, ch = max(xs)-ox+1, max(ys)-oy+1
    cell = min(cw//20, ch//15)
    print(path, w, "x", h, "client=", (ox, oy, cw, ch), "cell=", cell)
    for r in range(15):
        line = ""
        for c in range(20):
            x = ox + c*cell + cell//2
            y = oy + r*cell + cell//2
            votes = {}
            for dx in (-3, 0, 3):
                for dy in (-3, 0, 3):
                    k = classify(px(x+dx, y+dy))
                    votes[k] = votes.get(k, 0) + 1
            best = max(votes.items(), key=lambda kv: kv[1])
            line += best[0] if best[1] >= 4 else "."
        print(line)

if __name__ == "__main__":
    main(sys.argv[1])
