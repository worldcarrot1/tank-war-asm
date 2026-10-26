# -*- coding: utf-8 -*-
# ============================================================
# rl_rec_extract.py —— 会话47：.rlrec 原始流 → 训练数据集 npz
# 输出与 rl_train.build_obs 同构：obs[N,90]（slot0 视角）+
# act6[N,6]（slot0 人类/策略电平）+ opp_act6[N,6]（slot1，人机局
# 即启发式 bot 的真实决策，可做模仿基线对照）+ 分段元数据。
# 用途：行为克隆预训练、风格评估、转圈/走位场景回放分析。
# 用法：python tools/rl_rec_extract.py live_xxx.rlrec [-o out.npz]
# ============================================================
import os, sys, struct, argparse
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rl_env import TankEnv
from rl_train import build_obs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out", default=None)
    a = ap.parse_args()
    out = a.out or os.path.splitext(a.src)[0] + ".npz"

    probe = TankEnv()
    probe.close()
    env = probe                       # 只借用其 META 表与 tv()，进程已关
    total = probe.snap_total
    in_len = total + probe.MAX_PLAYERS * probe.KEY_PER * 4
    KP = probe.KEY_PER

    raw = open(a.src, "rb").read()
    n = len(raw) // in_len
    print(f"帧数 {n}（余 {len(raw) % in_len}B 丢弃）")
    OBSN = 90
    obs = np.zeros((n, OBSN), dtype=np.float32)
    act = np.zeros((n, 6), dtype=np.int32)
    oact = np.zeros((n, 6), dtype=np.int32)
    ticks = np.zeros(n, dtype=np.int64)
    rounds = np.zeros(n, dtype=np.int32)
    seg = np.ones(n, dtype=np.int32)   # episode 分段（gTick 回退=新 reset）
    st = dict(esin=0.0, ecos=0.0)
    for i in range(n):
        d = raw[i * in_len:(i + 1) * in_len]
        hdr = struct.unpack_from("<14I", d)
        tanks = [struct.unpack_from("<%dI" % (env.tank_sz // 4), d,
                 env.off_tanks + k * env.tank_sz) for k in range(4)]
        acts = struct.unpack_from("<%dI" % (env.MAX_PLAYERS * KP), d, total)
        bullets = [struct.unpack_from("<%dI" % (env.bul_sz // 4), d,
                   env.off_bullets + bi * env.bul_sz)
                   for bi in range(env.MAX_BULLETS)]
        grid = d[env.off_map:env.off_map + env.COLS * env.ROWS]
        s = dict(zip(("tick", "rngMatch", "mapIndex", "matchOver",
                      "roundsPlayed", "maxRounds", "pickupType", "pickupX",
                      "pickupY", "pickupTimer", "botMask", "rngState"),
                     hdr[1:13]))
        s["hdr"] = hdr
        s["tanks"] = tanks
        s["bullets"] = bullets
        s["map"] = grid
        if i and s["roundsPlayed"] < rounds[i - 1]:   # 回合计数回落=新开一局
            seg[i:] = seg[i - 1] + 1
            st = dict(esin=0.0, ecos=0.0)
        obs[i] = build_obs(env, s, st)
        act[i] = acts[0 * KP:1 * KP]
        oact[i] = acts[1 * KP:2 * KP]
        ticks[i] = hdr[1]
        rounds[i] = s["roundsPlayed"]
    nseg = int(seg.max())
    np.savez_compressed(out, obs=obs, act=act, opp_act=oact, ticks=ticks,
                        rounds=rounds, seg=seg)
    print(f"写 {out}: obs{obs.shape} 段数={nseg} "
          f"act 分布 slot0 fire均值={act[:,4].mean():.3f} "
          f"slot1 fire均值={oact[:,4].mean():.3f}")


if __name__ == "__main__":
    main()
