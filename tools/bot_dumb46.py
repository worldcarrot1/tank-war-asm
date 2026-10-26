# -*- coding: utf-8 -*-
# 会话46：呆行为体检 —— 从 bottrace.csv 量化"看起来呆"的六个特征。
import csv, sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else r'D:\tank-war-asm\tankwar_bottrace.csv'
rows = list(csv.reader(open(path)))
hdr = rows[0]
I = {k: i for i, k in enumerate(hdr)}
data = [r for r in rows[1:] if len(r) == len(hdr)]
print("rows=%d slots=%s" % (len(data), sorted({r[I['slot']] for r in data})))

def g(r, k): return r[I[k]]

# 按 slot 分组、按 tick 排序（tick 可能跨局重置，组内保序即可）
by = defaultdict(list)
for r in data:
    by[g(r, 'slot')].append(r)

for slot in sorted(by):
    rs = by[slot]
    alive = [r for r in rs if g(r, 'alive') == '1']
    n = len(alive) or 1
    # 1) 转向抖动：CCW/CW 电平交替次数（连续反向换向=原地摇头）
    last_turn, alt = 0, 0
    for r in alive:
        t = (int(g(r, 'inCW')) > 0) - (int(g(r, 'inCCW')) > 0)
        if t != 0 and last_turn != 0 and t != last_turn:
            alt += 1
        if t != 0:
            last_turn = t
    # 2) 目标横跳：tgtIdx 变化次数（目标还活着就换=三心二意）
    tj = 0
    for a, b in zip(alive, alive[1:]):
        if a[I['tgtIdx']] != b[I['tgtIdx']] and g(b, 'tgtIdx') != '-1':
            tj += 1
    # 3) 倒车比例 drive=-1（排除逃逸帧）
    rev = sum(1 for r in alive if g(r, 'drive') == '-1')
    rev_esc = sum(1 for r in alive if g(r, 'drive') == '-1' and g(r, 'esc') == '0')
    # 4) 挂墙：想前进但被挡 blk=1 帧数
    hang = sum(1 for r in alive if g(r, 'drive') == '1' and g(r, 'blk') == '1')
    # 5) 罚站：无逃逸/无让弹/无绕行还 drive=0（合法停车只剩打侧躲弹）
    idle = sum(1 for r in alive if g(r, 'drive') == '0' and g(r, 'esc') == '0'
               and g(r, 'det') == '0' and g(r, 'evT') == '0' and g(r, 'patrol') == '0')
    # 6) navA 剧变：相邻帧期望角变化>90°（口径跳变=方向盘乱打）
    swing = 0
    for a, b in zip(alive, alive[1:]):
        if g(a, 'patrol') == '1' or g(b, 'patrol') == '1':
            continue
        d = abs(int(a[I['navA']]) - int(b[I['navA']])) % 360
        if d > 180:
            d = 360 - d
        if d > 90 and g(a, 'tgtIdx') == g(b, 'tgtIdx') and g(a, 'tgtIdx') != '-1':
            swing += 1
    # 7) 有目标且 LOS 通却不开火的"瞄半天"占比；和 巡逻占比
    aim_only = sum(1 for r in alive if g(r, 'los') == '1' and g(r, 'patrol') == '0'
                   and g(r, 'inFire') == '0' and int(g(r, 'fireCd')) == 0)
    pat = sum(1 for r in alive if g(r, 'patrol') == '1')
    print("slot%s alive=%d | 摇头%dd(%.1f/100tick) 换目标%d 倒车%d(裸倒%d) 挂墙%d 罚站%d "
          "navA突变%d 空瞄%d 巡逻%d" % (
              slot, len(alive), alt, 100.0 * alt / n, tj, rev, rev_esc, hang, idle,
              swing, aim_only, pat))
