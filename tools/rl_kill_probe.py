# -*- coding: utf-8 -*-
# ============================================================
# rl_kill_probe.py —— 会话50b：激进陪练的"击杀信号"实测（A/B）
# 背景：达标线 5/12、run16 装死案的根因都是启发式陪练惜弹（实测
# ~1.2 发/千t 且隔墙静默）→ NN 收不到死亡梯度。botAggro 语义已
# 重做（误差 6° + 视线闸三级抢救：直视/靶心/盲射走廊），本脚本量
# 它作为陪练的真实产出：
#   opp杀/千t（=ego 死亡=正梯度主源）、opp发/千t、opp自亡/千t
#   （盲射回弹自杀的代价项）、ego杀/千t（对手机会）。
# 双臂：opp=heuristic（旧） vs opp=heurA（激进），同 env 数同局数。
# 用法：python -I tools/rl_kill_probe.py [--envs 4] [--rounds 4]
#        [--init rl_policy_14champ.bak.npz]
# ============================================================
import os, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train
from rl_train import Vec, forward, ROOT


def arm(opp, nenv, rounds, p, tag):
    vec = Vec(nenv, 999_001, opp=opp)
    per = [rounds // nenv + (1 if i < rounds % nenv else 0) for i in range(nenv)]
    tot_t = 0
    opp_kills = ego_kills = opp_shots = opp_deaths = ego_deaths = 0
    t0 = time.time()
    for j in range(nenv):
        cnt = ep = 0
        prev_opp_active = set()
        while cnt < per[j]:
            ep += 1
            if ep > 3000 * (per[j] + 1):
                break
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            act = int(pi[0].argmax())
            prev, s = vec.step(j, act)
            vec.note(j, prev, s)     # 会话50b修正：st 记分簿只由 note 维护，
                                     # 漏调 ⇒ sc0/sc1 恒初值，上版杀数全 0 皆因此
            e = vec.envs[j]
            tot_t += 1
            # opp 发数：owner==1 活跃弹索引新出现计数
            now = set(i for i, bl in enumerate(s["bullets"][:e.MAX_BULLETS])
                      if bl[e.bul_dw["active"]] and bl[e.bul_dw["owner"]] == 1)
            opp_shots += len(now - prev_opp_active)
            prev_opp_active = now
            # 死亡翻转（alive 1→0）
            if prev and e.tv(prev, 1, "alive") and not e.tv(s, 1, "alive"):
                opp_deaths += 1
            if prev and e.tv(prev, 0, "alive") and not e.tv(s, 0, "alive"):
                ego_deaths += 1
            over = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
            if over or ep % 2500 == 0:
                stj = vec.st[j]
                opp_kills += stj["sc1"]
                ego_kills += stj["sc0"]
                vec.reseed(j)
                ep = 0
                cnt += 1
    for e in vec.envs:
        e.close()
    k = 1000.0 / max(tot_t, 1)
    print(f"[{tag}] t={tot_t} opp发={opp_shots*k:.1f}/千t opp杀={opp_kills*k:.2f}/千t "
          f"opp自亡={opp_deaths*k:.2f}/千t | ego杀={ego_kills*k:.2f}/千t "
          f"ego死={ego_deaths*k:.2f}/千t 用时{time.time()-t0:.0f}s", flush=True)
    return dict(shots=opp_shots, kills=opp_kills, osu=opp_deaths,
                ek=ego_kills, ed=ego_deaths, t=tot_t)


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--init", default="rl_policy_14champ.bak.npz")
    a = ap.parse_args()
    path = a.init if os.path.isabs(a.init) else os.path.join(ROOT, a.init)
    p = dict(np.load(path))
    if "obsv2" in p:
        rl_train.OBS_V2 = bool(float(np.asarray(p["obsv2"]).ravel()[0]))
    else:
        rl_train.OBS_V2 = False
    print("== 旧档 heuristic ==")
    arm("heuristic", a.envs, a.rounds, p, "heur")
    print("== 激进档 heurA ==")
    arm("heurA", a.envs, a.rounds, p, "heurA")
