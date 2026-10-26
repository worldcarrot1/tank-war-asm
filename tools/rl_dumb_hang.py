# -*- coding: utf-8 -*-
# ============================================================
# rl_dumb_hang.py —— 会话48：挂墙段细看（承接 rl_dumb_nn 的 3 段）。
# 复刻体检同一 env/seed 前缀（2026_1024），逐 tick 记 (x,y,dir,m,t)，
# 检出"给移动指令但位置连动>=12 tick"的段，打印段首动作组合+朝向，
# 判定：t=2 直顶墙(真挂) vs 边转边顶(绕墙中，假挂)。
# 用法：python -I tools/rl_dumb_hang.py [steps]
# ============================================================
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import rl_train as T

T.OBS_V2 = False
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 2400
p = dict(np.load(os.path.join(ROOT, "rl_policy_14champ.bak.npz")))
vec = T.Vec(1, 2026_1024, opp="script")
recs = []
try:
    cnt = 0
    while cnt < STEPS:
        o = vec.obs(0)
        _, _, pi, _ = T.forward(p, np.asarray(o)[None])
        act = int(pi[0].argmax())
        m, t = act // 12, (act // 4) % 3
        e = vec.envs[0]
        recs.append((cnt, m, t, e.tv(vec.s[0], 0, "x"), e.tv(vec.s[0], 0, "y"),
                     e.tv(vec.s[0], 0, "dir") % 360))
        prev, s = vec.step(0, act)
        vec.note(0, prev, s)
        if bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]):
            vec.reseed(0)
        cnt += 1
finally:
    for ev in vec.envs:
        ev.close()

a = np.array(recs)
alive = a[:, 0].astype(int)  # 全 tick（本探针不筛存活，x,y 死后可见）
moved = np.abs(np.diff(a[:, 3])) + np.abs(np.diff(a[:, 4])) > 0
stuck = (a[:, 1] != 2) & np.concatenate(([0], moved == 0))
cur, segs = 0, []
for i, v in enumerate(stuck):
    if v:
        cur += 1
    else:
        if cur >= 12:
            segs.append((i - cur, cur))
        cur = 0
if cur >= 12:
    segs.append((len(stuck) - cur, cur))
print("挂墙段 %d" % len(segs))
for st, L in segs:
    blk = a[st:st + L]
    turns = int(np.sum(blk[:, 2] != 2))
    print("  tick %d 起 %d 帧: m=%s t转帧=%d/%d dir=%d→%d xy=(%d,%d)" %
          (blk[0, 0], L, ",".join(str(int(v)) for v in np.unique(blk[:, 1])),
           turns, L, blk[0, 5], blk[-1, 5], blk[0, 3], blk[0, 4]))
