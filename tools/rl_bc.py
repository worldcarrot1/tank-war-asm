# -*- coding: utf-8 -*-
# ============================================================
# rl_bc.py —— 会话47C：行为克隆（Behavior Cloning）热启动
# 思路：从零 PPO 追不上启发式 bot（1.4M 步仍 5% 胜率），就直接
# 拜它为师——rlhost 换位模式（flags.bit1：slot0=bot、slot1=主机），
# 逐 tick 采 (ego=slot1 观测90维 → 标签=inputTable[0..5] bot 电平)，
# 交叉熵拟合现有 90→128→128 网络，得到"复刻启发式"的初始策略；
# 之后再用 PPO 在这个起点上超越它（陪练与学徒同源，课程天然平滑）。
# 用法：python tools/rl_bc.py [--frames 120000] [--envs 4] [--eval]
# ============================================================
import os, sys, time, argparse
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train as T
import rl_env
from rl_env import TankEnv


def levels_to_act(l, fire, skill):
    """走/转读快照电平（水平通道，消费后保留）；火/技是边沿脉冲，GameUpdate
    消费即清零、帧尾读不到，改由状态导出版（见 collect 注释）。
    k = 走*12+转*4+火*2+技。"""
    mv = 0 if (l[0] and not l[1]) else (1 if (l[1] and not l[0]) else 2)
    tn = 0 if (l[2] and not l[3]) else (1 if (l[3] and not l[2]) else 2)
    return mv*12 + tn*4 + (1 if fire else 0)*2 + (1 if skill else 0)


def collect(nenv, frames, seed0=777_001):
    """换位 env 组：slot0=启发式 bot（标签源），slot1=漂移伪输入。"""
    envs = [TankEnv() for _ in range(nenv)]
    sts = [dict(esin=0.0, ecos=0.0) for _ in range(nenv)]
    seeds = [seed0 + 7919*i for i in range(nenv)]
    s = [e.reset(sd, swap=True) for e, sd in zip(envs, seeds)]
    rng = np.random.default_rng(11)
    O, Y = [], []
    cur = [int(rng.integers(T.NA)) for _ in range(nenv)]
    left = [0]*nenv
    t0 = time.perf_counter()
    per = frames // nenv
    for j in range(nenv):
        last_o = T.build_obs(envs[j], s[j], sts[j], ego=1)
        for t in range(per):
            # 会话47C 实测：bot 开火密度强烈依赖目标风格——对"每 tick 均匀
            # 随机"的目标 60~100 弹/6000tick，对"平滑换挡(4~12tick)"的目标
            # 仅 5 弹/20000tick（几乎见不到人就不开枪）。克隆要学到"会开枪"
            # 的策略，数据生成器就用逐 tick 随机风格（也正是用户报的
            # "转圈时 bot 变呆"的行为学证据）。
            cur[j] = int(rng.integers(T.NA))
            s[j] = envs[j].step((0,)*6, rep=1, act1=tuple(T.A6[cur[j]].tolist()))
            # 会话47C 对齐定论（出生 tick 实测）：BotThink 在 tick t 的
            # GameUpdate 内基于 state(t-1) 写 inputTable 并同 tick 执行；
            # 快照电平是保留通道（火/技也不清零——此前"开火率0.0"是
            # 0.0025 round 的舍入假象+低触发，非协议问题）。
            # ⇒ 标签对 (obs, lv) 必须"上一 tick 快照观测 ↔ 本 tick 快照电平"。
            e = envs[j]
            lv = s[j]["levels"][0:6]
            O.append(last_o); Y.append(levels_to_act(lv, lv[4] > 0, lv[5] > 0))
            last_o = T.build_obs(e, s[j], sts[j], ego=1)
            if s[j]["matchOver"]:
                seeds[j] += 1_000_003
                sts[j] = dict(esin=0.0, ecos=0.0)
                s[j] = envs[j].reset(seeds[j], swap=True)
                last_o = T.build_obs(e, s[j], sts[j], ego=1)
        envs[j].close()
    got = len(O)
    print(f"采集 {got} 帧 用时 {time.perf_counter()-t0:.0f}s "
          f"({got/(time.perf_counter()-t0):,.0f} f/s)")
    return np.stack(O), np.array(Y, dtype=np.int64)


def fit(O, Y, epochs=12, mb=1024, lr=1e-3, ent=0.0):
    p = T.init_nn()
    ad = T.Adam(p, lr)
    n = len(Y)
    idx = np.arange(n)
    cut = int(n*0.95)
    rng = np.random.default_rng(5)
    tr, va = idx[:cut], idx[cut:]
    for ep in range(epochs):
        rng.shuffle(idx)
        tot = 0.0
        for i0 in range(0, cut, mb):
            b = idx[i0:i0+mb]
            _, _, pi, _ = T.forward(p, O[b])
            ps = T.softmax(pi)
            lab = np.zeros_like(ps); lab[np.arange(len(b)), Y[b]] = 1.0
            dlogits = (ps - lab) / len(b)
            # 全网络 CE 梯度（与 rl_train.grads 同构，去掉 value/熵 项）
            h1, h2, _, _ = T.forward(p, O[b])
            g2 = dlogits @ p["pw"].T
            g2 *= (1.0 - h2*h2)
            pw_g = h2.T @ dlogits; pb_g = dlogits.sum(0)
            g2w = h1.T @ g2; g2b = g2.sum(0)
            g0 = g2 @ p["l2w"].T
            g0 *= (1.0 - h1*h1)
            g = {"l1w": O[b].T @ g0, "l1b": g0.sum(0), "l2w": g2w, "l2b": g2b,
                 "pw": pw_g, "pb": pb_g, "vw": np.zeros_like(p["vw"]),
                 "vb": np.zeros_like(p["vb"])}
            ad.step(g)
            tot += -(np.log(np.clip(ps[np.arange(len(b)), Y[b]], 1e-9, 1)).mean())
        _, _, pia, _ = T.forward(p, O[va])
        acc = (pia.argmax(1) == Y[va]).mean()
        print(f"epoch{ep} loss={tot/max(cut//mb,1):.4f} val_acc={acc*100:.1f}%",
              flush=True)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=120000)
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--eval", action="store_true")
    ap.add_argument("--width", type=int, default=128,
                    help="run19 预铺对齐：隐层宽度写入 T.H（fit→init_nn 消费）")
    ap.add_argument("--exe", default="", help="指定 rlhost 可执行文件（影子构建期用）")
    a = ap.parse_args()
    T.H = a.width
    if a.exe:
        rl_env.EXE = os.path.abspath(a.exe)
    O, Y = collect(a.envs, a.frames)
    hist = np.bincount(Y, minlength=T.NA)
    print("标签分布 top8:", sorted(range(T.NA), key=lambda k: -hist[k])[:8],
          " 开火率≈%.2f%% 技能率≈%.2f%%" % (100*float((Y % 4 >= 2).mean()),
                                            100*float((Y % 2 == 1).mean())))
    p = fit(O, Y, epochs=a.epochs)
    if os.path.exists(T.CKPT):
        bak = T.CKPT + ".pre_bc.bak"
        if os.path.exists(bak):
            os.remove(bak)
        os.replace(T.CKPT, bak)
    np.savez(T.CKPT, **p)
    print(f"BC 权重已写入 {T.CKPT}（原文件备份 .pre_bc.bak）")
    if a.eval:
        T.eval_greedy(4, 40)


if __name__ == "__main__":
    main()
