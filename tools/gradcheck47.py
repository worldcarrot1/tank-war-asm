# -*- coding: utf-8 -*-
# 会话47：grads() 数值-解析梯度自检（临时工具）
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train as T

p = T.init_nn()
RNG = np.random.default_rng(1)
B = 8
o = RNG.standard_normal((B, T.OBS)).astype(np.float32) * 0.3
a = RNG.integers(0, T.NA, B)
adv = RNG.standard_normal(B).astype(np.float32)
ret = RNG.standard_normal(B).astype(np.float32)
mask = np.ones(B, dtype=np.float32)
g = T.grads(p, o, a, adv, ret, mask, 0.0)


def loss(pp):
    _, _, pi, val = T.forward(pp, o)
    ps = T.softmax(pi)
    lp = np.log(np.clip(ps[np.arange(B), a], 1e-9, 1))
    return (-lp * adv).mean() + ((val - ret) ** 2).sum() / B


eps = 1e-3
bad = 0
for k in ("l1w", "l2w", "pw", "vw", "l1b", "pb", "vb"):
    ref = np.zeros_like(p[k])
    vis = np.zeros_like(p[k], dtype=bool)
    it = np.nditer(p[k], flags=["multi_index"])
    cnt = 0
    while not it.finished and cnt < 25:
        ix = it.multi_index
        old = p[k][ix]
        p[k][ix] = old + eps
        l1 = loss(p)
        p[k][ix] = old - eps
        l2 = loss(p)
        p[k][ix] = old
        ref[ix] = (l1 - l2) / (2 * eps)
        vis[ix] = True
        cnt += 1
        it.iternext()
    rel = np.abs(ref[vis] - g[k][vis]).max() / (np.abs(ref[vis]).max() + 1e-9)
    print(k, "relmax", round(float(rel), 4))
    bad += rel > 0.05
print("GRADIENT", "FAIL" if bad else "OK")
