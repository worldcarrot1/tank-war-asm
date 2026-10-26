# -*- coding: utf-8 -*-
# ============================================================
# rl_reflex_probe.py —— 会话51 B0：CPA 躲避反射叠加层免训练探针
# 背景：run23/24/25 三连终判坐实"定价穷尽"——V3 特征让躲避变便宜后，
# 均衡双峰化（纯龟 暴露0.38/和95/火0.0 vs 莽夫 暴露0.89/和47），价格
# 只能选角落不能造中间态 ⇒ 躲与火在抢同一张 MLP 的容量。B 案=把"躲"
# 从学习问题降级成几何问题：仿 rlBeacon，在 logits 上按 CPA 威胁给
# 转向/移动通道加先验偏置，NN 权重只管火/瞄/技能且完全不动。
# 本探针先零训练验证：14champ + 叠加 vs 裸冠军，双池读 火/暴露/和。
# 全部算术只用 mul/add/sqrt+dir 表可复刻原语（仿 beacon 约束，asm 镜像
# 时逐式对应）。判定标准：叠加后 火≥4.0/千t 且 暴露<0.56 且 和>82。
# 用法：python -I tools/rl_reflex_probe.py --pool script [--rounds 30]
#        [--kr 1.2] [--kt 0.8] [--line 26] [--tau 48] [--off]
# ============================================================
import os, sys, math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train
from rl_train import Vec, Cap, forward, ROOT


def reflex_bonus(vec, j, s, kr, kt, line, tau):
    """返回 36 维 logits 偏置：对"增大 |横向偏距| 最快"的移动/转向组合加分。
    威胁判据与 OBS_V3 尾列同几何：迎面(dot3>0) ∧ t*<tau ∧ |lat|<line。
    自弹不过滤——回弹打自己同样要躲（与 build_obs 口径一致）。"""
    e = vec.envs[j]
    tv = e.tv
    b = np.zeros(36, dtype=np.float32)
    if not tv(s, 0, "alive"):
        return b
    x, y = tv(s, 0, "x"), tv(s, 0, "y")
    dr = math.radians(tv(s, 0, "dir") % 360)
    c, sn = math.cos(dr), math.sin(dr)        # 车头单位向量 ĥ
    cx, cy = -sn, c                           # ĥ 逆时针90°导数方向（dir+ 旋转向）
    for bl in s["bullets"][:e.MAX_BULLETS]:
        if not bl[e.bul_dw["active"]]:
            continue
        dx = float(bl[e.bul_dw["x"]] - x)     # 我->弹 d（与 obs 同向）
        dy = float(bl[e.bul_dw["y"]] - y)
        vx = bl[e.bul_dw["vx"]]
        vy = bl[e.bul_dw["vy"]]
        if vx >= 0x80000000:
            vx -= 0x100000000
        if vy >= 0x80000000:
            vy -= 0x100000000
        vxp = vx / 65536.0                    # px/tick（16.16 定点换算）
        vyp = vy / 65536.0
        s2 = vxp * vxp + vyp * vyp
        dot3 = -(vxp * dx + vyp * dy)         # 弹->我 r=-d 上的投影（>0 迎面）
        if s2 <= 0.0 or dot3 <= 0.0:
            continue
        tstar = dot3 / s2                     # 到 CPA 拍数
        if tstar >= tau:
            continue
        sv = math.sqrt(s2)
        latS = (vxp * dy - vyp * dx) / sv     # signed 横向偏距(px)：n̂=(-vyp,vxp)/sv
        if abs(latS) >= line:
            continue
        u = 1.0 - tstar / tau                 # 紧迫度 ∈(0,1]
        sl = 1.0 if latS >= 0.0 else -1.0     # 使 |lat| 增大的方向符号
        ph = sl * (-c * vyp + sn * vxp) / sv  # d|lat|/dt / |v|：直行的横向速度分量
        pt = sl * (-cx * vyp + cy * vxp) / sv # 车头旋转的横向速度分量（单位角速度）
        for k in range(36):
            mv = k // 12                      # 0前进 1倒车 2停
            tn = (k // 4) % 3                 # 0左转(CCW,dir-) 1右转(CW,dir+) 2停
            mvs = 1.0 if mv == 0 else (-1.0 if mv == 1 else 0.0)
            tns = (-1.0 if tn == 0 else (1.0 if tn == 1 else 0.0))
            b[k] += u * (kr * mvs * ph + kt * tns * pt)
    return b


def run(opp, nenv, rounds, p, kr, kt, line, tau, use_reflex, stat=False):
    vec = Vec(nenv, 999_001, opp=opp)
    cap = Cap(nenv)
    per = [rounds // nenv + (1 if i < rounds % nenv else 0) for i in range(nenv)]
    wins = tot = 0
    n_trig = n_flip = n_dec = 0
    tag = ("反射 kr=%.2f kt=%.2f line=%.0f tau=%.0f" % (kr, kt, line, tau)) \
        if use_reflex else "裸冠军基线"
    for j in range(nenv):
        cnt = ep = 0
        while cnt < per[j]:
            ep += 1
            if ep > 3000 * (per[j] + 1):
                break
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            z = pi[0]
            if use_reflex:
                b = reflex_bonus(vec, j, vec.s[j], kr, kt, line, tau)
                if stat:
                    n_dec += 1
                    if b.any():
                        n_trig += 1
                    if int(z.argmax()) != int((z + b).argmax()):
                        n_flip += 1
                z = z + b
            act = int(z.argmax())
            prev, s = vec.step(j, act)
            vec.note(j, prev, s)
            cap.update(vec, j, prev, s)
            over = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
            if over or ep % 2500 == 0:
                stj = vec.st[j]
                w = 1 if (over and stj["sc0"] > stj["sc1"]) else 0
                wins += w
                tot += 1
                vec.reseed(j)
                ep = 0
                cnt += 1
    for e in vec.envs:
        e.close()
    k1k = 1000.0 / max(cap.ticks, 1)
    ex = cap.hits * k1k
    dk = 100.0 * cap.dA / max(cap.dA + cap.dF, 1)
    print(f"[{opp}] {tag}: 回合胜 {wins}/{tot}={100.0*wins/max(tot,1):.0f}%  "
          f"火{cap.shots*k1k:.1f}/千t 杀归{cap.kills*k1k:.2f} 暴露{ex:.2f}/千t "
          f"躲{100.0*cap.dodges/max(cap.dodges+cap.hits,1):.0f}% 主躲{dk:.0f}% "
          f"拾{cap.sk_grab}/发{cap.sk_act} ticks={cap.ticks}", flush=True)
    if stat:
        print(f"[{opp}] {tag} STAT: 决策{n_dec} 触发率={100.0*n_trig/max(n_dec,1):.1f}% "
              f"翻转率={100.0*n_flip/max(n_dec,1):.2f}%", flush=True)
    return wins, tot


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", default="both", choices=("script", "heuristic", "both"),
                    help="评估池；both=脚本池+启发池各跑一遍（和=两池胜%之和，finals 同尺）")
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=30)
    ap.add_argument("--kr", type=float, default=1.2, help="直行通道增益")
    ap.add_argument("--kt", type=float, default=0.8, help="转向通道增益")
    ap.add_argument("--line", type=float, default=26.0, help="在线上判据(px)")
    ap.add_argument("--tau", type=float, default=48.0, help="威胁窗(tick)")
    ap.add_argument("--init", default="rl_policy_best.npz")
    ap.add_argument("--off", action="store_true", help="关反射出裸冠军基线")
    ap.add_argument("--stat", action="store_true", help="逐 tick 统计触发率/argmax 翻转率")
    a = ap.parse_args()
    path = a.init if os.path.isabs(a.init) else os.path.join(ROOT, a.init)
    p = dict(np.load(path))
    p.pop("obsv2", None)
    p.pop("obsv3", None)
    rl_train.apply_obsv3(p["l1w"].shape[0] == 102)
    pools = ("script", "heuristic") if a.pool == "both" else (a.pool,)
    for opp in pools:
        run(opp, a.envs, a.rounds, p, a.kr, a.kt, a.line, a.tau, not a.off, a.stat)


if __name__ == "__main__":
    main()
