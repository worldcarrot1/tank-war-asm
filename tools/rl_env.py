# -*- coding: utf-8 -*-
# ============================================================
# rl_env.py —— 会话47：RL 训练环境 Python 驱动（管道版）
# 64 位 Python 载不动 x86 的 tankwar_rl.dll，故用 tankwar.exe 的
# rlhost 模式（src/rlhost.asm）当环境进程：stdin 发 64B 定长请求，
# stdout 收回 SNAP 快照。一个进程=一个环境，多进程即并行采样。
# 协议帧表与 META 字段序以 src/rlhost.asm 注释为唯一权威，本文件
# 启动时做尺寸断言，结构漂移立刻报错而不是静默读错。
# ============================================================
import os, struct, subprocess, time

EXE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tankwar.exe"))
CREATE_NO_WINDOW = 0x08000000

CMD_RESET, CMD_STEP, CMD_PING, CMD_META = 1, 2, 3, 4
FLAG_MANUAL2 = 1 << 0          # slot1 也归 Python（自博弈/评估用）
FLAG_SWAP = 1 << 1             # 会话47C：换位——slot0=启发式 bot、slot1=主机（BC 标签源）
RLMETAVER = 3                  # 帧尾带 24 dword 电平的协议版本（src/rlhost.asm）

KEYS = ("fwd", "back", "ccw", "cw", "fire", "skill")   # 与 inputTable 槽序一致


class TankEnv:
    """单个游戏逻辑环境。act 传 6 元组(0/1)，rep=动作重复 tick 数。"""

    def __init__(self, exe=None):
        self.manual2 = False
        self.flags = 0
        # 会话47 Phase3：RLHOST_EXTRA 环境变量附加命令行子串（如 "rlbot
        # rlbotdump"）——训练管内启用 NN 蒸馏网络并落盘，供 obs 对拍。
        extra = os.environ.get("RLHOST_EXTRA", "").split()
        self.p = subprocess.Popen(
            [exe or EXE, "rlhost"] + extra,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW)
        self._handshake()

    # ---- 底层帧 ----
    def _send(self, cmd, flags=0, aux=0, act0=(0,)*6, act1=(0,)*6):
        if len(act0) != 6 or len(act1) != 6:
            raise ValueError("act 必须是 6 元素")
        frame = struct.pack("<4BI6i6i8x", cmd, flags, 0, 0, aux & 0xFFFFFFFF,
                            *act0, *act1)
        assert len(frame) == 64
        self._last = (cmd, flags, aux)          # 会话48：EOF 现场记录
        self._wbytes = getattr(self, "_wbytes", 0) + 64
        self.p.stdin.write(frame)
        self.p.stdin.flush()

    def _recv_exact(self, n):
        buf = self.p.stdout
        out = bytearray()
        while len(out) < n:
            chunk = buf.read(n - len(out))
            if not chunk:
                import time
                rc = self.p.poll()
                for _ in range(6):              # 会话48取证：exit 与 poll 有竞态，
                    if rc is not None:          # 落定 0.5s 再取真退出码
                        break
                    time.sleep(0.08)
                    rc = self.p.poll()
                tag = "?" if rc is None else "0x%08X" % (rc & 0xFFFFFFFF)
                raise RuntimeError(
                    "环境进程退出（管道EOF rc=%s last=%s wbytes=%d want=%d got=%d）"
                    % (tag, getattr(self, "_last", None),
                       getattr(self, "_wbytes", 0), n, len(out)))
            out += chunk
        self._rbytes = getattr(self, "_rbytes", 0) + n
        return bytes(out)

    def _handshake(self):
        self._send(CMD_META)
        m = struct.unpack("<64I", self._recv_exact(256))
        (self.snap_total, self.tank_sz, self.bul_sz, self.off_tanks,
         self.off_bullets, self.off_map, self.COLS, self.ROWS, self.CELL,
         self.MAP_W, self.MAP_H, self.MAX_BULLETS, self.MAX_PLAYERS,
         self.KEY_PER, self.TILE_EMPTY, self.TILE_BRICK, self.TILE_STEEL,
         self.TILE_WATER, self.TILE_ICE, self.TILE_DIRT, self.TANK_HP) = m[:21]
        tnames = ("x y subpxX subpxY dir hp alive fireCd slide sdir score "
                  "skill effOn shieldT effT wallPass swapBul aimT aimSkill "
                  "lastCell phantomX phantomY phantomUses lives respawnT "
                  "protT spawnX spawnY spawnDir").split()
        bnames = "x y vx vy owner active bounces age subpxX subpxY fireAng".split()
        self.tank_off = dict(zip(tnames, m[21:21 + len(tnames)]))
        self.bul_off = dict(zip(bnames, m[50:50 + len(bnames)]))
        self.BULLET_FP = m[62] if len(m) > 62 else 0
        self.FIX_ONE = m[63] if len(m) > 63 else 0
        self.meta_ver = m[61]
        assert self.meta_ver >= RLMETAVER, \
            f"rlMetaVer={self.meta_ver} 过旧：应答帧尾无 24dword 电平（重编译 rlhost.asm）"
        assert self.tank_sz == 4 * (len(tnames)), "TANK 成员数与 META 不符"
        assert self.bul_sz == 4 * (len(bnames) + 0), "BULLET 尺寸漂移"
        assert self.snap_total == (self.off_map + self.COLS * self.ROWS)
        self.frame_len = self.snap_total + self.MAX_PLAYERS * self.KEY_PER * 4
        # 单词偏移→dword 索引表（快照解析用）
        self.tank_dw = {k: v // 4 for k, v in self.tank_off.items()}
        self.bul_dw = {k: v // 4 for k, v in self.bul_off.items()}

    # ---- gym 接口 ----
    def reset(self, seed=0, manual2=False, swap=False, aggro=False):
        self.manual2 = manual2
        self.flags = (FLAG_SWAP if swap else (FLAG_MANUAL2 if manual2 else 0))
        if aggro:                       # 会话50：bit2=启发式陪练激进化
            self.flags |= 4
        self._send(CMD_RESET, self.flags, seed & 0xFFFFFFFF)
        return self._snap()

    def step(self, act0, rep=1, act1=None):
        a1 = tuple(act1) if act1 else (0,) * 6
        self._send(CMD_STEP, self.flags, rep, tuple(act0), a1)
        return self._snap()

    def ping(self):
        self._send(CMD_PING)
        return self._snap()

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        self.p.wait(timeout=5)

    # ---- 快照解析 ----
    def _snap(self):
        raw = self._recv_exact(self.frame_len)
        hdr = struct.unpack("<14I", raw[:56])
        tw, bw = self.tank_sz // 4, self.bul_sz // 4
        tanks = [struct.unpack("<%dI" % tw,
                  raw[self.off_tanks + i*self.tank_sz:][:self.tank_sz])
                 for i in range(4)]
        bullets = [struct.unpack("<%dI" % bw,
                  raw[self.off_bullets + i*self.bul_sz:][:self.bul_sz])
                   for i in range(self.MAX_BULLETS)]
        grid = raw[self.off_map:self.off_map + self.COLS*self.ROWS]
        levels = struct.unpack("<%dI" % (self.MAX_PLAYERS*self.KEY_PER),
                               raw[self.snap_total:self.frame_len])
        s = dict(zip(
            ("tick", "rngMatch", "mapIndex", "matchOver", "roundsPlayed",
             "maxRounds", "pickupType", "pickupX", "pickupY", "pickupTimer",
             "botMask", "rngState"), hdr[1:13]))
        s["hdr"] = hdr
        s["tanks"] = tanks
        s["bullets"] = bullets
        s["map"] = grid
        s["levels"] = levels          # 会话47C：本 tick 实际生效电平（BC 标签）
        return s

    def tv(self, snap, slot, field):
        """取某槽坦克字段（按 META 名，不数偏移）。"""
        return snap["tanks"][slot][self.tank_dw[field]]

    def alive(self, snap, slot):
        return self.tv(snap, slot, "alive")


if __name__ == "__main__":
    import sys, random
    def show(tag, env, s):
        x0, y0 = env.tv(s, 0, "x"), env.tv(s, 0, "y")
        x1, y1 = env.tv(s, 1, "x"), env.tv(s, 1, "y")
        print(f"{tag}: tick={s['tick']} map={s['mapIndex']} "
              f"rngMatch={s['rngMatch']:08x} P0=({x0},{y0}) "
              f"P1=({x1},{y1}) MO={s['matchOver']}")

    print("== 冒烟1：META 握手 ==")
    e = TankEnv()
    print(f"tank_sz={e.tank_sz} bul_sz={e.bul_sz} snap={e.snap_total} "
          f"grid={e.COLS}x{e.ROWS} off(t,b,m)=({e.off_tanks},{e.off_bullets},{e.off_map})")
    e.close()

    def run_fixed(seed, n=300):
        env = TankEnv()
        rnd = random.Random(999)
        s = env.reset(seed=seed)
        for _ in range(n):
            a = [rnd.randint(0, 1) for _ in range(6)]
            s = env.step(a, rep=1)
        sig = (s["tick"], env.tv(s, 0, "x"), env.tv(s, 0, "y"),
               env.tv(s, 1, "x"), env.tv(s, 1, "y"),
               env.tv(s, 1, "dir"), s["pickupType"], s["roundsPlayed"])
        env.close()
        return sig, env

    print("== 冒烟2：确定性（同 seed 两次全轨迹）==")
    sigA, envA = run_fixed(123456)
    sigB, envB = run_fixed(123456)
    print("A:", sigA); print("B:", sigB)
    assert sigA == sigB, "非确定！"
    sigC, _ = run_fixed(654321)
    assert sigA != sigC, "不同 seed 竟同终态？"
    print("确定性 PASS")

    print("== 冒烟3：吞吐（单步往返 / rep=20 批步）==")
    env = TankEnv()
    env.reset(seed=7)
    t0 = time.perf_counter()
    for _ in range(2000):
        env.step((1, 0, 0, 0, 0, 0), rep=1)
    dt = time.perf_counter() - t0
    print(f"单步: {2000/dt:,.0f} ticks/s (含帧往返)")
    t0 = time.perf_counter()
    for _ in range(200):
        env.step((1, 0, 0, 0, 0, 0), rep=20)
    dt2 = time.perf_counter() - t0
    print(f"rep20: {4000/dt2:,.0f} ticks/s")
    show("末帧", env, env.ping())
    env.close()
    print("SMOKE ALL PASS")
