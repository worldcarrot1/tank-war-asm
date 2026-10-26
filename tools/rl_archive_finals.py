# -*- coding: utf-8 -*-
# ============================================================
# rl_archive_finals.py —— 会话51：历史网络档案 finals 重烤
# run17 教训：选拔终点若无"≥在位冠军"护栏就会误覆写；反过来也说明
# 有些历史候选从未按双池 和 口径复评过（当年只用 mix 快评 comp 排序）。
# 本脚本把全部存档按 finals 同协议（seed0=999_001, 4env×60 回合,
# script/heuristic 双池）逐一正评，找是否存在被低估的 >=82 档，
# 为 run18 的 init 选点与"天花板位置"提供数据。
# 用法：python -I tools/rl_archive_finals.py [npz ...]（缺省=内置清单）
# ============================================================
import os, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train
from rl_train import eval_greedy, ROOT

DEFAULT = ["rl_policy_14champ.bak.npz", "rl_policy_15champ.bak.npz",
           "rl_policy_16champ.bak.npz", "rl_policy_skbest.npz",
           "rl_policy_cand1.npz", "rl_policy_cand2.npz",
           "rl_policy_cand3.npz", "rl_policy_turtle58.npz"]

if __name__ == "__main__":
    names = sys.argv[1:] or DEFAULT
    for nm in names:
        path = nm if os.path.isabs(nm) else os.path.join(ROOT, nm)
        if not os.path.exists(path):
            print(f"[{nm}] 缺档", flush=True)
            continue
        p = dict(np.load(path))
        t0 = time.time()
        # 会话51 单位案：eval_greedy 首值是胜"数"非百分比（14champ 当年
        # "30/60=50%"被本脚本首版打成 script=30%，和=49 假象）。同尺换算。
        w1, n1, _, _, cs = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                       opp="script", pdict=p)
        w2, n2, _, _, ch = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                       opp="heuristic", pdict=p)
        rs, rh = 100.0 * w1 / max(n1, 1), 100.0 * w2 / max(n2, 1)
        k1 = 1000.0 / max(cs.ticks + ch.ticks, 1)
        print(f"[{nm}] script={rs:.0f}%(火{cs.shots*1000/max(cs.ticks,1):.1f}"
              f" 躲{100.0*cs.dodges/max(cs.dodges+cs.hits,1):.0f}%)"
              f" heur={rh:.0f}%(火{ch.shots*1000/max(ch.ticks,1):.1f})"
              f" 和={rs+rh:.0f} 用时{time.time()-t0:.0f}s", flush=True)
