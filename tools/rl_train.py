# -*- coding: utf-8 -*-
# ============================================================
# rl_train.py —— 会话47 Phase2：纯 numpy PPO（无 torch 依赖）
# 布局：N 个 rlhost 环境进程并行采样；slot0=PPO 策略，
#       slot1=游戏内置启发式 bot（botMask=2，天然陪练/评估对手）。
# 观测不直接暴露敌方瞬时朝向，而是 sin/cos + 16tick EMA 质心航向
# ——对症"玩家原地转圈绕晕 bot"：转圈在特征空间退化为"站在原地"，
# 瞬时假姿态被平滑滤掉，策略只能从位移/瞄准里读真实意图。
# 用法：python tools/rl_train.py [--iters 150] [--envs 4] [--eval-only]
# 产物：rl_policy.npz（float 权重；Phase3 再定点化进 inc/nn.inc）
# ============================================================
import os, sys, time, math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rl_env import TankEnv

RNG = np.random.default_rng(20261023)
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CKPT = os.path.join(ROOT, "rl_policy.npz")
BEST = os.path.join(ROOT, "rl_policy_best.npz")
# 会话47E-run11：技能漏斗第二存档点——run9/10 实测 comp 单档会系统性把
# 技能档挤掉（p10 距道具随开火权重上升反而恶化 165→219→396px，交战卡距
# 与趋近道具互斥）。技能产出(拾取+发动)/千t 的历史最高档单独存此文件，
# 事后可与主档双对照正评，不让唯一开张的漏斗窗口在选拔中蒸发。
SKB = os.path.join(ROOT, "rl_policy_skbest.npz")
# 会话47E-run14：快评选拔三连败（148→正评12/5、127→25/13、run12 前 129→
# 未存即崩）——mix 3env×36 快评与 60 回合单池正评转移性太差。终局协议：
# 快评 comp 前 3 名候选各存一槽，训练收官对每槽做双池 60 回合正评，
# (script+heuristic) 胜率和最高者钦定冠军覆写 BEST——选拔终点对齐验收口径。
CANDS = [os.path.join(ROOT, f"rl_policy_cand{i}.npz") for i in (1, 2, 3)]
LOGP = os.path.join(ROOT, "rl_train.log")

OBS = 90
# run15：道具观测编码 v2（--obsv2 开启；默认关=历史 90 列语义不变，
# 旧 npz 仍可被探针/正评正确解读。开 v2 训出的权重与旧档不可互评）
OBS_V2 = False
# run23 预铺（会话51 B 案）：OBS_V3=尾追加 12 维=6 弹槽×(latN, τN)。
# 前 90 维偏移一格不动（探针/旧布局工具全兼容）；asm 镜像在 rlbot.asm
# 的 IF RL_OBSCPA 分支（cfg 默认 0=位级不变）。新旧权重不可互评，
# 随 npz 带 obsv3 标记自动对齐。
OBS_V3 = False
def apply_obsv3(v):
    global OBS_V3, OBS
    OBS_V3 = bool(v)
    OBS = 102 if OBS_V3 else 90
NA = 36
MOVES = [(1, 0), (0, 1), (0, 0)]      # fwd, back, idle
URNS = [(1, 0), (0, 1), (0, 0)]       # ccw, cw, idle
A6 = np.zeros((NA, 6), dtype=np.int32)
k = 0
for m in range(3):
    for t in range(3):
        for f in range(2):
            for s in range(2):
                A6[k, 0], A6[k, 1] = MOVES[m]
                A6[k, 2], A6[k, 3] = URNS[t]
                A6[k, 4], A6[k, 5] = f, s
                k += 1
assert k == NA

# ---------------- 会话47D：显式能力奖励 ----------------
# 用户要求：不只"开火+追踪"，技能使用与躲避子弹也要练出来。
# 躲弹=势函数塑形 F=γΦ'−Φ（Φ=−K·威胁和）：脱离弹道逐 tick 得正反馈，
# 不再只靠 −5 死亡惩罚这一根稀疏信号；自弹只按 SELF_W 计（防自伤
# 但不压开火——自弹出膛即背离弹轴，天然少进威胁集）。
DODGE_D0 = 180.0      # 威胁视距(px)
# 会话51 run22（躲弹专项）：0.6→1.2 抬档——run18~21 四连实证"交战=换弹"
# 均衡（能开火的候选交战躲仅 45%），根因=受击不即亏(3HP 可换)而躲的收益
# ±0.1/tick 是零头。塑形翻倍并同步抬限幅 0.10→0.15（run6 教训：塑形上量
# 会压锁瞄，AIM_RATE 0.05→0.08 对冲）；全部 env 可回滚做单变量对照。
DODGE_K  = float(os.environ.get("RL_DODGEK", "1.2"))    # 塑形系数（run22 前 0.6）
DODGE_CLIP = float(os.environ.get("RL_DODGECLIP", "0.15"))  # 单 tick 限幅
SELF_W   = 0.35       # 己方弹威胁权重
SK_WIN   = 40         # 技能→伤害归因窗口(tick)
SK_BONUS = 2.0        # 窗口内敌方掉血奖励（技能命中）
SK_GRAB  = 5.0        # 拾取技能（skill 0→非0）。run8 重构依据（item_probe47e）：
                      # run7 最优权重距道具 p10=165px、进圈率 0.0%——技能键按下率
                      # 33%（有发动意图）却从不走近拿，病因=激励量级而非机制，
                      # 1.2 档彻底压不住，直接抬到击杀量级
SK_ACT   = 1.5        # 发动成功（引擎消费沿）
SK_NONE  = -10**9
# 会话47D③：诊断实测 71% 权重"车尾对敌 median 偏差142°、中位距离477px"
# = 只会放风筝不会开枪。补两路稠密信号：锁瞄（角带内每 tick 微奖）与
# 精度弹（出膛 2 tick 时离敌中心 <50px 记一次准星奖）。
AIM_T    = 12.0       # 锁瞄角带(°)
AIM_D    = 430.0      # 锁瞄索敌距(px)
AIM_RATE = float(os.environ.get("RL_AIMRATE", "0.08"))  # 角带内 /tick。run6 实测 0.03 压不住躲弹塑形(clip 0.1/tick)，瞄占比仍 1~3%；run22 塑形加倍后 0.05→0.08 对冲
HIT_M = float(os.environ.get("RL_HITM", "1.0"))  # 会话51 run22：ego 每掉 1HP 即时罚（与致死 −5 叠加）
ACC_SHOT = float(os.environ.get("RL_ACCSHOT", "0.80"))
# 准星弹：自弹首次进入敌擦身带(角点距<ACC_R)一弹一次
# run19 抬交战：原 0.50——与 HIT_P 同组稠密信号，只加"打准/打中"，
# 不碰 win(+8)/致死(+3.5) 大梁（run13 "杀穿但输回合"套利护栏）。
ACC_R    = 20.0       # 擦身带半径(px,角点制)。旧 age==2 版弹只离膛 5px，
                      # 等于只在 50px 内战才发——477px 交战距下恒 0，run7 废
# 会话47D⑤（run3 加强）：能力卡实测"躲弹63%学会、瞄3%/技0发没学会"——
# 放风筝主导。补反逃逸惩罚（中距以上贴脸压力）与技能道具趋近塑形
# （skill 只能靠拾取获得，不吃道具=技能链永闭）。
RUNAWAY_P  = 0.0      # 双方存活且距离 >RUNAWAY_D 每 tick 惩罚
# 会话47D run3/run4 两次实证：此惩罚令策略"蛮干"（run3-peak 正评仅 13%、
# 中弹 1.82/千t；run4 沿用后快评从 33% 衰减到 0~4%、阵亡比恶化到 24:16），
# 反放风筝改由 AIM_RATE 锁瞄正奖励单边引导，罚项关闭。
RUNAWAY_D  = 520.0    # 过远判定(px)
# 会话47E：击杀/命中必须归因到自己（详见 reward() 内注释）。
HIT_P = float(os.environ.get("RL_HITP", "1.1"))   # 自弹命中未致死(dense credit)
# run19 抬交战：原 0.8；env RL_HITP/RL_ACCSHOT 可回滚做单变量对照。
KILL_R     = 34.0     # 归因半径：自弹与受害方角点差(<33=TANK25+弹8,game.inc:124)
PICK_RATE  = 0.08     # 道具距离趋近塑形限幅（run8 0.03→0.08；旧值下 2.2px/tick
                      # 位移只兑现 0.003/tick，约为躲弹塑形的 1/30，形同虚设）
SK_ZONE    = 80.0     # 道具"进圈"判定半径(px,角点制)
SK_ZONES   = 2.0      # 每次侵入道具圈一次性奖（run8 0.4→2.0，与 SK_GRAB 同批
                      # 重构；依据 item_probe47e：run7 最优进圈率 0.0%/p10=165px）


# ---------------- 观测 ----------------
def build_obs(env, s, st, ego=0):
    """ego 视角观测（会话47C：ego=1 即换位——BC 采集时策略槽在 slot1，
    启发式 bot 在 slot0，标签=inputTable[0..5]）。"""
    opp = 1 - ego
    W = float(env.MAP_W)
    H = float(env.ROWS * env.CELL)
    tv = env.tv
    out = np.zeros(OBS, dtype=np.float32)
    i = 0
    x, y = tv(s, ego, "x"), tv(s, ego, "y")
    d = math.radians(tv(s, ego, "dir") % 360)
    alive0 = 1.0 if tv(s, ego, "alive") else 0.0
    out[i:i+11] = (x/W, y/H, math.sin(d), math.cos(d), alive0,
                   min(tv(s, ego, "fireCd")/30.0, 1.0),
                   min(tv(s, ego, "skill")/8.0, 1.0),
                   1.0 if tv(s, ego, "effOn") else 0.0,
                   1.0 if tv(s, ego, "shieldT") else 0.0,
                   1.0 if tv(s, ego, "protT") else 0.0,
                   tv(s, ego, "lives")/3.0)
    i += 11
    ea = 1.0 if tv(s, opp, "alive") else 0.0
    ex, ey = tv(s, opp, "x"), tv(s, opp, "y")
    de = math.radians(tv(s, opp, "dir") % 360)
    se, ce = math.sin(de), math.cos(de)
    a = 1.0/16.0
    st["esin"] = (1-a)*st["esin"] + a*se*ea
    st["ecos"] = (1-a)*st["ecos"] + a*ce*ea
    out[i:i+10] = (ea, (ex-x)/W, (ey-y)/H, se, ce,
                   st["esin"], st["ecos"],
                   1.0 if tv(s, opp, "aimT") else 0.0,
                   min(tv(s, opp, "skill")/8.0, 1.0),
                   1.0 if tv(s, opp, "effOn") else 0.0)
    i += 10
    bl = []
    bfp = getattr(env, "BULLET_FP", 0) or 176947     # 会话47B：弹速是 16.16
    for b in s["bullets"][:env.MAX_BULLETS]:         # 定点，按模长归一到 ±1
        if b[env.bul_dw["active"]]:
            bx, by = b[env.bul_dw["x"]], b[env.bul_dw["y"]]
            vx, vy = b[env.bul_dw["vx"]], b[env.bul_dw["vy"]]
            vxs = vx - 0x100000000 if vx >= 0x80000000 else vx
            vys = vy - 0x100000000 if vy >= 0x80000000 else vy
            dx, dy = bx - x, by - y
            bl.append((dx*dx + dy*dy, dx/W, dy/H, vxs/bfp, vys/bfp,
                       1.0 if dx*vxs + dy*vys < 0 else 0.0,
                       dx, dy, vxs, vys))       # 尾4=原始整数(V3 用)
    bl.sort()
    for j in range(6):
        if j < len(bl):
            out[i:i+6] = (bl[j][1], bl[j][2], bl[j][3], bl[j][4], bl[j][5], 1.0)
        i += 6
    cx, cy = int(x // env.CELL), int(y // env.CELL)
    for gy in range(cy-2, cy+3):
        for gx in range(cx-2, cx+3):
            v = 1.0
            if 0 <= gx < env.COLS and 0 <= gy < env.ROWS:
                v = s["map"][gy*env.COLS + gx] / 6.0
            out[i] = v
            i += 1
    pk = s["pickupType"]
    if pk:
        if OBS_V2:
            # run15 道具方位显著化：旧编码 (在场, dx/W, dy/H, type) 要求 MLP
            # 从坐标自学科出"方向"；v2 把方位角直接摊开成 cos/sin + 近因衰减
            # 在场列——趋近方向变成线性可读特征，与躲弹威胁列正面抢注意力。
            ddx = s["pickupX"] - x
            ddy = s["pickupY"] - y
            rr = math.hypot(ddx, ddy) or 1.0
            out[i:i+4] = (max(0.0, 1.0 - rr / 700.0), ddx / rr, ddy / rr, pk / 8.0)
        else:
            out[i:i+4] = (1.0, (s["pickupX"]-x)/W, (s["pickupY"]-y)/H, pk/8.0)
    i += 4
    out[i:i+4] = (tv(s, ego, "score")/3.0, tv(s, opp, "score")/3.0,
                  s["roundsPlayed"]/max(s["maxRounds"], 1),
                  1.0 if s["matchOver"] else 0.0)
    assert i + 4 == 90, i + 4
    if OBS_V3:
        # 会话51 B 预铺：与弹槽同序追加 (latN, τN)，基址=90（score 块不
        # 动游标，此处显式从 90 起笔）。ego 按静止参照预测（asm 镜像同式）：
        # latN=直线弹到最近approach时的横向偏距/300；τN=clip(1-到最近
        # approach拍数/48,0,1)，非迎面=0。MLP 从此"看得见弹道线还有几拍
        # 钉死我"，不再自己反推除法非线性。
        i2 = 90
        for j in range(6):
            if j < len(bl):
                dx0, dy0, vxs0, vys0 = bl[j][6], bl[j][7], bl[j][8], bl[j][9]
                s2 = vxs0 * vxs0 + vys0 * vys0
                rdx, rdy = -dx0, -dy0           # 弹→我
                dot = vxs0 * rdx + vys0 * rdy
                if s2 > 0 and dot > 0:
                    sv = math.sqrt(s2)
                    out[i2] = abs(vxs0 * rdy - vys0 * rdx) / sv / 300.0
                    # 会话51 B 预铺量纲修正：v 是 16.16 定点，到 CPA 拍数
                    # t* = dot·65536/s2（不是 dot/s2——后者≈恒 0，τN 会塌成
                    # approaching 旗标，全窗无时间梯度）。48 拍≈130px 威胁窗。
                    out[i2+1] = max(0.0, 1.0 - (dot * 65536.0 / s2) / 48.0)
            i2 += 2
        assert i2 == OBS, i2
    return out


# ---------------- 网络 ----------------
# 会话51 run19 预铺：隐层宽度参数化。init_nn 用全局 H（--width 设置）；
# 一切消费方（forward/更新/蒸馏导出 rl_distill_check/gen_rlbot_data/探针）
# 早已按 p["l1w"].shape 张量代数运行，宽度天然从 npz 形状反推，不落新标记。
H = 128


def init_nn():
    p = {}
    p["l1w"] = RNG.standard_normal((OBS, H)).astype(np.float32) * math.sqrt(2.0/OBS)
    p["l1b"] = np.zeros(H, dtype=np.float32)
    p["l2w"] = RNG.standard_normal((H, H)).astype(np.float32) * math.sqrt(2.0/H)
    p["l2b"] = np.zeros(H, dtype=np.float32)
    p["pw"] = RNG.standard_normal((H, NA)).astype(np.float32) * 0.01
    p["pb"] = np.zeros(NA, dtype=np.float32)
    p["vw"] = RNG.standard_normal((H, 1)).astype(np.float32) * 1.0
    p["vb"] = np.zeros(1, dtype=np.float32)
    return p


def forward(p, o):
    h1 = np.tanh(o @ p["l1w"] + p["l1b"])
    h2 = np.tanh(h1 @ p["l2w"] + p["l2b"])
    return h1, h2, h2 @ p["pw"] + p["pb"], (h2 @ p["vw"] + p["vb"])[:, 0]


def softmax(pi):
    x = pi - pi.max(1, keepdims=True)
    e = np.exp(x)
    return e / e.sum(1, keepdims=True)


def grads(p, o, a, adv, ret, clipmask, ent_coef):
    """解析梯度。clipmask=1 的样本策略梯度生效，被截断的=0。"""
    B = len(a)
    h1, h2, pi, val = forward(p, o)
    ps = softmax(pi)
    lp = np.log(np.clip(ps[np.arange(B), a], 1e-9, 1.0))
    # loss=-adv·logπ（mask=1 样本）→ ∂L/∂z_j = adv·(p_j−δ_ja)/B
    dlogits = ps.copy()
    dlogits[np.arange(B), a] -= 1.0
    dlogits *= ((adv * clipmask) / B)[:, None]
    # loss 含 -ent*H，∂H/∂z_j = -p_j(lp_j - m), m=Σp·lp → ∂/∂z_j = ent*p_j*(lp_j-m)/B
    lpp = np.log(np.clip(ps, 1e-9, 1.0))
    m = (ps * lpp).sum(1, keepdims=True)
    dlogits += (ent_coef / B) * ps * (lpp - m)
    dv = 2.0 * (val - ret) / B                      # value loss
    g2 = dlogits @ p["pw"].T + dv[:, None] @ p["vw"].T
    g2 *= (1.0 - h2*h2)
    g1w = h2.T @ dlogits; g1b = dlogits.sum(0)
    gvw = h2.T @ dv[:, None]; gvb = np.array([dv.sum()])
    g2w = h1.T @ g2; g2b = g2.sum(0)
    g0 = g2 @ p["l2w"].T
    g0 *= (1.0 - h1*h1)
    g1w2 = o.T @ g0; g1b2 = g0.sum(0)
    return {"l1w": g1w2, "l1b": g1b2, "l2w": g2w, "l2b": g2b,
            "pw": g1w, "pb": g1b, "vw": gvw, "vb": gvb}


class Adam:
    def __init__(self, p, lr):
        self.p, self.t, self.lr = p, 0, lr
        self.m = {k: np.zeros_like(v) for k, v in p.items()}
        self.v = {k: np.zeros_like(v) for k, v in p.items()}

    def step(self, g):
        self.t += 1
        b1, b2, eps = 0.9, 0.999, 1e-8
        for k in self.p:
            self.m[k] = b1*self.m[k] + (1-b1)*g[k]
            self.v[k] = b2*self.v[k] + (1-b2)*g[k]*g[k]
            mh = self.m[k]/(1-b1**self.t); vh = self.v[k]/(1-b2**self.t)
            self.p[k] -= self.lr * mh/(np.sqrt(vh)+eps)


# ---------------- 进攻型脚本陪练（会话47C） ----------------
# 实测实锤：内置启发式 bot 对移动目标 6000tick 仅开火 ~4 次——克隆或对战
# 它都学不到"主动开枪"（用户所报"转圈时发呆"即其瞄准条件几乎从不满足）。
# 脚本陪练直接走 slot1 真人电平通道（manual2），追击+定瞄+视距开火，
# 让击杀/阵亡信号密度提高两个数量级；难度旋钮可调，后续接自博弈课程。
def script_act(vec, j):
    e = vec.envs[j]
    s = vec.s[j]
    if not e.tv(s, 1, "alive") or not e.tv(s, 0, "alive"):
        return (0, 0, 0, 0, 0, 0)
    x, y = e.tv(s, 1, "x"), e.tv(s, 1, "y")
    dx, dy = e.tv(s, 0, "x") - x, e.tv(s, 0, "y") - y
    dist = math.hypot(dx, dy)
    tgt = math.degrees(math.atan2(dy, dx)) % 360
    err = (tgt - (e.tv(s, 1, "dir") % 360) + 180) % 360 - 180
    dead, fire_d = vec.kd[j], vec.kf[j]      # 会话47D：逐 env 旋钮（课程对手）
    cw = 1 if err > dead else 0
    ccw = 1 if err < -dead else 0
    fwd = 1 if dist > 130 and (ccw or cw or dist > 260) else 0
    back = 1 if dist < 80 else 0
    fire = 1 if abs(err) < 2*dead and dist < fire_d else 0
    return (fwd, back, ccw, cw, fire, 0)


# ---------------- 环境组 ----------------
class Vec:
    def __init__(self, n, start_seed, ego=0, opp="heuristic",
                 opp_dead=3, opp_fire_d=430, opp_var=False):
        self.envs = [TankEnv() for _ in range(n)]
        self.st = [dict(esin=0.0, ecos=0.0, sc0=0, sc1=0, sk_t=SK_NONE)
                   for _ in range(n)]
        self.seeds = [start_seed + 7919*i for i in range(n)]
        self.ego = ego
        self.opp_mode = opp
        self.opp_var = opp_var        # 会话47D：课程对手——每次换局重掷旋钮
        self.kd = [opp_dead] * n      # 逐 env 死区(°)
        self.kf = [opp_fire_d] * n    # 逐 env 开火视距(px)
        # 会话47E-run9：opp="mix" 逐 env 交替 script/heuristic——脚本池会
        # 自爆送"捡漏生存分"，纯脚本训练必产装死策略（run8 实证：79% 峰
        # 是开火 0.9/千t 的装死档）；启发式池不自爆，赢回合只能真打中人，
        # 装死收益直接砍半。换局随机重掷，两侧配比~50/50。
        # 会话51 run22：opp="gun" 对枪密弹池=小死区(3°)远视距(500px)脚本
        # +激进化启发式(heurA)交替。两种都"愿意把弹放出来"：躲弹塑形与
        # 掉血计价的信号密度直接决定"躲"能不能学会（mix 池里 heur 不还手
        # 档弹流稀，交战躲 45% 就是在那种低弹流里量出来的）。
        self.per = (["script" if j % 2 == 0 else
                     ("heurA" if opp in ("mixA", "gun") else "heuristic")
                     for j in range(n)]
                    if opp in ("mix", "mixA", "gun") else None)
        if opp == "gun":
            for j in range(n):
                self.kd[j] = 3.0
                self.kf[j] = 500.0
        self.manual2 = False
        swap = ego == 1
        if opp_var:
            self.reknob()
        self.s = [e.reset(seed=sd, swap=swap, manual2=self._script(j),
                          aggro=self._aggro(j))
                  for j, (e, sd) in enumerate(zip(self.envs, self.seeds))]

    def _script(self, j):
        return (self.per[j] == "script") if self.per else (self.opp_mode == "script")

    def _aggro(self, j):
        """会话50：槽1 exe 启发式走激进化档（RESET flags bit2）——它对移动
        目标几乎从不还手的问题由 bot.asm botAggro 开关修复（误差上限 4°→12°），
        使 heuristic 池成为有效击杀信号源（run8/run16 实证：不还手的对手池
        必产装死策略）。默认关——不影响任何既有池/评估口径。"""
        return ((self.per[j] == "heurA") if self.per else (self.opp_mode == "heurA"))

    def reknob(self):
        """死区 2~8°（对应反应精度从神枪手到手抖）、视距 260~470px。
        6 个 env 同时挂 6 档难度=天然课程池（源自 TankGame/BattleCity2021
        对抗训练共性：单一强度对手会让策略过拟合到该风格）。"""
        for j in range(len(self.kd)):
            self.kd[j] = float(RNG.uniform(2.0, 8.0))
            self.kf[j] = float(RNG.uniform(260.0, 470.0))

    def obs(self, j):
        return build_obs(self.envs[j], self.s[j], self.st[j], ego=self.ego)

    def step(self, j, aidx):
        prev = self.s[j]
        lv = tuple(A6[aidx].tolist())
        if self.ego == 1:
            act1 = lv
        elif self._script(j):
            act1 = script_act(self, j)
        else:
            act1 = None
        self.s[j] = self.envs[j].step(lv if self.ego == 0 else (0,)*6,
                                      rep=1, act1=act1)
        return prev, self.s[j]

    def note(self, j, prev, s):
        """回合内正得分累计（会话47C：冻结帧会清零 score，跳变 tick 读不得）。"""
        e = self.envs[j]
        if e.tv(s, 0, "score") > e.tv(prev, 0, "score"):
            self.st[j]["sc0"] += 1
        if e.tv(s, 1, "score") > e.tv(prev, 1, "score"):
            self.st[j]["sc1"] += 1

    def reseed(self, j):
        self.seeds[j] += 1_000_003
        self.st[j] = dict(esin=0.0, ecos=0.0, sc0=0, sc1=0, sk_t=SK_NONE)
        if self.per is not None:               # mix：换局重掷对手类型
            alt = "heuristic" if self.opp_mode == "mix" else "heurA"
            self.per[j] = "script" if RNG.random() < 0.5 else alt
        if self.opp_var:                       # 课程对手：换局重掷该 env 难度
            self.kd[j] = float(RNG.uniform(2.0, 8.0))
            self.kf[j] = float(RNG.uniform(260.0, 470.0))
        self.s[j] = self.envs[j].reset(seed=self.seeds[j], swap=self.ego == 1,
                                       manual2=self._script(j),
                                       aggro=self._aggro(j))


def threat(env, s, ego=0):
    """ego 受到的子弹威胁势 T=Σ w·(1-d/D0)（仅迎面、d<D0 的弹）。
    w：己方弹 SELF_W（防自伤但压得住不乱开），他方弹 1.0。
    d 用弹头到车体的实际间距；vx/vy 定点取迎面分量投影。"""
    x, y = env.tv(s, ego, "x"), env.tv(s, ego, "y")
    tv = env.tv
    if not tv(s, ego, "alive"):
        return 0.0
    bfp = getattr(env, "BULLET_FP", 0) or 176947
    T = 0.0
    for b in s["bullets"]:
        if not b[env.bul_dw["active"]]:
            continue
        bx, by = b[env.bul_dw["x"]], b[env.bul_dw["y"]]
        vx, vy = b[env.bul_dw["vx"]], b[env.bul_dw["vy"]]
        vxs = vx - 0x100000000 if vx >= 0x80000000 else vx
        vys = vy - 0x100000000 if vy >= 0x80000000 else vy
        dx, dy = x - bx, y - by
        d = math.hypot(dx, dy)
        if d >= DODGE_D0 or d < 1e-3:
            continue
        # 迎面判据：速度在"弹→车"方向上有正投影
        closing = (vxs * dx + vys * dy) / (bfp * d)
        if closing <= 0:
            continue
        w = SELF_W if b[env.bul_dw["owner"]] == ego else 1.0
        T += w * closing * (1.0 - d / DODGE_D0)
    return T


def own_gun_hit(env, prev, s, vx, vy, ego):
    """伤害归因：victim 角坐标 (vx,vy) 处，prev/s 两帧弹池里是否存在我方
    (owner==ego) 活动弹与其命中盒重叠（角点差 hypot<KILL_R）。必须查 prev：
    引擎命中同 tick 就把弹置 inactive（game.asm TankHitLoop 销毁子弹），
    s 里只剩"更早到达的另一颗"；弹速 2.7px/tick、重叠带 ~33px，单颗弹在
    带内 12+ tick，两帧并查无漏判。"""
    tw = env.bul_dw
    for st in (prev, s):
        for b in st["bullets"]:
            if b[tw["active"]] and b[tw["owner"]] == ego \
                    and math.hypot(b[tw["x"]] - vx, b[tw["y"]] - vy) < KILL_R:
                return True
    return False


IDLE_G = 250                                        # 久不试射宽限(tick)
IDLE_P = float(os.environ.get("RL_IDLEP", "0.006"))  # 超宽限罚/tick，开火即停罚


def reward(env, prev, s, stj=None):
    r = -0.002                                       # 时间惩罚（鼓励主动）
    tv = env.tv
    # run20 反龟项（会话51）：run19 容量已证实（cand2 和=92 双池全面超冠军）
    # 但火 0.1/千t——"不开火"是唯一零成本策略，HIT_P/ACC_SHOT 上浮拉不动。
    # 给"静默"定价：ego 存活且距上一发自弹超 IDLE_G tick，每 tick −IDLE_P；
    # 宽限 250 ⇒ 4 发/千t 完全免罚，与 finals 开火地板 4.0 同尺（训练激励=
    # 选拔闸门）。乱射回弹自亡仍受 −5 大梁自限，不用改 win/kill 结构。
    if stj is not None and tv(s, 0, "alive"):
        tw0 = env.bul_dw
        for i3, b in enumerate(s["bullets"]):
            if b[tw0["active"]] and b[tw0["owner"]] == 0 \
                    and not prev["bullets"][i3][tw0["active"]]:
                stj["shot_t"] = s["tick"]
                break
        if s["tick"] - stj.get("shot_t", -10 ** 9) > IDLE_G:
            r -= IDLE_P
    # 会话47E：敌"死亡+5"从无条件改为归因制，见下方 damage attribution 块。
    if tv(prev, 0, "alive") and not tv(s, 0, "alive"):
        r -= 5.0
    # 会话51 run22：受击直接计价。旧版受伤只有 −5 死讯的稀疏前传，掉 1HP
    # 当场零成本 ⇒"挨一发换一发"期望为正，NN 停在换弹均衡（能开火候选
    # 交战躲仅 45%，run21 cand1 实证）。每掉 1HP −HIT_M，致死仍是额外 −5
    # （3HP 全丢=−8+判负），把"躲开"变成立刻进账的正收入。
    if tv(prev, 0, "alive") and tv(s, 0, "hp") < tv(prev, 0, "hp"):
        r -= HIT_M * float(tv(prev, 0, "hp") - tv(s, 0, "hp"))
    if tv(s, 1, "alive") and tv(s, 0, "alive"):
        d0 = math.dist((tv(prev, 0, "x"), tv(prev, 0, "y")),
                       (tv(prev, 1, "x"), tv(prev, 1, "y")))
        d1 = math.dist((tv(s, 0, "x"), tv(s, 0, "y")),
                       (tv(s, 1, "x"), tv(s, 1, "y")))
        r += float(np.clip((d0 - d1) / env.MAP_W * 0.3, -0.02, 0.02))
    # 会话47D①：躲弹=势函数塑形 γΦ(s')−Φ(s)，Φ=−DODGE_K·threat。
    # 脱离弹道（threat 变小）即得正反馈，把稀疏的 −5 死亡惩罚补成
    # 逐 tick 连续梯度，策略能"学着躲"而非"撞死才知道躲"。
    phi_prev = -DODGE_K * threat(env, prev, 0)
    phi_now = -DODGE_K * threat(env, s, 0)
    r += float(np.clip(0.99 * phi_now - phi_prev, -DODGE_CLIP, DODGE_CLIP))
    # 会话47D②：技能发动沿/拾取沿（inc/game.inc 查实 skill=持有待发动
    # SK_ id，引擎消费归零为权威发动沿；effOn 全为益己掩码，敌方 effOn
    # 上升≠被我命中——第一版归因写反已纠）。沿须在伤害归因前先更新 sk_t。
    skd = False
    if stj is not None:
        if tv(prev, 0, "skill") > 0 and tv(s, 0, "skill") == 0:
            stj["sk_t"] = s["tick"]
            r += SK_ACT                            # 鼓励"拾了就用"
        elif tv(prev, 0, "skill") == 0 and tv(s, 0, "skill") > 0:
            r += SK_GRAB                           # 去吃技能道具
        skd = s["tick"] - stj.get("sk_t", SK_NONE) <= SK_WIN
    # 会话47E：击杀/命中必须归因到自己才记分。引擎成就行只认 dmgSrc!=victim
    # （game.asm DamageTankRaw"自雷/自激光不记 kill"），回合分判"最后存活者"
    # （game.asm:9379）——旧版 kill+5 无归因，对手被自己反弹弹自雷对我们是
    # 纯白捡收入 → run5 退化成"装死等对面自爆"（58% 峰开火仅 0.6/千t，低于
    # 启发式 1.2，用户要的四能力全违背）。现仅两证记分：我方弹在受害 tick
    # 与受害盒重叠（own_gun_hit，prev 帧弹池为主证）或技能发动窗口内掉血：
    # 致死 +5（替代旧无条件击杀分），未致死 +HIT_P 0.8（新增"打中即赚"稠密信号）。
    if tv(prev, 1, "alive") and tv(s, 1, "hp") < tv(prev, 1, "hp"):
        gun = own_gun_hit(env, prev, s, tv(s, 1, "x"), tv(s, 1, "y"), 0)
        if skd:
            r += SK_BONUS
            if stj is not None:
                stj["sk_t"] = SK_NONE              # 一次发动只记一次命中
        if gun or skd:
            # run13 回合经济重排：kill 5.0→3.5——run12 冠军档(归因杀0.62~0.74
            # 全场史最高、正评仅 12%/5%)证明"杀穿但输回合"套利：引擎对手
            # 死后即复活可被反复 +5，而活到最后只有 +3，杀收入天然压过胜负。
            r += 3.5 if not tv(s, 1, "alive") else HIT_P
    # 会话47D④：锁瞄（角带内微奖，教它"把车头转向人"）+ 精度弹
    # （出膛 2 tick 时弹头离敌中心 <50px = 这枪瞄得准，age==2 恰一 tick 去重）。
    if tv(s, 0, "alive") and tv(s, 1, "alive"):
        x, y = tv(s, 0, "x"), tv(s, 0, "y")
        ex1, ey1 = tv(s, 1, "x"), tv(s, 1, "y")
        dx, dy = ex1 - x, ey1 - y
        dist1 = math.hypot(dx, dy)
        if dist1 < AIM_D:
            tgt = math.degrees(math.atan2(dy, dx)) % 360
            err = (tgt - tv(s, 0, "dir") % 360 + 180) % 360 - 180
            if abs(err) < AIM_T:
                r += AIM_RATE
        # 会话47E-run7：准星弹判据改版——自弹"首次进入敌擦身带"记一次。
        # 旧 age==2 版弹头只离膛 5px，条件等价"50px 内战贴脸开枪"，在
        # 477px 交战距下恒不触发=瞄准梯度断供（run6 瞄占比仍 1~3%）。
        # 新判据全程有效：弹道只要瞄得准（离敌角点 <20px）即 +0.5，
        # 一弹一次（进带置 -1 销账，弹销毁回 1e18 复用槽自然重置）。
        tw = env.bul_dw
        if stj is not None:
            if stj.get("bmin") is None:
                stj["bmin"] = [1e18] * env.MAX_BULLETS
            bm = stj["bmin"]
            for i2, b in enumerate(s["bullets"]):
                if not b[tw["active"]]:
                    bm[i2] = 1e18
                    continue
                if b[tw["owner"]] != 0:
                    continue
                d2 = math.hypot(b[tw["x"]] - ex1, b[tw["y"]] - ey1)
                if bm[i2] >= ACC_R and d2 < ACC_R:
                    r += ACC_SHOT
                    bm[i2] = -1.0
                elif bm[i2] >= 0.0 and d2 < bm[i2]:
                    bm[i2] = d2
    # 会话47D⑤：技能道具趋近塑形——skill 唯一来源是拾取，不主动去捡
    # 则技能链（拾→发→中）永不开张。距离每 tick 净减给奖（对称于逼近项）。
    # run7 加"进圈奖"：侵入道具 80px 圈一次性 +0.4（每次入圈只给一次，
    # 出圈复位）——run6 全程 0 拾取证明纯距离塑形压不住避险惯性。
    if tv(s, 0, "alive") and s["pickupType"] > 0 and prev["pickupType"] > 0:
        pd0 = math.dist((tv(prev, 0, "x"), tv(prev, 0, "y")),
                        (prev["pickupX"], prev["pickupY"]))
        pd1 = math.dist((tv(s, 0, "x"), tv(s, 0, "y")),
                        (s["pickupX"], s["pickupY"]))
        # run8：系数 1.2→20——2.2px/tick 位移兑现 0.055/tick，与躲弹塑形
        # (≤0.1)同量级；旧 1.2 系数只兑现 0.003，梯度被躲弹项淹没。
        # run12 冲突仲裁：同 tick 弹威胁上升时不给**正向**趋近分——道具
        # 趋近与交战卡距在旧口径下直接互斥（证据链：p10 距道具随开火权重
        # 恶化 165→219→396px；skbest 档进圈带仅 1.7%，60 正评 1 拾靠侥幸）。
        # 只沿"火线切线抢"才兑现 → 塑造安全趋近路径而非无脑冲圈。负项
        # （远离道具）不受门控：退道具恒罚，避险不能白退。
        ap = float(np.clip((pd0 - pd1) / env.MAP_W * 20.0, -PICK_RATE, PICK_RATE))
        if ap > 0.0 and threat(env, s, 0) - threat(env, prev, 0) > 1e-6:
            ap = 0.0
        r += ap
        if stj is not None:
            if pd1 < SK_ZONE and not stj.get("pkz", False):
                r += SK_ZONES
                stj["pkz"] = True
            elif pd1 >= SK_ZONE:
                stj["pkz"] = False
    # 会话47C：得分判定改在"加分发生的那一 tick"（探针 rl_probe47 实测：
    # 多数回合在轮次跳变 tick 当场加分，少数先加分、跳变 tick 反而清零，
    # 旧写法把清零 tick 误当无人得分）。
    if tv(s, 0, "score") > tv(prev, 0, "score"):
        r += 8.0                                 # 本回合我是最后存活者（run13：3→8，与 kill3.5 拉开主次）
    elif tv(s, 1, "score") > tv(prev, 1, "score"):
        r -= 1.0
    return r


def sample_slice(vec, j, p, horizon, stats):
    """一个环境一段 rollout。返回 dict of arrays + bootstrap value。"""
    O = np.zeros((horizon, OBS), dtype=np.float32)
    A = np.zeros(horizon, dtype=np.int64)
    LP = np.zeros(horizon, dtype=np.float32)
    V = np.zeros(horizon, dtype=np.float32)
    R = np.zeros(horizon, dtype=np.float32)
    D = np.zeros(horizon, dtype=np.float32)
    for t in range(horizon):
        o = vec.obs(j)
        _, _, pi, v = forward(p, o[None])
        ps = softmax(pi)
        a = int(RNG.choice(NA, p=ps[0]))
        prev, s = vec.step(j, a)
        vec.note(j, prev, s)
        if env_tv(vec, j, prev, s, 0):
            stats["die0"] += 1
        if env_tv(vec, j, prev, s, 1):
            stats["die1"] += 1
        r = reward(vec.envs[j], prev, s, vec.st[j])
        # episode=一回合（会话47修订）：整场比赛极少终结（双方无限复活互耗），
        # 比赛级 episode 下 2.8M 步只切出 ~500 局，advantage 噪声大且 win 恒 0。
        # 回合结束（roundsPlayed 变化）即切断 bootstrap，信号密度提高一个量级。
        done = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
        O[t], A[t] = o, a
        V[t] = float(v[0]); R[t] = r; D[t] = 1.0 if done else 0.0
        lp = math.log(max(float(ps[0][a]), 1e-9))
        LP[t] = lp
        stats["steps"] += 1
        if done:
            stats["eps"] += 1
            stj = vec.st[j]
            if stj["sc0"] > stj["sc1"]:
                stats["wins"] += 1
            else:
                stats["losses"] += 1
            vec.reseed(j)
    _, _, _, bv = forward(p, vec.obs(j)[None])
    return O, A, LP, V, R, D, float(bv[0])


def gae_env(R, D, V, bv, gamma, lam):
    n = len(R); adv = np.zeros(n, dtype=np.float32); last = 0.0
    for t in reversed(range(n)):
        nextv = bv if t == n-1 else V[t+1]
        nxt = 0.0 if D[t] else last
        delta = R[t] + gamma * nextv * (1.0 - D[t]) - V[t]
        last = adv[t] = delta + gamma * lam * nxt
    return adv


def train(iters, nenv, horizon, gamma=0.99, lam=0.95, clip=0.2,
          epochs=8, mb=384, lr=1e-3, ent=0.01, seed0=1000, eval_every=50,
          opp="script", init=None, best0=None, opp_var=False, finals=-1,
          fire_floor=4.0, dodge_floor=0.0):
    # 会话47D：train.best 原为进程内 -1，续训时第一个噪声快评就把上一轮
    # 真最优权重覆盖掉（run3 实测：42%快评盖掉 54%，正评仅 13% 才发现）。
    # 显式传入已知最优（百分数）才能守住 BEST。
    train.best = best0 if best0 is not None else -1.0
    # 会话47E-run11：技能漏斗第二档（见 SKB 注释）；进程内变量，续训天然清零重赛
    train.best_sk = -1.0
    # 会话47E-run14：终局协议候选（[comp, slot] 列表，见 CANDS 注释）
    train.cands = []
    # 会话47C：默认对手改 script——启发式 bot 对移动目标几乎不开火
    # （实测 4 弹/6000tick），对战/克隆都学不到主动交火；脚本陪练把
    # 杀/亡信号密度提两个数量级。启发式对照仍可用 --opp heuristic。
    # （更早：lr3e-4/ep4 推不动的教训 → 1e-3/8ep + 退火）
    vec = Vec(nenv, seed0, opp=opp, opp_var=opp_var)
    global OBS_V2
    p = dict(np.load(init or CKPT)) if os.path.exists(init or CKPT) else init_nn()
    # run15：观测编码版本随权重走——init 档带 obsv2 标记则自动继承，
    # 避免 --obsv2 忘了加/多加导致新层乱读旧编码。
    if "obsv2" in p:
        OBS_V2 = bool(float(np.asarray(p["obsv2"]).ravel()[0]))
    p.pop("obsv2", None)
    # run23：obsv3 同理；且允许 90 列旧档暖启动补零进 102 列——
    # 新 12 列权重行为 0 ⇒ 起点=冠军本尊行为，梯度慢慢学特征。
    if "obsv3" in p:
        apply_obsv3(bool(float(np.asarray(p["obsv3"]).ravel()[0])))
    p.pop("obsv3", None)
    if OBS_V3 and p["l1w"].shape[0] == 90:
        w90 = p["l1w"]
        nw = np.zeros((OBS, w90.shape[1]), dtype=np.float32)
        nw[:90] = w90
        p["l1w"] = nw
        print("[init] 90→102 列补零暖启动（V3 特征行从 0 学起）", flush=True)
    ad = Adam(p, lr)
    t0 = time.perf_counter(); gstep = 0
    for it in range(iters):
        batches, stats = [], dict(steps=0, wins=0, losses=0, eps=0,
                                  die0=0, die1=0)
        for j in range(nenv):
            batches.append(sample_slice(vec, j, p, horizon, stats))
        O = np.concatenate([b[0] for b in batches])
        A = np.concatenate([b[1] for b in batches])
        LP = np.concatenate([b[2] for b in batches])
        V = np.concatenate([b[3] for b in batches])
        R = np.concatenate([b[4] for b in batches])
        D = np.concatenate([b[5] for b in batches])
        advs, rets = [], []
        for j, b in enumerate(batches):
            a = gae_env(b[4], b[5], b[3], b[6], gamma, lam)
            advs.append(a); rets.append(a + b[3])
        adv = np.concatenate(advs); ret = np.concatenate(rets)
        gstep += stats["steps"]
        adv = (adv - adv.mean()) / (adv.std() + 1e-8)
        # PPO epochs
        for ep in range(epochs):
            idx = RNG.permutation(len(O))
            for i0 in range(0, len(O), mb):
                b = idx[i0:i0+mb]
                _, _, pi, _ = forward(p, O[b])
                ps = softmax(pi)
                lp = np.log(np.clip(ps[np.arange(len(b)), A[b]], 1e-9, 1.0))
                ratio = np.exp(lp - LP[b])
                clipped = ((ratio > 1+clip) & (adv[b] > 0)) | \
                          ((ratio < 1-clip) & (adv[b] < 0))
                mask = np.where(clipped, 0.0, 1.0).astype(np.float32)
                ad.step(grads(p, O[b], A[b], adv[b], ret[b], mask, ent))
        wr = 100.0 * stats["wins"] / max(stats["eps"], 1)
        msg = (f"it{it} step{gstep} rounds={stats['eps']} win%={wr:.0f} "
               f"die={stats['die0']}:{stats['die1']} R={R.mean():+.3f} "
               f"sps={gstep/(time.perf_counter()-t0):,.0f} "
               f"clip%={100*clipped.mean():.0f}")
        print(msg, flush=True)
        with open(LOGP, "a") as fh:
            fh.write(msg + "\n")
        np.savez(CKPT, obsv2=np.array([1.0 if OBS_V2 else 0.0]), obsv3=np.array([1.0 if OBS_V3 else 0.0]), **p)
        # 会话47C：lr 线性退火（1e-3 冲顶后塌车，终点 1/10）；每 50 迭代
        # 快评一次并保最优权重——峰值被终值覆盖是本run最大的教训。
        ad.lr = max(lr * 0.1, lr * (1.0 - (it + 1) / iters))
        if eval_every and (it + 1) % eval_every == 0:
            # 会话47D run5：快评非静默——每档打印能力卡（开火/躲弹/技能
            # 四级漏斗/瞄占比），技能与瞄准的爬坡在训练期就可见，不等收尾。
            w, n, e0, e1, cap = eval_greedy(3, 36, seed0=999_001 + it,
                                            quiet=False, opp=opp, pdict=p)
            rate = 100.0 * w / max(n, 1)
            # 会话47E-run9：BEST 判据从纯胜率改**复合分**——纯胜率会
            # 系统性收割装死档（run8 实测：79% 存档开火仅 0.9/千t、捡漏
            # 19，turtle 把对手自爆当收入）。
            # 会话47E-run10 再修：run9 的 20×(拾取+发动) 按"次"计，24 回合
            # 一次幸运拾取=+40，把 comp=96 推成开火仅 1.3/千t 的档位（正评
            # 45%/32% 双新高但开火近零、探针进圈 0.1%）——技能项要归一化，
            # 且开火率本身必须是选拔维度。comp = win% + 100×击杀(归因)/千t
            # + 3×开火/千t + 100×(拾取+发动)/回合。turtle 67% 档只剩 67；
            # 对拼档 33+28(杀0.28)+39(火13) 即破百；run9 的 win4% 真打档
            # (火11.6/杀0.65)在此口径下 ≈104，本该被选中——旧式漏杀。
            # 会话47E-run11 三反例：comp=129 win-0 狂战档登顶（火 14.8=44 分
            # +杀 0.84=84 分，die 24:12 每回合先死，却压过 win 38% 的 124 档）
            # ——杀/火项没有生存约束。补 +100×(敌亡−己亡)/回合数：狂战 -50 →
            # 78 出局；run10 真打档 (20-16)/24≈+17 → 127 守住。
            k1k = 1000.0 / max(cap.ticks, 1)
            comp = rate + 100.0 * cap.kills * k1k \
                   + 3.0 * cap.shots * k1k \
                   + 100.0 * (cap.sk_grab + cap.sk_act) / max(n, 1) \
                   + 100.0 * (e1 - e0) / max(n, 1)
            em = (f"    [eval] 贪心 {w}/{n}={rate:.0f}% comp={comp:.0f} "
                  f"杀归{cap.kills * k1k:.2f} 火{cap.shots * k1k:.1f}/千t "
                  f"技{cap.sk_grab}拾{cap.sk_act}发 die={e0}:{e1}")
            print(em, flush=True)
            with open(LOGP, "a") as fh:
                fh.write(em + "\n")
            # run13 选拔胜率地板：comp=148 冠军档(杀火满格、正评 12%/5%)
            # 教训——杀/火/生存项能把 win≈0 档抬进 BEST。win<25% 无资格
            # 主存（技能守档不设地板，幸运漏斗窗照扣）。
            if comp > train.best and rate >= 25.0:
                train.best = comp
                np.savez(BEST, obsv2=np.array([1.0 if OBS_V2 else 0.0]), obsv3=np.array([1.0 if OBS_V3 else 0.0]), **p)
                with open(LOGP, "a") as fh:
                    fh.write(f"    [eval] 新最优 comp={comp:.0f} "
                             f"(win {rate:.0f}%) → rl_policy_best.npz\n")
            # run14 终局协议·候选登记：过地板的窗按 comp 前 3 名单独存槽，
            # 收官双池正评钦定冠军（快评 mix→单池正评转移性三连败，选拔
            # 终点必须就是验收口径本身）。
            if rate >= 25.0:
                slot = None
                if len(train.cands) < 3:
                    slot = len(train.cands)
                    train.cands.append([comp, slot])
                else:
                    worst = min(range(3), key=lambda i: train.cands[i][0])
                    if comp > train.cands[worst][0]:
                        slot = worst
                        train.cands[worst][0] = comp
                if slot is not None:
                    np.savez(CANDS[slot], obsv2=np.array([1.0 if OBS_V2 else 0.0]), obsv3=np.array([1.0 if OBS_V3 else 0.0]), **p)
                    cm = (f"    [eval] 候选 comp={comp:.0f} 存cand{slot+1} "
                          f"(现存 {[round(c[0]) for c in sorted(train.cands, key=lambda c: -c[0])]} )")
                    print(cm, flush=True)
                    with open(LOGP, "a") as fh:
                        fh.write(cm + "\n")
            # 会话47E-run11：技能漏斗第二存档点——按千t速率（非次数）竞争，
            # 单档 comp 会把技能档系统性挤掉（见 SKB 注释），漏斗开张的档
            # 无论 comp 高低都单独留住，收官后与主档做双对照正评。
            sk = (cap.sk_grab + cap.sk_act) * k1k
            if sk > train.best_sk:
                train.best_sk = sk
                np.savez(SKB, obsv2=np.array([1.0 if OBS_V2 else 0.0]), obsv3=np.array([1.0 if OBS_V3 else 0.0]), **p)
                sm = (f"    [eval] 新技能档 sk={sk:.3f}/千t "
                      f"技{cap.sk_grab}拾{cap.sk_act}发 (comp={comp:.0f}) "
                      f"→ rl_policy_skbest.npz")
                print(sm, flush=True)
                with open(LOGP, "a") as fh:
                    fh.write(sm + "\n")

    # run14 终局协议：训练收官对 comp 前 3 候选各做双池 60 回合正评，
    # (script%+heuristic%) 和最高者钦定冠军覆写 BEST——选拔终点=验收口径。
    # finals: -1=自动(iters≥300 才跑) / 1=强制(冒烟直测) / 0=禁用；无候选自然跳过。
    # 会话51 开火地板：run18 教训——纯和排序把 火0.2/千t 的神龟(和=62)选成
    # 冠军，胜率赢了但违背"发射子弹/追踪/技能/躲弹"四能力目标。候选须双池
    # 合计开火/千t ≥ fire_floor 才有钦定资格；全部不过闸=保留在位 BEST。
    run_fin = finals == 1 or (finals == -1 and iters >= 300)
    if run_fin and train.cands:
        rows = []
        for comp_c, slot in sorted(train.cands, key=lambda c: -c[0]):
            q = dict(np.load(CANDS[slot]))
            ws, ns, _, _, cs = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                           opp="script", pdict=q)
            wh, nh, _, _, ch = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                           opp="heuristic", pdict=q)
            rs, rh = 100.0 * ws / max(ns, 1), 100.0 * wh / max(nh, 1)
            fk = 1000.0 * (cs.shots + ch.shots) / max(cs.ticks + ch.ticks, 1)
            # run22 主躲率（双池合并，分母=被瞄且贴身的遭遇）：留作描述
            # 读数。实测区分力不足——turtle77/92 主躲 81~89% 反超 shooter
            # 76%（逃跑天然少挨贴脸弹），故**不作为闸门**；闸门用受击暴露
            # ex（中弹/千t，双池）：能过开火地板者都在主动交战，谁的暴露
            # 低才是真"挨打少"。14champ 同尺 ex≈0.56/千t。
            dk = 100.0 * (cs.dA + ch.dA) / max(cs.dA + ch.dA + cs.dF + ch.dF, 1)
            ex = 1000.0 * (cs.hits + ch.hits) / max(cs.ticks + ch.ticks, 1)
            rows.append((rs + rh, comp_c, slot, rs, rh, fk, dk, ex))
            fm = (f"[finals] cand{slot+1} comp={comp_c:.0f} "
                  f"正评 script={rs:.0f}%(火{cs.shots*1000.0/max(cs.ticks,1):.1f}/千t"
                  f" 躲{100.0*cs.dodges/max(cs.dodges+cs.hits,1):.0f}%) "
                  f"heur={rh:.0f}%(火{ch.shots*1000.0/max(ch.ticks,1):.1f}) "
                  f"和={rs+rh:.0f} 火计{fk:.1f}/千t 主躲{dk:.0f}% 暴露{ex:.2f}/千t")
            print(fm, flush=True)
            with open(LOGP, "a") as fh:
                fh.write(fm + "\n")
        # 会话51 开火地板：run18 神龟(和62 火0.2)教训——候选先过 fire_floor
        # 闸再谈和的排序；全部不过闸=不登基，连旧 BEST 复评都不启动。
        # run22 追加躲弹闸门：过火闸者受击暴露还须 ≤ dodge_floor/千t
        # （0=关）——交战归交战，挨打少才是真躲；神龟进不了火闸碰不到此门。
        ok = [r for r in rows if r[5] >= fire_floor
              and (dodge_floor <= 0 or r[7] <= dodge_floor)]
        if not ok:
            fm = ("[finals] 全部候选不过地板(火计 %s < %.1f/千t 或 暴露 %s > %.2f/千t)"
                  " → 神龟/木桩不登基，保留在位 BEST"
                  % (" ".join("%.1f" % r[5] for r in rows), fire_floor,
                     " ".join("%.2f" % r[7] for r in rows), dodge_floor))
        else:
            win = max(ok)
            # 会话50b 护栏：run17 教训——finals 收官无条件用候选里和最高者覆写
            # BEST，续训暖启动时把和=82 冠军刷成 cand3 和=60（--best0 只守中途
            # 快评噪声，不守终点）。现先按同协议复评"现 BEST"双池和，新冠军和
            # 更高才覆写，否则保留旧冠军。旧 BEST 缺失/不可评则照旧。
            old = None
            if os.path.exists(BEST):
                try:
                    b0 = dict(np.load(BEST))
                    # 会话51 单位案：eval_greedy 首值是胜"数"不是百分比——
                    # run18 时 old=rs0+rh0 把计数当和(49)与候选真百分比(62)
                    # 对比，护栏被单位骗穿，神龟(火0.2)误登大位。必须同尺。
                    rs0, ns0, _, _, _ = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                                    opp="script", pdict=b0)
                    rh0, nh0, _, _, _ = eval_greedy(4, 60, seed0=999_001, quiet=True,
                                                    opp="heuristic", pdict=b0)
                    old = (100.0 * rs0 / max(ns0, 1)
                           + 100.0 * rh0 / max(nh0, 1))
                except Exception as ex:
                    print("[finals] 旧 BEST 复评失败(%s)，按原协议覆写" % ex,
                          flush=True)
            if old is not None and win[0] < old:
                fm = ("[finals] 冠军 cand%d 和=%.0f < 旧 BEST 和=%.0f"
                      " → 保留旧冠军（不覆写）" % (win[2] + 1, win[0], old))
            else:
                q = dict(np.load(CANDS[win[2]]))
                np.savez(BEST, **q)
                fm = ("[finals] 冠军 cand%d 和=%.0f 旧=%s 火%.1f → 覆写 rl_policy_best.npz"
                      % (win[2] + 1, win[0],
                         ("%.0f" % old) if old is not None else "无", win[5]))
        print(fm, flush=True)
        with open(LOGP, "a") as fh:
            fh.write(fm + "\n")


class Cap:
    """会话47D：能力卡——把用户点名的四项能力拆成独立可测：
    开火/追踪(瞄准占比)/技能(发动+命中)/躲弹(擦身闪避率)。
    躲弹判据：敌弹全程与 ego 最近距离 < NEAR 且弹消亡时 ego 本 tick 未中弹
    → 记一次"擦身而过"；中弹 tick 把最近距离<30 的弹头销账（那是命中弹）。
    会话51 run22 新增**主动躲**（主躲判据）：敌弹曾在某 tick 满足"弹道
    指向 ego"（closing>0 且横向偏距 CPA<COLR≈命中盒），此后弹消亡且未
    命中=躲成（ego 挪出弹道/偏掉），命中=躲败。旧口径把"对手本来就打偏
    的流弹擦身"也算躲（turtle58 靠逃跑刷出 76% 即此水分），主躲的分母
    只认真冲你来的弹——finals 躲弹地板以此为准。"""
    NEAR = 40.0      # 擦身半径（车身半宽~12 + 28px 余量）
    COLR = 16.0      # 主躲判定的弹道横向命中带(px, 车半宽+弹半宽)
    AIM = 12.0       # 命中角带(°)
    FIRE_D = 430.0   # 计瞄准的索敌距离
    def __init__(self, nenv):
        self.n = nenv
        self.ticks = self.shots = self.kills = self.hits = self.dodges = 0
        self.dA = self.dF = 0              # 主动躲：成/败（run22）
        self.scav = 0                      # 捡漏击杀（对手自雷致死，未归因，47E）
        self.sk_act = self.sk_hit = self.sk_grab = 0
        self.pick_t = 0                      # 诊断：技能道具在场 tick
        self.aim_t = self.live_t = 0
        self.skT = [SK_NONE] * nenv
        self.mind = None
    def update(self, vec, j, prev, s):
        e = vec.envs[j]; tv = e.tv
        if self.mind is None:
            self.mind = [[1e18] * e.MAX_BULLETS for _ in range(self.n)]
            self.oncol = [[False] * e.MAX_BULLETS for _ in range(self.n)]
        ego, opp = vec.ego, 1 - vec.ego
        self.ticks += 1
        ex, ey = tv(s, ego, "x"), tv(s, ego, "y")
        hit = bool(tv(prev, ego, "alive") and
                   tv(s, ego, "hp") < tv(prev, ego, "hp"))
        if hit:
            self.hits += 1
        # 会话47E：击杀改归因双轨（与 reward 同判据）——自弹重叠/技能窗口
        # = kills；否则=捡漏 scav（对手被自己反弹弹炸死）。
        tw = e.bul_dw
        for b in s["bullets"]:
            if b[tw["active"]] and b[tw["age"]] == 1 and b[tw["owner"]] == ego:
                self.shots += 1                    # age==1 恰出现一 tick
        # ——躲弹逐弹记账（旧口径=擦身 NEAR；run22 新口径=主躲 oncol；
        #   CPA 判据用叉积/模长，与定点速度尺度无关，无需除 bfp）——
        for i, b in enumerate(s["bullets"]):
            if not b[tw["active"]]:
                if self.mind[j][i] < Cap.NEAR and not hit:
                    self.dodges += 1
                if self.oncol[j][i]:
                    if self.mind[j][i] >= Cap.NEAR:
                        pass                      # 被瞄过但从未贴身：非遭遇，不记账
                    elif hit and self.mind[j][i] < 30.0:
                        self.dF += 1              # 贴身冲我来的弹打穿=躲败
                    else:
                        self.dA += 1              # 贴身量级躲过=真闪避
                    self.oncol[j][i] = False
                self.mind[j][i] = 1e18
                continue
            if b[tw["owner"]] == ego:
                continue
            d = math.hypot(b[tw["x"]] - ex, b[tw["y"]] - ey)
            if d < self.mind[j][i]:
                self.mind[j][i] = d
            if not self.oncol[j][i]:
                vx, vy = b[tw["vx"]], b[tw["vy"]]
                vxs = vx - 0x100000000 if vx >= 0x80000000 else vx
                vys = vy - 0x100000000 if vy >= 0x80000000 else vy
                nv = math.hypot(vxs, vys)
                # 距离门控：只在威胁窗内(同 DODGE_D0)判定"弹道指过我"——
                # 远距 aiming 弹飞行中车体自然横移，会白送"躲成"水分
                # (首测 script 池 95% 即此病)，d<180 时仍是真冲我来。
                if nv > 1e-6 and d < DODGE_D0:
                    ddx, ddy = ex - b[tw["x"]], ey - b[tw["y"]]
                    if (ddx * vxs + ddy * vys) > 0 and \
                       abs(ddx * vys - ddy * vxs) / nv < self.COLR:
                        self.oncol[j][i] = True
        if hit:
            for i, b in enumerate(s["bullets"]):
                if b[tw["active"]] and self.mind[j][i] < 30.0:
                    self.mind[j][i] = 1e18
                    if self.oncol[j][i]:
                        self.dF += 1
                        self.oncol[j][i] = False
        # ——技能：引擎消费沿=发动成功——
        if s["pickupType"] > 0:
            self.pick_t += 1                   # 道具在场（诊断稀有度）
        if tv(prev, ego, "skill") == 0 and tv(s, ego, "skill") > 0:
            self.sk_grab += 1                  # 拾到技能道具（诊断可达性）
        if tv(prev, ego, "skill") > 0 and tv(s, ego, "skill") == 0:
            self.sk_act += 1
            self.skT[j] = s["tick"]
        # 会话47E：伤害 tick 两证归因（击杀归属+技能命中，与 reward 同判据）。
        if tv(prev, opp, "alive") and tv(s, opp, "hp") < tv(prev, opp, "hp"):
            gun = own_gun_hit(e, prev, s, tv(s, opp, "x"), tv(s, opp, "y"), ego)
            skd = s["tick"] - self.skT[j] <= SK_WIN
            if skd:
                self.sk_hit += 1
                self.skT[j] = SK_NONE
            if not tv(s, opp, "alive"):
                if gun or skd:
                    self.kills += 1
                else:
                    self.scav += 1
        elif tv(prev, opp, "alive") and not tv(s, opp, "alive"):
            self.scav += 1              # 防御：无掉血 tick 的死亡（理论不发生）
        # ——瞄准占比——
        if tv(s, ego, "alive") and tv(s, opp, "alive"):
            self.live_t += 1
            dx, dy = tv(s, opp, "x") - ex, tv(s, opp, "y") - ey
            if math.hypot(dx, dy) < Cap.FIRE_D:
                tgt = math.degrees(math.atan2(dy, dx)) % 360
                err = (tgt - tv(s, ego, "dir") % 360 + 180) % 360 - 180
                if abs(err) < Cap.AIM:
                    self.aim_t += 1
    def report(self, tag=""):
        k = 1000.0 / max(self.ticks, 1)
        dg = self.dodges + self.hits
        dd = self.dA + self.dF
        print(f"CAP{tag}: {self.ticks}tick "
              f"开火{self.shots * k:.1f}/千t 击杀{self.kills * k:.2f}/千t(归因)/捡漏{self.scav} "
              f"中弹{self.hits * k:.2f}/千t 躲弹{100.0 * self.dodges / max(dg, 1):.0f}%({self.dodges}/{dg}) "
              f"主躲{100.0 * self.dA / max(dd, 1):.0f}%({self.dA}/{dd}) "
              f"技能 在场{self.pick_t}t/拾取{self.sk_grab}次/发动{self.sk_act}次/命中{self.sk_hit}次 "
              f"瞄准占比{100.0 * self.aim_t / max(self.live_t, 1):.0f}%", flush=True)


def eval_greedy(nenv=4, rounds=60, seed0=999_001, quiet=False, opp="script",
                pdict=None):
    """贪心回合级评估：胜=本回合得分 strictly 高于对手；2500tick 未分胜负
    判和(计负)。另报阵亡比（比胜负更抗判定噪声）+ 能力卡（会话47D）。"""
    global OBS_V2
    p = pdict if pdict is not None else dict(np.load(CKPT))
    if "obsv2" in p:                      # run15：编码版本随权重自动对齐
        OBS_V2 = bool(float(np.asarray(p["obsv2"]).ravel()[0]))
    if "obsv3" in p:                      # run23：obsv3 随权重自动对齐
        apply_obsv3(bool(float(np.asarray(p["obsv3"]).ravel()[0])))
    else:
        # run23 首修病根：train 周期快评传的内存 p 不带标记（init 时已 pop），
        # 无条件 apply(False) 把 OBS 复位 90，与 102 列 l1w 相乘即炸。
        # 按 l1w 列宽对齐——列宽是比标记更硬的证据，标记缺失时兜底。
        apply_obsv3(p["l1w"].shape[0] == 102)
    vec = Vec(nenv, seed0, opp=opp)
    cap = Cap(nenv)
    per = [rounds // nenv + (1 if i < rounds % nenv else 0) for i in range(nenv)]
    res = []
    die0 = die1 = 0
    for j in range(nenv):
        cnt = 0
        ep = 0
        while cnt < per[j]:
            ep += 1
            if ep > 3000 * (per[j] + 1):
                break                       # 防御：环境异常不再空转
            o = vec.obs(j)
            _, _, pi, _ = forward(p, o[None])
            act = int(pi[0].argmax())
            prev, s = vec.step(j, act)
            vec.note(j, prev, s)
            cap.update(vec, j, prev, s)
            if env_tv(vec, j, prev, s, 0):
                die0 += 1
            if env_tv(vec, j, prev, s, 1):
                die1 += 1
            over = bool(s["matchOver"] or s["roundsPlayed"] != prev["roundsPlayed"])
            if over or ep % 2500 == 0:
                stj = vec.st[j]
                win = stj["sc0"] > stj["sc1"] if ep % 2500 else False
                res.append(1 if win else 0)
                cnt += 1
                vec.reseed(j)
                ep = 0
    for e in vec.envs:
        e.close()
    w = sum(res)
    if not quiet:
        print(f"EVAL greedy vs {opp}: 回合胜 {w}/{len(res)} = "
              f"{100.0*w/max(len(res),1):.0f}%  阵亡比 {die0}:{die1} (我:对面)")
        cap.report(f"[vs {opp}]")
    return w, len(res), die0, die1, cap


def env_tv(vec, j, prev, s, slot):
    """prev 活、s 死 → True（阵亡事件）。"""
    e = vec.envs[j]
    return bool(e.tv(prev, slot, "alive") and not e.tv(s, slot, "alive"))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=200)
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--steps", type=int, default=256)
    ap.add_argument("--eval-only", action="store_true")
    ap.add_argument("--rounds", type=int, default=60)
    ap.add_argument("--opp", default="script",
                    choices=("script", "heuristic", "mix", "heurA", "mixA", "gun"),
                    help="对手：script=进攻型脚本陪练 / heuristic=游戏内置 / "
                         "mix=逐env对半混池(run9：堵死装死刷分通路) / "
                         "heurA=激进化内置(botAggro，会话50) / mixA=script+heurA 混池 / "
                         "gun=对枪密弹池(run22：死区3°+视距500px脚本 与 heurA 交替，"
                         "躲弹专项的信号源)")
    ap.add_argument("--lr", type=float, default=1e-3, help="Adam 初始学习率(线性退火至1/10)")
    ap.add_argument("--init", default="", help="初始权重 npz（如 rl_policy_best.npz 续训）")
    ap.add_argument("--opp-var", action="store_true",
                    help="课程对手：每局重掷脚本陪练死区 2~8°/视距 260~470px")
    ap.add_argument("--best0", type=float, default=-1.0,
                    help="已知最优复合分comp(run9 起，win%+100×归因击杀/千t+20×技能事件)，"
                         "续训时守住 BEST 不被噪声快评覆盖")
    ap.add_argument("--finals", type=int, default=-1, choices=(-1, 0, 1),
                    help="终局协议(run14)：-1=iters≥300自动 / 1=强制 / 0=禁用")
    ap.add_argument("--obsv2", action="store_true",
                    help="run15：道具观测改(近因衰减,方位cos,方位sin,类型)；"
                         "续训/评估/探针会自动跟权重里的 obsv2 标记")
    ap.add_argument("--obsv3", action="store_true",
                    help="run23 预铺：观测尾追加 12 维弹道 CPA 特征"
                         "(6 槽×(latN,τN))，90→102 列；90 列旧档自动补零"
                         "暖启动。权重带 obsv3 标记自动对齐")
    ap.add_argument("--fire-floor", type=float, default=4.0,
                    help="finals 开火地板(会话51)：候选双池合计开火/千t 低于此值"
                         "不得登基（run18 神龟和=62 但火0.2 的教训；"
                         "14champ 双池火 8~10/千t，地板取其半）")
    ap.add_argument("--dodge-floor", type=float, default=0.0,
                    help="finals 躲弹闸门(run22)：过火闸候选双池合计 受击暴露/千t"
                         " 高于此值不得登基（主躲率实测被逃跑策略刷高无区分力，"
                         "改用交战归一的暴露口径；14champ≈0.56；0=关）")
    ap.add_argument("--width", type=int, default=128,
                    help="run19 预铺：隐层宽度（90->W->W->36）。仅 init_nn 生效，"
                         "消费方全部按 npz 形状反推；蒸馏侧由 gen_rlbot_data "
                         "写入 inc/rlw_cfg.inc 的 RL_HW 进 asm")
    a = ap.parse_args()
    H = a.width            # 模块级赋值即改全局（init_nn 调用期读取）
    if getattr(a, "obsv2", False):
        OBS_V2 = True
    if getattr(a, "obsv3", False):
        apply_obsv3(True)
    if a.eval_only:
        pd = dict(np.load(a.init)) if a.init else None
        eval_greedy(a.envs, a.rounds, opp=a.opp, pdict=pd)
    else:
        train(a.iters, a.envs, a.steps, opp=a.opp, lr=a.lr, best0=a.best0,
              opp_var=a.opp_var, finals=a.finals, fire_floor=a.fire_floor,
              dodge_floor=a.dodge_floor,
              init=(os.path.join(ROOT, a.init) if a.init else None))
