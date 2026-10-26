# -*- coding: utf-8 -*-
# ============================================================
# rl_obs_dist.py —— 会话47 Phase3 观测内容对拍（B 层之上再验 obs 本身）：
# 蒸馏校验 A/B/C 只核对了"前向/信标/argmax 与落盘 obs 自洽"，obs 内容
# 从未与训练环境对过——本脚本补上：
#   exe 侧：rlbot_trace.bin 每条记录的 90 列
#   env 侧：Vec(heuristic 陪练) 用冠军权重贪心跑，采集同网络所见 obs
# 逐列比 min/max/mean：exe 值落在 env 分布外（超出容差）即端口偏差。
# 用法：python -I tools/rl_obs_dist.py [steps]
# ============================================================
import os, sys, struct
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rl_train as T

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACE = os.path.join(ROOT, "rlbot_trace.bin")
NPZ = os.path.join(ROOT, "rl_policy_14champ.bak.npz")
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 3000

T.OBS_V2 = False
p = dict(np.load(NPZ))
assert "obsv2" not in p

# ---- exe 侧 ----
REC = 16 + 90 * 4 + 36 * 4 * 2
data = open(TRACE, "rb").read()
n = len(data) // REC
X = np.stack([np.frombuffer(data, "float32", 90, i * REC + 16)
              for i in range(n)]).astype(np.float32)

# ---- env 侧（结果缓存到 TEMP，重跑免启 rlhost）----
CACHE = os.path.join(os.environ.get("TEMP", "/tmp"), "rl_obs_dist_env.npy")
if os.path.exists(CACHE):
    Y = np.load(CACHE)
else:
    vec = T.Vec(4, 999_001, opp="heuristic")
    Y = []
    try:
        cnt = 0
        while cnt < STEPS:
            for j in range(4):
                o = vec.obs(j)
                Y.append(o)
                _, _, pi, _ = T.forward(p, np.asarray(o)[None])
                act = int(pi[0].argmax())
                prev, s = vec.step(j, act)
                vec.note(j, prev, s)
                if bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]):
                    vec.reseed(j)
                cnt += 1
                if cnt >= STEPS:
                    break
    finally:
        for e in vec.envs:
            e.close()
    Y = np.array(Y, dtype=np.float32)
    np.save(CACHE, Y)
print("exe recs=%d  env recs=%d" % (n, len(Y)))

# ---- 逐列对比 ----
# env 分位数作"合法域"：[p0.2, p99.8]，exe 越界比例 >2% 或均值差异常即点名
lo = np.percentile(Y, 0.2, axis=0)
hi = np.percentile(Y, 99.8, axis=0)
mY, sY = Y.mean(0), Y.std(0)
mX, sX = X.mean(0), X.std(0)
frac = ((X < lo - 1e-4) | (X > hi + 1e-4)).mean(0)
z = np.abs(mX - mY) / (sY + 1e-6)
print("%3s %8s %8s | %8s %8s | %8s %8s | %6s %6s  flag" %
      ("col", "env_lo", "env_hi", "exe_min", "exe_max", "env_mean", "exe_mean",
       "越界%", "|Δm|σ"))
bad = []
for c in range(90):
    f = 100.0 * frac[c]
    flag = ""
    if f > 2.0:
        flag = "OOB"
    elif z[c] > 2.0 and abs(mX[c] - mY[c]) > 0.05:
        flag = "MEAN"
    if flag:
        bad.append(c)
        print("%3d %8.3f %8.3f | %8.3f %8.3f | %8.3f %8.3f | %6.1f %6.2f  %s" %
              (c, lo[c], hi[c], X[:, c].min(), X[:, c].max(), mY[c], mX[c], f, z[c], flag))
print("异常列 %d/90: %s" % (len(bad), bad))
