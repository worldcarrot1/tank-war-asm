# -*- coding: utf-8 -*-
# ============================================================
# rl_obs_pipe_check.py —— 会话47 Phase3 决定性对拍：
# "rlhost rlbot rlbotdump" 管道里，NN（asm 构建 obs）与启发式对手跑
# 真实对局；python 同 tick 用 build_obs 从响应快照复算观测。逐列比：
#   X = exe 落盘 obs（RlBuildObs 产物）
#   Y = python build_obs(env, prev_s)（训练侧同一函数）
# 两者源自同一 tick 的同一状态——任何系统性差异即端口 bug，直接点名列。
# 另比 exe chosen vs python argmax（同一 Y 上的贪心），量化行为差。
# 用法：python -I tools/rl_obs_pipe_check.py [steps]
# ============================================================
import os, sys, struct, shutil
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ["RLHOST_EXTRA"] = "rlbot rlbotdump"
TRACE = os.path.join(ROOT, "rlbot_trace.bin")
OLD = os.path.join(ROOT, "rlbot_trace_gui2.bin")
if os.path.exists(TRACE):
    shutil.move(TRACE, OLD)              # 移开 GUI run2 档，防读混

import rl_train as T

T.OBS_V2 = False
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
p = dict(np.load(os.path.join(ROOT, "rl_policy_14champ.bak.npz")))

vec = T.Vec(1, 999_003, opp="heuristic")
Y, A, AL = [], [], []
try:
    cnt = 0
    while cnt < STEPS:
        o = vec.obs(0)
        _, _, pi, _ = T.forward(p, np.asarray(o)[None])
        act = int(pi[0].argmax())
        prev, s = vec.step(0, act)
        vec.note(0, prev, s)
        AL.append(float(o[4]) > 0.5)          # exe 仅 alive=1 tick 落盘
        Y.append(o)
        A.append(act)
        if bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]):
            vec.reseed(0)
        cnt += 1
finally:
    for e in vec.envs:
        e.close()
AL = np.array(AL)
Y = np.array(Y, dtype=np.float32)[AL]
A = np.array(A, dtype=np.int64)[AL]

REC = 16 + 90 * 4 + 36 * 4 * 2
data = open(TRACE, "rb").read()
n = len(data) // REC
X = np.stack([np.frombuffer(data, "float32", 90, i * REC + 16) for i in range(n)])
hdr = np.array([struct.unpack_from("<4i", data, i * REC) for i in range(n)])
chosen = hdr[:, 2]
print("python recs=%d  exe recs=%d" % (len(Y), n))
if n == 0:
    sys.exit("exe 未落盘：RLHOST_EXTRA 未生效？")

# ---- 对齐 offset：tick 相位未知，试 0/1/-1 取越界列数最小 ----
m = min(len(Y), n)


def score(off):
    if off >= 0:
        Xs, Ys = X[off:off + m], Y[:m - off]
    else:
        Xs, Ys = X[:m + off], Y[-off:-off + m]
    d = np.abs(Xs - Ys)
    return (d > 2e-3).mean(), Xs, Ys, d


best = min((score(off), off) for off in (0, 1, -1))
(frac, Xs, Ys, d), off = best
print("对齐 offset=%d  失配元素比=%.4f%%  max|Δ|=%.4g" % (off, 100 * frac, d.max()))
colbad = (d > 2e-3).mean(0)
meand = d.mean(0)
order = np.argsort(-meand)[:15]
print("%3s %10s %10s %10s  exe_mean py_mean" % ("col", "mean|Δ|", "max|Δ|", "失配%"))
for c in order:
    if meand[c] > 1e-4:
        print("%3d %10.5f %10.5f %9.1f%%  %8.3f %8.3f" %
              (c, meand[c], d[:, c].max(), 100 * colbad[c],
               Xs[:, c].mean(), Ys[:, c].mean()))
# ---- 行为对比：exe chosen vs python argmax(同 tick Y) ----
L = len(Ys)
if off >= 0:
    cs, As_ = chosen[off:off + L], A[:L]
else:
    cs, As_ = chosen[:L], A[-off:-off + L]
print("act(exe chosen)==argmax(py obs): %.2f%%" % (100 * np.mean(cs == As_)))
hist_x = np.bincount(chosen, minlength=36)
hist_y = np.bincount(A, minlength=36)
hx = hist_x.reshape(3, 12).sum(1)
fx = hist_x.reshape(9, 2, 2)
print("exe动作分布: 前进/倒车/停=%d/%d/%d 开火=%d 技能=%d" %
      (hx[0], hx[1], hx[2], fx[:, 1, :].sum(), fx[:, :, 1].sum()))
hy = hist_y.reshape(3, 12).sum(1)
fy = hist_y.reshape(9, 2, 2)
print("py 动作分布: 前进/倒车/停=%d/%d/%d 开火=%d 技能=%d" %
      (hy[0], hy[1], hy[2], fy[:, 1, :].sum(), fy[:, :, 1].sum()))
