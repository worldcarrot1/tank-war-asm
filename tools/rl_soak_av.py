# -*- coding: utf-8 -*-
# ============================================================
# rl_soak_av.py —— 会话48 夜间：rlhost 管道低概率 AV 搜捕。
# 背景：纯权重贪心 vs 启发式跑 12 局时，同一逻辑三次在 vec.step 处
# 收管道 EOF（exe 死），手写重放却两次全绿——疑为 exe 侧低概率崩溃
# （启动期非确定性或边界态）。本 soak 长循环：贪心选动作持续 step，
# 每 tick poll() 检尸；崩溃则打印 seed 谱系/局内 ep/总 tick/返回码，
# 然后换新 seed 续跑，直到跑满 --ticks 或崩满 --stops 次。
# 用法：python -I tools/rl_soak_av.py [--ticks 20000] [--opp heuristic]
#                                        [--stops 3]
# ============================================================
import sys, os, time
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import rl_train as T

args = sys.argv[1:]
def get(name, default):
    return args[args.index(name) + 1] if name in args else default
TICKS = int(get("--ticks", 20000))
OPP = get("--opp", "heuristic")
STOPS = int(get("--stops", 3))

T.OBS_V2 = False
p = dict(np.load(os.path.join(ROOT, "rl_policy_14champ.bak.npz")))
seed0 = 4_000_001
done = 0
crashes = 0
v = T.Vec(1, seed0, opp=OPP)
ep = rnd = 0
t_last = time.time()
try:
    while done < TICKS and crashes < STOPS:
        o = v.obs(0)
        _, _, pi, _ = T.forward(p, np.asarray(o)[None])
        act = int(pi[0].argmax())
        try:
            prev, s = v.step(0, act)
        except RuntimeError as ex:
            rc = v.envs[0].p.poll()
            print("CRASH#%d seed=%d 局内ep=%d 全局rnd=%d done=%d rc=0x%08X %r" %
                  (crashes + 1, v.seeds[0], ep, rnd, done,
                   rc & 0xFFFFFFFF if rc is not None else 0, ex), flush=True)
            crashes += 1
            ep = 0
            v.close()
            seed0 += 1
            v = T.Vec(1, seed0, opp=OPP)
            continue
        v.note(0, prev, s)
        ep += 1
        done += 1
        if bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"]):
            rnd += 1
            v.reseed(0)
            ep = 0
        if done % 1000 == 0:
            el = time.time() - t_last
            print("tick %d/%d round %d 崩%d (%.0f t/s)" % (done, TICKS, rnd, crashes, 1000.0 / el), flush=True)
finally:
    try:
        v.close()
    except Exception:
        pass
print("soak done: ticks=%d rounds=%d crashes=%d" % (done, rnd, crashes))
