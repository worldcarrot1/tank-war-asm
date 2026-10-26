# -*- coding: utf-8 -*-
# ============================================================
# rl_beacon_probe.py —— 会话47 Phase3：道具信标叠加层（Python 先行调参）
# 背景：16 轮 RL 终判——趋近道具与交战卡距是策略几何冲突，纯权重学不会
# （进圈带 0~0.2%）。定版方案 = run14 冠军纯权重 + 运行时叠加层：向"能
# 接近道具"的动作加 logits 偏置，然后照抄这套算术蒸馏进 bot.asm（rlbot）。
# 本脚本精确复刻将来 asm 侧可用的原语（点积/叉积/距离带/威胁计数，无
# atan2 等超越函数，asm 侧只有 fsqrt），参数调好后 asm 逐式对应。
# 用法：python -I tools/rl_beacon_probe.py [--opp script|heuristic]
#        [--envs 4] [--rounds 30] [--km 1.2] [--kt 0.6] [--thr 1]
#        [--init rl_policy_14champ.bak.npz] [--off]（--off=纯权重基线）
# ============================================================
import os, sys, math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train
from rl_train import Vec, Cap, forward, A6, env_tv, ROOT


def beacon_bonus(vec, j, s, km, kt, thr):
    """返回 36 维 logits 偏置（float32）。全部量可用 x87 mul/add/sqrt 复刻。"""
    e = vec.envs[j]
    tv = e.tv
    b = np.zeros(36, dtype=np.float32)
    if s["pickupType"] == 0 or not tv(s, 0, "alive"):
        return b
    x, y = tv(s, 0, "x"), tv(s, 0, "y")
    dx = float(s["pickupX"] - x)
    dy = float(s["pickupY"] - y)
    d = math.sqrt(dx * dx + dy * dy)
    if d < 40.0 or d > 700.0:               # 太近让 NN 自己处理；太远不值得
        return b
    # 威胁闸：260px 内"接近中"敌弹数 >= thr+1 → 关信标（活着比道具重要）
    n_in = 0
    for bl in s["bullets"][:e.MAX_BULLETS]:
        if not bl[e.bul_dw["active"]] or bl[e.bul_dw["owner"]] == 0:
            continue
        bx = float(bl[e.bul_dw["x"]] - x)
        by = float(bl[e.bul_dw["y"]] - y)
        vx = bl[e.bul_dw["vx"]]
        vy = bl[e.bul_dw["vy"]]
        if vx >= 0x80000000:
            vx -= 0x100000000
        if vy >= 0x80000000:
            vy -= 0x100000000
        if bx * bx + by * by < 260.0 * 260.0 and bx * vx + by * vy < 0:
            n_in += 1
    if n_in > thr:
        return b
    # 距离带系数（无 sqrt 的分级比较已在 d 上顺带算完）
    w = 1.0 if d < 200.0 else (0.6 if d < 400.0 else 0.3)
    dr = math.radians(tv(s, 0, "dir") % 360)
    c, sn = math.cos(dr), math.sin(dr)
    dotN = (c * dx + sn * dy) / d          # 车头指向道具程度 ∈[-1,1]
    crsN = (c * dy - sn * dx) / d          # sin(道具角-车头角)：>0 右转靠近
    for k in range(36):
        mv = k // 12                        # 0前进 1倒车 2停
        tn = (k // 4) % 3                   # 0左转(CCW,dir-) 1右转(CW,dir+) 2停
        mvs = dotN if mv == 0 else (-dotN if mv == 1 else 0.0)
        tns = (-crsN if tn == 0 else (crsN if tn == 1 else 0.0))
        b[k] = w * (km * mvs + kt * tns)
    return b


def run(opp, nenv, rounds, p, km, kt, thr, use_beacon):
    vec = Vec(nenv, 999_001, opp=opp)
    cap = Cap(nenv)
    per = [rounds // nenv + (1 if i < rounds % nenv else 0) for i in range(nenv)]
    wins = tot = 0
    t_zone = t_band = t_pk = 0
    dists = []
    tag = ("信标 km=%.2f kt=%.2f thr=%d" % (km, kt, thr)) if use_beacon else "纯权重基线"
    for j in range(nenv):
        cnt = ep = 0
        while cnt < per[j]:
            ep += 1
            if ep > 3000 * (per[j] + 1):
                break
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            z = pi[0]
            if use_beacon:
                z = z + beacon_bonus(vec, j, vec.s[j], km, kt, thr)
            act = int(z.argmax())
            prev, s = vec.step(j, act)
            vec.note(j, prev, s)
            cap.update(vec, j, prev, s)
            e = vec.envs[j]
            if s["pickupType"] > 0 and e.tv(s, 0, "alive") and e.tv(s, 1, "alive"):
                d = math.dist((e.tv(s, 0, "x"), e.tv(s, 0, "y")),
                              (s["pickupX"], s["pickupY"]))
                dists.append(d)
                t_pk += 1
                if d < 80.0:
                    t_zone += 1
                if d < 26.0:
                    t_band += 1
            over = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
            if over or ep % 2500 == 0:
                stj = vec.st[j]
                # 会话48修正：原式 `sc0>sc1 if not (ep % 2500) else False`
                # 判定反了——常规局(not(非0)=False)一律走 else False 全记负，
                # 只有超时局才比 sc0>sc1。正确语义：自然局比 sc，超时记负。
                w = 1 if (over and stj["sc0"] > stj["sc1"]) else 0
                wins += w
                tot += 1
                # 会话48：逐局进度（script 平局会打满 2500t，长跑必须可见）
                print("[%s] env%d 局%d tot=%d %s ep=%d sc=%d:%d 累计%d/%d"
                      % (tag, j, cnt + 1, tot, "胜" if w else "负", ep,
                         stj["sc0"], stj["sc1"], wins, tot), flush=True)
                vec.reseed(j)
                ep = 0
                cnt += 1
    for e in vec.envs:
        e.close()
    k1k = 1000.0 / max(cap.ticks, 1)
    ds = np.array(dists) if dists else np.array([float("nan")])
    tag = ("信标 km=%.2f kt=%.2f thr=%d" % (km, kt, thr)) if use_beacon else "纯权重基线"
    print(f"[{opp}] {tag}: 回合胜 {wins}/{tot}={100.0*wins/max(tot,1):.0f}%  "
          f"火{cap.shots*k1k:.1f}/千t 杀{cap.kills*k1k:.2f} 躲{100.0*cap.dodges/max(cap.dodges+cap.hits,1):.0f}%  "
          f"拾{cap.sk_grab}/发{cap.sk_act}  在场{t_pk}t 进圈带={100.0*t_zone/max(t_pk,1):.1f}% "
          f"拾取带={100.0*t_band/max(t_pk,1):.1f}% p10={np.percentile(ds,10):.0f} p50={np.percentile(ds,50):.0f}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--opp", default="script")
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=30)
    ap.add_argument("--km", type=float, default=1.2)
    ap.add_argument("--kt", type=float, default=0.6)
    ap.add_argument("--thr", type=int, default=1)
    ap.add_argument("--init", default="rl_policy_14champ.bak.npz")
    ap.add_argument("--off", action="store_true", help="关掉信标出纯权重基线")
    a = ap.parse_args()
    path = a.init if os.path.isabs(a.init) else os.path.join(ROOT, a.init)
    p = dict(np.load(path))
    if "obsv2" in p:
        rl_train.OBS_V2 = bool(float(np.asarray(p["obsv2"]).ravel()[0]))
    else:
        rl_train.OBS_V2 = False
    run(a.opp, a.envs, a.rounds, p, a.km, a.kt, a.thr, not a.off)


if __name__ == "__main__":
    main()
