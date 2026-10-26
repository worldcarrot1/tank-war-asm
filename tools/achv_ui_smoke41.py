# -*- coding: utf-8 -*-
# 会话41：成就优化 UI 冒烟
# v1 旧档(196B, 23行, 弹幕大海 999/1000) 实启动 -> 迁移显示 -> bot 开火解锁(带日期)
# -> (新)角标 -> 图鉴徽章/日期/追风者行/数字跳页 -> 角标熄灭 -> v2 档落盘
import sys, os, struct, time
sys.path.insert(0, r'D:\tank-war-asm\tools')
import sim_ui_test as U

OUT = r"D:\tank-war-asm\shots41"
os.makedirs(OUT, exist_ok=True)
DAT = r"D:\tank-war-asm\achv.dat"

def shot(h, name, tries=6):
    for k in range(tries):
        im = U.grab(h)
        if im.size[0] > 100 and im.size[1] > 100:
            im.save(os.path.join(OUT, name))
            return im
        time.sleep(0.3)
    raise RuntimeError('grab invalid %s' % (im.size,))

def write_v1():
    b = bytearray(196)
    struct.pack_into('<4sII', b, 0, b'ACHP', 1, 23)
    struct.pack_into('<II', b, 12 + 22 * 8, 995, 0)   # 弹幕大海 995/1000 未点亮（一炮不满）
    open(DAT, 'wb').write(bytes(b))

def own0():
    """轮询 achv.dat 行0 own 位：解锁即同步落盘，文件反推解锁时刻"""
    try:
        b = open(DAT, 'rb').read(300)
        if len(b) >= 300:
            return struct.unpack_from('<I', b, 12 + 0 * 12 + 4)[0]
    except OSError:
        pass
    return 0

def main():
    global T0
    write_v1()
    T0 = time.time()
    p, h = U.launch()
    time.sleep(0.6)
    # 1) 图鉴：迁移后 1/24、无日期（旧档迁移=0）、p4 弹幕大海 999/1000
    U.click(h, 550, 483); time.sleep(0.5)
    assert p.poll() is None, 'dead entering gallery (migration load?)'
    shot(h, "g1_migrated_p1.png")
    U.click(h, 880, 300); time.sleep(0.25)
    U.click(h, 880, 300); time.sleep(0.25)
    U.click(h, 880, 300); time.sleep(0.25)            # p4：弹幕大海(idx23) 999/1000
    shot(h, "g2_migrated_p4.png")
    U.key(0x33, True); time.sleep(0.08); U.key(0x33, False) # 数字键 3 -> p3(追风者 idx12 首行)
    time.sleep(0.25)
    shot(h, "g3_key3_p3.png")
    U.key(0x31, True); time.sleep(0.08); U.key(0x31, False) # 键 1 回 p1
    time.sleep(0.25)
    U.click(h, 500, 534); time.sleep(0.4)             # 返回钮
    # 2) bot 直开局开火 -> 首开锋芒 解锁(真日期) + 弹层（轮询 dat 定解锁时刻，连拍弹层）
    U.click(h, 550, 253); time.sleep(1.3)
    assert p.poll() is None, 'dead in bot match'
    U.key(0x20, True); time.sleep(0.05); U.key(0x20, False)
    t_u = None
    for k in range(80):                        # 至多 8s 等解锁落盘
        time.sleep(0.1)
        if own0() == 1:
            t_u = time.time() - T0
            break
    print("unlock@%.2fs (tap was at ~%.2fs)" % (t_u or -1, 1.35))
    time.sleep(0.15)
    im = shot(h, "g4a_toast_early.png")        # age~10tick：滑入完成后
    im.crop((250, 20, 740, 120)).resize((980, 200)).save(os.path.join(OUT, "g4a_crop.png"))
    time.sleep(1.2)
    shot(h, "g4b_toast_mid.png")               # age~90tick：稳显段
    # 3) 暂停菜单退出对局 -> 主菜单 -> (新) 角标；再进图鉴 -> 角标应灭、p1 首开锋芒 带日期
    U.key(0x1B, True); time.sleep(0.08); U.key(0x1B, False)   # Esc 开暂停
    time.sleep(0.4)
    U.click(h, 500, 445); time.sleep(0.6)                     # 退出游戏 -> 主菜单
    if p.poll() is None:
        shot(h, "g5_menu_new_badge.png")
        U.click(h, 550, 483); time.sleep(0.5)
        shot(h, "g6_gal_date.png")
        U.click(h, 500, 534); time.sleep(0.4)
        if p.poll() is None:
            shot(h, "g7_menu_after_read.png")
    alive = p.poll() is None
    time.sleep(0.4)
    sz = os.path.getsize(DAT) if os.path.exists(DAT) else -1
    head = open(DAT, 'rb').read(300) if sz >= 300 else b''
    ver = struct.unpack_from('<I', head, 4)[0] if len(head) >= 12 else -1
    cnt = struct.unpack_from('<I', head, 8)[0] if len(head) >= 12 else -1
    date0 = struct.unpack_from('<I', head, 12 + 0 * 12 + 8)[0] if len(head) >= 32 else -1
    own23 = struct.unpack_from('<I', head, 12 + 23 * 12 + 4)[0] if len(head) >= 300 else -1
    print("dat size=%s ver=%s count=%s row0date=%s own23(should0)=%s" % (sz, ver, cnt, date0, own23))
    print("alive:", alive)
    p.kill()

main()
