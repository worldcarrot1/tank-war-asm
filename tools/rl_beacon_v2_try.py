# -*- coding: utf-8 -*-
# ============================================================
# rl_beacon_v2_try.py —— 会话48 夜间：信标"末段压制"变体试验。
# 已证：纯正吸引 bonus（现 RL_BKM=1.2 / 扫到 3.0/6.0）进圈带恒 0%——
# 冠军网趋近道具时"倒车远离"margin 稳，20% 翻转也停在 ~200px 带。
# 变体：d<D_FAR(700) 用原正吸引；d<D_NEAR(260) 追加"倒车远离大罚"
# （mvs<-0.3 的倒车动作 bonus -= PEN），把"不许退离"作为硬约束。
# 指标：进圈带(d<80)/拾取带(d<26)/回合胜/火/千t，与 off、km3 对比。
# 用法：python -I tools/rl_beacon_v2_try.py [envs] [rounds] [pen]
# ============================================================
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import rl_train as T
from rl_train import Vec, Cap, forward

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T.OBS_V2 = False
NEV = int(sys.argv[1]) if len(sys.argv) > 1 else 2
RND = int(sys.argv[2]) if len(sys.argv) > 2 else 12
PEN = float(sys.argv[3]) if len(sys.argv) > 3 else 8.0
KM, KT, THR = 3.0, 1.5, 1
D_FAR, D_NEAR = 700.0, 260.0
p = dict(np.load(os.path.join(ROOT, "rl_policy_14champ.bak.npz")))


def bonus2(vec, j, s):
    """km3 正吸引 + 近场倒车远离惩罚。全部量 asm 可复刻（sqrt/乘加）。"""
    e = vec.envs[j]
    tv = e.tv
    b = np.zeros(36, dtype=np.float32)
    if s["pickupType"] == 0 or not tv(s, 0, "alive"):
        return b
    x, y = tv(s, 0, "x"), tv(s, 0, "y")
    dx = float(s["pickupX"] - x)
    dy = float(s["pickupY"] - y)
    d = math.sqrt(dx * dx + dy * dy)
    if d < 40.0 or d > D_FAR:
        return b
    n_in = 0
    for bl in s["bullets"][:e.MAX_BULLETS]:
        if not bl[e.bul_dw["active"]] or bl[e.bul_dw["owner"]] == 0:
            continue
        bx = float(bl[e.bul_dw["x"]] - x)
        by = float(bl[e.bul_dw["y"]] - y)
        vx, vy = bl[e.bul_dw["vx"]], bl[e.bul_dw["vy"]]
        if vx >= 0x80000000:
            vx -= 0x100000000
        if vy >= 0x80000000:
            vy -= 0x100000000
        if bx * bx + by * by < 260.0 * 260.0 and bx * vx + by * vy < 0:
            n_in += 1
    if n_in > THR:
        return b
    w = 1.0 if d < 200.0 else (0.6 if d < 400.0 else 0.3)
    dr = math.radians(tv(s, 0, "dir") % 360)
    c, sn = math.cos(dr), math.sin(dr)
    dotN = (c * dx + sn * dy) / d
    crsN = (c * dy - sn * dx) / d
    near = d < D_NEAR
    for k in range(36):
        mv = k // 12
        tn = (k // 4) % 3
        mvs = dotN if mv == 0 else (-dotN if mv == 1 else 0.0)
        tns = (-crsN if tn == 0 else (crsN if tn == 1 else 0.0))
        val = w * (KM * mvs + KT * tns)
        if near and mv == 1 and dotN > 0.3:     # 倒车且道具在车头前方=远离
            val -= PEN * dotN
        b[k] = val
    return b


vec = Vec(NEV, 999_001, opp="script")
cap = Cap(NEV)
per = [RND // NEV + (1 if i < RND % NEV else 0) for i in range(NEV)]
wins = tot = t_zone = t_band = t_pk = 0
try:
    for j in range(NEV):
        cnt = ep = 0
        while cnt < per[j]:
            ep += 1
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            act = int((pi[0] + bonus2(vec, j, vec.s[j])).argmax())
            prev, s = vec.step(j, act)
            vec.note(j, prev, s)
            cap.update(vec, j, prev, s)
            e = vec.envs[j]
            if s["pickupType"] > 0 and e.tv(s, 0, "alive") and e.tv(s, 1, "alive"):
                d = math.dist((e.tv(s, 0, "x"), e.tv(s, 0, "y")),
                              (s["pickupX"], s["pickupY"]))
                t_pk += 1
                if d < 80.0:
                    t_zone += 1
                if d < 26.0:
                    t_band += 1
            over = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
            if over or ep % 2500 == 0:
                stj = vec.st[j]
                wins += 1 if (over and stj["sc0"] > stj["sc1"]) else 0
                tot += 1
                vec.reseed(j)
                ep = 0
                cnt += 1
                print("env%d 局%d %s sc=%d:%d 累计%d/%d" %
                      (j, cnt, "胜" if over and stj["sc0"] > stj["sc1"] else "负",
                       stj["sc0"], stj["sc1"], wins, tot), flush=True)
finally:
    for e in vec.envs:
        e.close()
k1k = 1000.0 / max(cap.ticks, 1)
print("[v2 PEN=%.1f] 回合胜 %d/%d=%.0f%% 火%.1f/千t 杀%.2f 拾%d/发%d "
      "在场%dt 进圈带=%.1f%% 拾取带=%.1f%%" %
      (PEN, wins, tot, 100.0 * wins / max(tot, 1), cap.shots * k1k,
       cap.kills * k1k, cap.sk_grab, cap.sk_act, t_pk,
       100.0 * t_zone / max(t_pk, 1), 100.0 * t_band / max(t_pk, 1)))
