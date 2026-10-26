# -*- coding: utf-8 -*-
# 会话41 DBG：弹层三哨兵最小复现——开局开火后连拍 6 帧看右上角 蓝/紫/橙 灯
import sys, os, struct, time
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

DAT = r"D:\tank-war-asm\achv.dat"
OUT = r"D:\tank-war-asm\shots41"

def own0():
    try:
        b = open(DAT, 'rb').read(300)
        if len(b) >= 300:
            return struct.unpack_from('<I', b, 12 + 0 * 12 + 4)[0]
    except OSError:
        pass
    return 0

def main():
    b = bytearray(196)
    struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
    open(DAT, 'wb').write(bytes(b))
    T0 = time.time()
    p, h = U.launch()
    time.sleep(0.6)
    U.click(h, 550, 253)             # BOT 对战
    time.sleep(1.3)
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
    for k in range(60):
        time.sleep(0.1)
        if own0() == 1:
            print("unlock@%.2fs" % (time.time() - T0))
            break
    else:
        print("NO UNLOCK")
    for i in range(14):
        im = U.grab(h)
        im.save(os.path.join(OUT, "dbg_%d.png" % i))
        print("f%d @%.2fs px(932,12)=%s px(948,12)=%s px(964,12)=%s" %
              (i, time.time() - T0,
               im.getpixel((932, 12)), im.getpixel((948, 12)), im.getpixel((964, 12))))
        time.sleep(0.45)
    p.kill()

main()
