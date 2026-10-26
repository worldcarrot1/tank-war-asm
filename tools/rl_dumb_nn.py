# -*- coding: utf-8 -*-
# ============================================================
# rl_dumb_nn.py —— 会话48 夜间队列②：NN 呆行为体检（反转圈专项）。
# 口径搬 bot_dumb46.py（那是启发式 bot 的 CSV 侧），这里在管道侧用
# python 贪心选动作（与 exe NN 已对拍：act 一致 94.67%、obs 失配
# 0.0037%，故 python 侧度量即 exe 行为的等价代理）。度量五项：
#   摇头   —— 相邻 tick 转向从 ccw 直跳 cw（或反向）的次数
#   罚站   —— m停&t停&不发不技 连续>=8 tick 的整段（最长/段数）
#   全倒车 —— m=倒车 占比与最长连续段（冠军风格验证：应很高且段长）
#   挂墙   —— 给移动指令但 px 位置连续>=12 tick 纹丝不动的段数
#   白转   —— 60-tick 滑窗内位移<6px 但移动/转向指令密集（原地磨洋工）
# 用法：python -I tools/rl_dumb_nn.py [steps] [opp]   opp=script|heuristic
# ============================================================
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import rl_train as T

T.OBS_V2 = False
STEPS = int(sys.argv[1]) if len(sys.argv) > 1 else 2400
OPP = sys.argv[2] if len(sys.argv) > 2 else "script"
p = dict(np.load(os.path.join(ROOT, "rl_policy_14champ.bak.npz")))

vec = T.Vec(1, 2026_1024, opp=OPP)
M, T_, F, S, AL, PX, PY = [], [], [], [], [], [], []
try:
    cnt, rounds = 0, 0
    while cnt < STEPS:
        o = vec.obs(0)
        _, _, pi, _ = T.forward(p, np.asarray(o)[None])
        act = int(pi[0].argmax())
        AL.append(float(o[4]) > 0.5)
        M.append(act // 12)
        T_.append((act // 4) % 3)
        F.append((act // 2) % 2)
        S.append(act % 2)
        prev, s = vec.step(0, act)
        vec.note(0, prev, s)
        PX.append(vec.envs[0].tv(s, 0, "x"))
        PY.append(vec.envs[0].tv(s, 0, "y"))
        if bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]):
            vec.reseed(0)
            rounds += 1
        cnt += 1
finally:
    for e in vec.envs:
        e.close()

AL = np.array(AL, dtype=bool)
M, T_, F, S = (np.array(v)[AL] for v in (M, T_, F, S))
PX, PY = np.array(PX)[AL], np.array(PY)[AL]
n = len(M) or 1
print("opp=%s 存活tick=%d 回合=%d" % (OPP, len(M), rounds))

# 1) 摇头：ccw(0)↔cw(1) 直跳
alt = int(np.sum((T_[:-1] + T_[1:] == 1) & (T_[:-1] < 2)))
# 2) 罚站段
still = (M == 2) & (T_ == 2) & (F == 0) & (S == 0)
runs, longest, cur = 0, 0, 0
for v in still:
    if v:
        cur += 1
    else:
        if cur >= 8:
            runs += 1
            longest = max(longest, cur)
        cur = 0
if cur >= 8:
    runs += 1
    longest = max(longest, cur)
# 3) 倒车段
rev = M == 1
rl_cur, rl_long = 0, 0
for v in rev:
    rl_cur = rl_cur + 1 if v else 0
    rl_long = max(rl_long, rl_cur)
# 4) 挂墙段：移动指令(m!=2 或 t!=2) 但位置不动>=12
moved = np.concatenate(([0], np.abs(np.diff(PX)) + np.abs(np.diff(PY)) > 0))
stuckmask = (M != 2) & (moved == 0)
sr, sl, cur = 0, 0, 0
for v in stuckmask:
    if v:
        cur += 1
    else:
        if cur >= 12:
            sr += 1
            sl = max(sl, cur)
        cur = 0
if cur >= 12:
    sr += 1
    sl = max(sl, cur)
# 5) 白转窗：60-tick 窗位移<6px
W = 60
dis = np.abs(PX - np.roll(PX, W)) + np.abs(PY - np.roll(PY, W))
dis[:W] = 9999      # 头部 roll 回绕不可信（尾部被下面切片天然排除）
lazy = int(np.sum(dis[:len(dis) - W + 1] < 6)) if len(M) > W else 0
act_rate = float(np.mean((M != 2) | (T_ != 2)))
print("摇头 %d(%.1f/100t) | 罚站段 %d 最长 %d | 倒车 %.1f%% 最长段 %d |"
      " 挂墙段 %d 最长 %d | 白转窗 %d/%d" %
      (alt, 100.0 * alt / n, runs, longest,
       100.0 * float(np.mean(rev)) if len(rev) else 0.0, rl_long,
       sr, sl, lazy, max(len(M) - W + 1, 0)))
print("指令率(m或t非停)=%.1f%% 开火=%.1f%% 技能=%.1f%%" %
      (100 * act_rate, 100 * float(np.mean(F)), 100 * float(np.mean(S))))
