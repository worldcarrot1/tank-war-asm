# -*- coding: utf-8 -*-
# ============================================================
# item_probe47e.py —— 会话47E：技能道具瓶颈切片探针
# 问题：run4~7 能力卡技能"拾取"全程 0（道具在场 20~50% tick）。
# 两种病因要分辨：A=策略从不走近道具（激励问题）；B=走近了也拾不到
# （几何/机制问题）。逐 tick 记 ego 与道具的角点距，输出分位直方 +
# 关键带（<26 拾取带 / <80 进圈带）tick 占比 + 技能键按下率。
# 用法：python -I tools/item_probe47e.py [npz ...]（默认 best+final）
# ============================================================
import os, sys, math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train
from rl_train import Vec, forward

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = [a if os.path.isabs(a) else os.path.join(ROOT, a)
           for a in (sys.argv[1:] or ["rl_policy_best.npz", "rl_policy.npz"])]
ROUNDS_PER_ENV = 6


def probe(path):
    p = dict(np.load(path))
    if "obsv2" in p:                       # run15：随权重自动切编码
        import numpy as _np
        rl_train.OBS_V2 = bool(float(_np.asarray(p["obsv2"]).ravel()[0]))
    vec = Vec(4, 20261024, opp="script")
    dists = []
    t_zone = t_band = grabs = skill_act = sk_key_t = alive_t = 0
    for j in range(4):
        vec.reseed(j)
        prev = vec.s[j]
        rounds = 0
        ep = 0
        while rounds < ROUNDS_PER_ENV:
            ep += 1
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            a = int(pi[0].argmax())
            prev, s = vec.step(j, a)
            e = vec.envs[j]; tv = e.tv
            if tv(s, 0, "alive"):
                alive_t += 1
                if a % 2:                       # k=mv*12+tn*4+f*2+s → s=a%2
                    sk_key_t += 1
            if s["pickupType"] > 0 and tv(s, 0, "alive") and tv(s, 1, "alive"):
                d = math.dist((tv(s, 0, "x"), tv(s, 0, "y")),
                              (s["pickupX"], s["pickupY"]))
                dists.append(d)
                if d < 80.0:
                    t_zone += 1
                if d < 26.0:
                    t_band += 1
            if tv(prev, 0, "skill") == 0 and tv(s, 0, "skill") > 0:
                grabs += 1
            if tv(prev, 0, "skill") > 0 and tv(s, 0, "skill") == 0:
                skill_act += 1
            if s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]:
                rounds += 1
                vec.reseed(j)
                prev = vec.s[j]
                ep = 0
            if ep > 4000:                       # 防御：僵住就换局
                vec.reseed(j)
                prev = vec.s[j]
                rounds += 1
                ep = 0
    for en in vec.envs:
        en.close()
    ds = np.array(dists) if dists else np.array([float("nan")])
    tot = len(dists)
    print(f"\n### {os.path.basename(path)}")
    print(f"道具在场&双方存活 tick={tot}  <26px 拾取带={100.0*t_band/max(tot,1):.1f}%  "
          f"<80px 进圈带={100.0*t_zone/max(tot,1):.1f}%")
    qs = "  ".join(f"p{q}={np.percentile(ds, q):.0f}" for q in (10, 50, 90))
    print(f"距道具 {qs} px   拾取={grabs} 发动={skill_act}  "
          f"技能键按下率={100.0*sk_key_t/max(alive_t,1):.1f}%")


for path in TARGETS:
    if os.path.exists(path):
        probe(path)
    else:
        print("缺文件:", path)
