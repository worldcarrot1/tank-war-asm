# -*- coding: utf-8 -*-
# ============================================================
# rl_server.py —— 会话47D：实时对战数据服务（录制 + 直播分析）
# 客户端在游戏里：`tankwar.exe rlrec [ip:port]` 正常开窗口对战，
# 每逻辑 tick 推一枚 UDP 帧（SNAP 3573B + inputTable 4×6 dword，
# 布局与 rlhost 管道应答逐字节同构，src/rlhost.asm 为唯一权威）。
# 本服务三件事，一件比一件显眼：
#   ① 原样落盘 .rlrec —— 离线 tools/rl_rec_extract.py → obs/act
#      数据集 → 行为克隆/风格复盘（真人对局是 GitHub 上买不到的数据）
#   ② 逐帧解码 —— 双方 HP/比分/击杀/开火/中弹/极限躲弹/技能发动
#      与命中/瞄准占比，终端每秒实况（能力口径与 rl_train.py Cap 一致）
#   ③ 浏览器实况面板 rl_server_status.html（2s 自动刷新）+ 退出时
#      落 rl_server_stats.json 能力总表
# 用法：python tools/rl_server.py [--port 51777] [--listen 0.0.0.0]
#                                [--out live_*.rlrec] [--html 路径]
#                                [--no-html]
# ============================================================
import os, sys, time, math, json, socket, struct, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rl_env import TankEnv

# MASM 多字符常量首字符在高字节：'RLS1' dword=0x524C5331，内存 LE 布局：
MAGIC = struct.pack("<I", 0x524C5331)   # == b"1SLR"，勿按字面字符串比

# ---- 能力判定阈值（与 rl_train.py Cap 同源同值）----
NEAR = 40.0        # 擦身闪避半径(px)
HIT_BURN = 30.0    # 中弹 tick 销账半径(px)：小于此的在飞弹头记为命中弹
SK_WIN = 40        # 技能→伤害归因窗口(tick)
KILL_R = 34.0      # 击杀归因半径：自弹与受害方角点差(弹池须查上一帧)
AIM_T = 12.0       # 瞄准角带(°)
AIM_D = 430.0      # 索敌距(px)


class SlotStat:
    def __init__(self):
        self.hp = self.alive = self.score = 0
        self.shots = self.kills = self.deaths = self.hits = self.dodges = 0
        self.scav = 0                      # 捡漏击杀（对方自雷致死，未归因）
        self.sk_act = self.sk_hit = self.sk_grab = 0
        self.aim_t = self.live_t = 0
        self.sk_t = -10**9

    def rates(self, ticks):
        k = 1000.0 / max(ticks, 1)
        dg = self.dodges + self.hits
        return (f"枪{self.shots * k:.0f}/千t 杀{self.kills}捡{self.scav} 亡{self.deaths} "
                f"中弹{self.hits} 躲{self.dodges}({100.0 * self.dodges / max(dg, 1):.0f}%) "
                f"技{self.sk_grab}拾{self.sk_act}发{self.sk_hit}中 "
                f"瞄{100.0 * self.aim_t / max(self.live_t, 1):.0f}%")


class Analyzer:
    """逐帧解码统计。本地对局常规只用槽 0/1（PvP/人机同构）。"""

    def __init__(self, probe):
        self.ns = probe.MAX_PLAYERS
        self.tdw, self.tw = probe.tank_dw, probe.bul_dw
        self.slots = [SlotStat() for _ in range(self.ns)]
        self.mind = [[1e18] * probe.MAX_BULLETS for _ in range(self.ns)]
        self.ticks = self.pick_t = 0
        self.tick = self.map = 0
        self.prev = None
        self.prev_bullets = None
        self._bullets = []

    def attach_bullets(self, bullets):
        self._bullets = bullets

    def _gun_hit(self, owner, vx, vy, bullets):
        """会话47E：本 tick 或上一 tick 弹池中是否有 owner 的活动弹与受害方
        命中盒重叠（引擎命中同 tick 销毁子弹，单帧池会漏判，与训练侧
        own_gun_hit 同构）。"""
        tw = self.tw
        pools = [p for p in (self.prev_bullets, bullets) if p]
        for pl in pools:
            for b in pl:
                if b[tw["active"]] and b[tw["owner"]] == owner \
                        and math.hypot(b[tw["x"]] - vx, b[tw["y"]] - vy) < KILL_R:
                    return True
        return False

    def update(self, hdr, tanks, acts):
        tdw, tw = self.tdw, self.tw
        self.tick = hdr[1]
        self.map = hdr[3]
        self.ticks += 1
        if hdr[7] > 0:                       # pickupType：道具在场时长统计
            self.pick_t += 1
        prev = self.prev
        if prev is None:                    # 首帧只建档不结算
            for i, s in enumerate(self.slots):
                s.alive, s.hp, s.score = (tanks[i][tdw["alive"]],
                                          tanks[i][tdw["hp"]],
                                          tanks[i][tdw["score"]])
            self.prev = tanks
            return
        bullets = self._bullets
        for i, s in enumerate(self.slots):
            t, pt = tanks[i], prev[i]
            a, pa = t[tdw["alive"]], pt[tdw["alive"]]
            s.alive, s.hp, s.score = a, t[tdw["hp"]], t[tdw["score"]]
            hit = bool(pa and t[tdw["hp"]] < pt[tdw["hp"]])
            if hit:
                s.hits += 1
            if pa and not a:
                s.deaths += 1
            x, y = t[tdw["x"]], t[tdw["y"]]
            # 技能链（inc/game.inc：skill=持有待发动 SK_ id，引擎消费即 0）
            if pt[tdw["skill"]] == 0 and t[tdw["skill"]] > 0:
                s.sk_grab += 1                       # 拾到技能道具
            if pt[tdw["skill"]] > 0 and t[tdw["skill"]] == 0:
                s.sk_act += 1
                s.sk_t = self.tick
            if i < 2:
                o = 1 - i
                ot, opt = tanks[o], prev[o]
                # 会话47E：伤害 tick 双证归因（与训练 Cap 同口径）——
                # 自弹重叠命中盒 或 技能发动窗口内；致死记杀、否则记捡漏。
                if opt[tdw["alive"]] and ot[tdw["hp"]] < opt[tdw["hp"]]:
                    gun = self._gun_hit(i, ot[tdw["x"]], ot[tdw["y"]], bullets)
                    skd = self.tick - s.sk_t <= SK_WIN
                    if skd:
                        s.sk_hit += 1
                        s.sk_t = -10**9
                    if not ot[tdw["alive"]]:
                        if gun or skd:
                            s.kills += 1
                        else:
                            s.scav += 1
                elif opt[tdw["alive"]] and not ot[tdw["alive"]]:
                    s.scav += 1
                if a and ot[tdw["alive"]]:
                    s.live_t += 1
                    dx, dy = ot[tdw["x"]] - x, ot[tdw["y"]] - y
                    if math.hypot(dx, dy) < AIM_D:
                        tgt = math.degrees(math.atan2(dy, dx)) % 360
                        err = (tgt - t[tdw["dir"]] % 360 + 180) % 360 - 180
                        if abs(err) < AIM_T:
                            s.aim_t += 1
            # 弹池记账：开火(age==1 恰一帧)/极限躲弹/中弹销账
            for bi, b in enumerate(bullets):
                if not b[tw["active"]]:
                    if self.mind[i][bi] < NEAR and not hit:
                        s.dodges += 1
                    self.mind[i][bi] = 1e18
                    continue
                if b[tw["owner"]] == i:
                    if b[tw["age"]] == 1:
                        s.shots += 1
                    continue
                d = math.hypot(b[tw["x"]] - x, b[tw["y"]] - y)
                if d < self.mind[i][bi]:
                    self.mind[i][bi] = d
            if hit:
                for bi, b in enumerate(bullets):
                    if b[tw["active"]] and self.mind[i][bi] < HIT_BURN:
                        self.mind[i][bi] = 1e18
        # 击杀归因已并入上方逐槽"双证归因"块（会话47E，与训练 Cap 同口径）
        self.prev = tanks
        self.prev_bullets = bullets


def html_page(an, addr, n_frames, lost, out_path, t0):
    el = time.time() - t0
    k = 1000.0 / max(an.ticks, 1)
    names = ("P1(蓝方)", "P2(红方)", "P3", "P4")
    rows = []
    for i, s in enumerate(an.slots):
        if i >= 2:
            continue
        dg = s.dodges + s.hits
        rows.append(
            f"<tr><td>{names[i]}</td><td>{s.hp}</td>"
            f"<td>{'存活' if s.alive else '—'}</td><td>{s.score}</td>"
            f"<td>{s.shots * k:.1f}</td><td>{s.kills}/{s.scav}</td><td>{s.deaths}</td>"
            f"<td>{100.0 * s.dodges / max(dg, 1):.0f}% ({s.dodges}/{dg})</td>"
            f"<td>{s.sk_grab} / {s.sk_act} / {s.sk_hit}</td>"
            f"<td>{100.0 * s.aim_t / max(s.live_t, 1):.0f}%</td></tr>")
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="2"><title>坦克大战 实况数据台</title>
<style>
body{{background:#101418;color:#dfe6ee;font-family:Consolas,monospace;margin:24px}}
h1{{font-size:20px}} table{{border-collapse:collapse;margin-top:12px}}
td,th{{border:1px solid #2c3a47;padding:6px 14px;text-align:right}}
th{{background:#18222c;color:#7fd1b9}} .m{{color:#8aa3b8;font-size:13px}}
b.go{{color:#7fd1b9}}
</style></head><body>
<h1>⬤ rlrec 实时数据台 <span class="m">源 {addr[0]}:{addr[1]} · tick {an.tick} ·
已解码 {an.ticks} 帧 · 收帧 {n_frames} · 丢帧~{lost} ·
录制 {os.path.basename(out_path)}</span></h1>
<table><tr><th>槽</th><th>HP</th><th>状态</th><th>回合分</th><th>开火/千tick</th>
<th>击杀/捡漏</th><th>阵亡</th><th>极限躲弹率</th><th>技能 拾/发/中</th><th>瞄准占比</th></tr>
{''.join(rows)}</table>
<p class="m">口径与训练管线 rl_train.py Cap 完全一致。对局结束后可直接
<b class="go">python -I tools/rl_rec_extract.py {out_path}</b>
转 obs/act 数据集，回灌行为克隆/风格对照。</p>
<p class="m">本页 2 秒自动刷新 · 运行 {el:.0f}s · {time.strftime('%H:%M:%S')}</p>
</body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=51777)
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--out", default=time.strftime("live_%Y%m%d_%H%M%S.rlrec"))
    ap.add_argument("--html", default="rl_server_status.html")
    ap.add_argument("--json", default="rl_server_stats.json")
    ap.add_argument("--no-html", action="store_true")
    a = ap.parse_args()

    print("读取布局表（借 rlhost 进程做一次 META 握手）...", flush=True)
    probe = TankEnv()                       # 只为拿 META，立刻关闭
    probe.close()
    total = probe.snap_total
    in_len = total + probe.MAX_PLAYERS * probe.KEY_PER * 4
    print(f"帧长 {in_len}B（snap {total} + 输入 {in_len - total}）", flush=True)

    sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sk.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sk.bind((a.listen, a.port))
    print(f"监听 udp://{a.listen}:{a.port}  →  {a.out}", flush=True)
    print("游戏侧启动：tankwar.exe rlrec   （或 rlrec:192.168.x.x:51777）", flush=True)

    an = Analyzer(probe)
    bw = probe.tank_sz // 4
    fh = open(a.out, "wb")
    n = lost = 0
    last_tick = -1
    t_start = time.time()
    last_report = last_html = 0.0
    addr = ("-", 0)
    try:
        while True:
            data, addr = sk.recvfrom(65536)
            if len(data) != in_len or data[:4] != MAGIC:
                lost += 1
                continue
            hdr = struct.unpack_from("<14I", data)
            tanks = [struct.unpack_from("<%dI" % bw, data,
                     probe.off_tanks + i * probe.tank_sz)
                     for i in range(probe.MAX_PLAYERS)]
            bullets = [struct.unpack_from("<%dI" % (probe.bul_sz // 4), data,
                       probe.off_bullets + i * probe.bul_sz)
                       for i in range(probe.MAX_BULLETS)]
            acts = struct.unpack_from("<%dI" % (probe.MAX_PLAYERS * probe.KEY_PER),
                                      data, total)
            tick = hdr[1]
            if last_tick >= 0 and tick > last_tick + 1:
                lost += tick - last_tick - 1
            last_tick = tick
            fh.write(data)
            n += 1
            an.attach_bullets(bullets)
            an.update(hdr, tanks, acts)
            now = time.time()
            if now - last_report >= 1.0:
                last_report = now
                s0, s1 = an.slots[0], an.slots[1]
                print(f"{now - t_start:6.1f}s pps={n / max(now - t_start, 1e-9):5.1f} "
                      f"tick={tick} map={hdr[3]} | "
                      f"P0 hp{s0.hp} 分{s0.score} [{s0.rates(an.ticks)}] | "
                      f"P1 hp{s1.hp} 分{s1.score} [{s1.rates(an.ticks)}] | "
                      f"丢帧~{lost} 源={addr[0]}", flush=True)
                fh.flush()
            if not a.no_html and now - last_html >= 2.0:
                last_html = now
                tmp = a.html + ".tmp"
                with open(tmp, "w", encoding="utf-8") as hf:
                    hf.write(html_page(an, addr, n, lost, a.out, t_start))
                os.replace(tmp, a.html)
    except KeyboardInterrupt:
        pass
    except Exception:
        import traceback
        traceback.print_exc()          # 会话47B：静默退过一次，必须留痕
    finally:
        fh.close()
        summary = dict(frames=n, lost=lost, ticks=an.ticks,
                       seconds=round(time.time() - t_start, 1),
                       rlrec=os.path.abspath(a.out),
                       slots=[vars(s) for s in an.slots])
        try:
            with open(a.json, "w", encoding="utf-8") as jf:
                json.dump(summary, jf, ensure_ascii=False, indent=1)
        except OSError:
            pass
        print(f"\n收帧 {n}，丢帧~{lost}，已写 {a.out}")
        print(f"能力总表 → {a.json}")
        print(f"离线转训练集：python -I tools/rl_rec_extract.py {a.out}")


if __name__ == "__main__":
    main()
