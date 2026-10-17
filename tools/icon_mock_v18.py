# Geometry mock of DrawPickupIcon (session 18 redesigns), GDI semantics:
# Rectangle/Ellipse fill left..right-1 x top..bottom-1; LineTo width fixed 2px;
# coords scaled by sc (skill guide page uses sc=3). VM screenshot path is
# down, so this validates icon geometry only, not real GDI output.
from PIL import Image, ImageDraw

BG = (48, 32, 32)      # brushPickBg 00202030 (BGR->RGB)
WH = (240, 240, 240)   # brushIcon / penIcon
S = 3                  # skill guide scale
PAD = 8
N = 6

img = Image.new("RGB", (PAD + (16 * S + PAD) * N, 16 * S + 2 * PAD), (200, 200, 200))
d = ImageDraw.Draw(img)

def plate(idx):
    x0 = PAD + idx * (16 * S + PAD) + 2
    y0 = PAD
    d.rectangle([x0 - 2, y0 - 2, x0 + 16 * S + 2, y0 + 16 * S + 2], fill=(60, 60, 60))
    d.rectangle([x0, y0, x0 + 16 * S, y0 + 16 * S], fill=BG)
    return x0, y0

def L(x0, y0, x1, y1, x2, y2):
    d.line([x0 + x1 * S, y0 + y1 * S, x0 + x2 * S, y0 + y2 * S], fill=WH, width=2)

def FR(x0, y0, l, t, r, b, col):   # GDI Rectangle (no right/bottom edge)
    d.rectangle([x0 + l * S, y0 + t * S, x0 + r * S - 1, y0 + b * S - 1], fill=col)

def FE(x0, y0, l, t, r, b, col):   # GDI Ellipse bbox (no right/bottom)
    d.ellipse([x0 + l * S, y0 + t * S, x0 + r * S - 1, y0 + b * S - 1], fill=col)

# 1 ice shield: shield outline + ice cross
x0, y0 = plate(0)
L(x0, y0, 3, 3, 13, 3); L(x0, y0, 3, 3, 3, 9); L(x0, y0, 13, 3, 13, 9)
L(x0, y0, 3, 9, 8, 14); L(x0, y0, 13, 9, 8, 14)
L(x0, y0, 8, 5, 8, 11); L(x0, y0, 5, 8, 11, 8)

# 2 laser: cannon = wheel ellipse + barrel + muzzle band
x0, y0 = plate(1)
FE(x0, y0, 2, 8, 10, 16, WH)
FR(x0, y0, 5, 6, 15, 10, WH)
FR(x0, y0, 13, 4, 16, 12, WH)

# 4 ghost: solid wall blocks with center gap + pierce arrow
x0, y0 = plate(2)
FR(x0, y0, 6, 1, 10, 7, WH)
FR(x0, y0, 6, 10, 10, 16, WH)
L(x0, y0, 1, 8, 15, 8)
L(x0, y0, 12, 5, 15, 8); L(x0, y0, 12, 11, 15, 8)

# 5 mine: bomb body + fuse + spark cross
x0, y0 = plate(3)
FE(x0, y0, 1, 6, 11, 15, WH)
L(x0, y0, 9, 6, 12, 3); L(x0, y0, 12, 1, 12, 5); L(x0, y0, 10, 3, 14, 3)

# 8 water: two rows of wave zags
x0, y0 = plate(4)
for yo in (0, 7):
    L(x0, y0, 2, 7 + yo, 4, 4 + yo); L(x0, y0, 4, 4 + yo, 6, 7 + yo)
    L(x0, y0, 6, 7 + yo, 8, 4 + yo); L(x0, y0, 8, 4 + yo, 10, 7 + yo)
    L(x0, y0, 10, 7 + yo, 12, 4 + yo); L(x0, y0, 12, 4 + yo, 14, 7 + yo)

# 9 phantom: camera body+bump, lens = dark ring/white ring/dark pupil
x0, y0 = plate(5)
FR(x0, y0, 2, 6, 14, 14, WH)
FR(x0, y0, 6, 4, 10, 6, WH)
FE(x0, y0, 5, 8, 11, 14, BG)
FE(x0, y0, 6, 9, 10, 13, WH)
FE(x0, y0, 7, 10, 9, 12, BG)

img.save("icon_mock_v18.png")
print("saved icon_mock_v18.png")
