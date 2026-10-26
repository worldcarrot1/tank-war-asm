# -*- coding: utf-8 -*-
# rl_probe47.py —— 会话47 训练信号诊断：回合终止瞬间到底发生了什么
# 逐项计数：双方阵亡事件 / roundsPlayed 跳变 / 跳变时谁改了分 / matchOver。
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from rl_env import TankEnv
import rl_train as T

N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
env = TankEnv()
st = dict(esin=0.0, ecos=0.0)
p = dict(np.load(T.CKPT)) if os.path.exists(T.CKPT) else T.init_nn()
s = env.reset(seed=12345)

c = dict(steps=0, die0=0, die1=0, rps_chg=0, rps_chg_scored0=0,
         rps_chg_scored1=0, rps_chg_noscore=0, match_over=0,
         fire0=0, move0=0, hpchg=0)
rng = np.random.default_rng(7)
for t in range(N):
    o = T.build_obs(env, s, st)
    _, _, pi, v = T.forward(p, o[None])
    ps = T.softmax(pi)
    a = int(rng.choice(T.NA, p=ps[0]))
    prev = s
    s = env.step(tuple(T.A6[a].tolist()), rep=1, act1=None)
    tv = env.tv
    c["steps"] += 1
    if a % 16 != 15 and T.A6[a, 4]:          # 开火动作
        c["fire0"] += 1
    if T.A6[a, 0] or T.A6[a, 1] or T.A6[a, 2] or T.A6[a, 3]:
        c["move0"] += 1
    if tv(prev, 0, "alive") and not tv(s, 0, "alive"):
        c["die0"] += 1
        print(f"tick{prev['tick']+1} slot0阵亡 hp0={tv(prev,0,'hp')}->0 "
              f"hp1={tv(s,1,'hp')} rps {prev['roundsPlayed']}->{s['roundsPlayed']}")
    if tv(prev, 1, "alive") and not tv(s, 1, "alive"):
        c["die1"] += 1
        print(f"tick{prev['tick']+1} slot1阵亡 rps {prev['roundsPlayed']}->{s['roundsPlayed']}")
    if prev["roundsPlayed"] != s["roundsPlayed"]:
        c["rps_chg"] += 1
        d0 = tv(s, 0, "score") - tv(prev, 0, "score")
        d1 = tv(s, 1, "score") - tv(prev, 1, "score")
        if d0 > 0: c["rps_chg_scored0"] += 1
        elif d1 > 0: c["rps_chg_scored1"] += 1
        else:
            c["rps_chg_noscore"] += 1
            print(f"tick{prev['tick']+1} 轮次跳变但无人加分! sc {tv(prev,0,'score')}/{tv(prev,1,'score')}"
                  f"->{d0}/{d1} alive {tv(prev,0,'alive')}/{tv(prev,1,'alive')}"
                  f"-> {tv(s,0,'alive')}/{tv(s,1,'alive')} hp {tv(s,0,'hp')}/{tv(s,1,'hp')}")
    if s["matchOver"]:
        c["match_over"] += 1
        print(f"tick{prev['tick']+1} matchOver rps={s['roundsPlayed']}")
        s = env.reset(seed=12345 + c["match_over"])
    # 单发命中的话 hp 会掉
for k, u in c.items():
    print(f"{k:18s} {u}")
env.close()
