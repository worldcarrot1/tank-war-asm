# Tank War ASM —— 坦克大战（汇编 + 局域网对战）

用 x86 汇编（MASM32）编写的坦克大战，支持局域网 UDP 联机对战。
项目目标：以最小的游戏复杂度验证「汇编游戏引擎 + UDP 状态同步」的完整链路，
为后续做《森林冰火人》等更复杂的联机游戏打下引擎基础。

## 技术选型

| 项 | 选择 | 说明 |
|----|------|------|
| 语言 | x86 汇编 (MASM) | `ml.exe` 汇编，32 位 Win32 API |
| 渲染 | GDI（内存 DC + BitBlt） | 无需 DirectX，逻辑清晰，够画网格地图和弹幕 |
| 网络 | Winsock2 UDP | `sendto` / `recvfrom`，每 tick 交换状态包 |
| 架构 | P2P（无服务器） | 局域网内 UDP 广播发现对方，直连对战 |
| 节奏 | 固定 60 tick/秒 | 逻辑与渲染分离，同步确定性优先 |

## 目录结构

```
tank-war-asm/
├── src/
│   ├── main.asm      # 入口：WinMain、消息循环、主循环（逻辑/渲染分离）
│   ├── gfx.asm       # 渲染：GDI 内存 DC、地图、坦克、子弹绘制
│   ├── input.asm     # 输入：键盘状态采样（WASD + 空格开火）
│   ├── game.asm      # 逻辑：坦克/子弹状态、碰撞检测、胜负判定
│   ├── ui.asm        # 界面：主菜单/设置/改键/联机大厅/成就图鉴状态机与绘制
│   ├── bot.asm       # 黑色超强人机 AI（会话38 起；会话44 效用评分决策，纯确定性、botMask 门控）
│   ├── achv.asm      # 成就系统（会话40/41：24 条×4 品阶、事件匹配、achv.dat v2 持久化+解锁日期）
│   └── net.asm       # 网络：Winsock 初始化、UDP 收发、状态包编解码
├── inc/
│   ├── game.inc      # 公共常量与结构体定义（坦克、子弹、网络包格式）
│   ├── achvicons.inc # 成就图标位表（会话45：game-icons CC BY 3.0，tools/raster45.py 生成）
│   └── sfxdata.inc   # CC0 音效采样位表（会话43，tools/gen_sfx43.py 生成）
├── server/
│   └── relay_server.c # 自建 UDP 中继服务器（会话37 M3.5，Win/Linux 单文件）
├── docs/
│   ├── ROADMAP.md    # 开发路线图（分阶段，每阶段可验证）
│   └── PROTOCOL.md   # 网络协议设计（包格式、同步策略）
├── build.bat         # 一键汇编 + 链接
├── build_server.bat  # 编译中继服务器（产出 relay_server.exe）
└── README.md
```

## 构建要求

1. 安装 Visual Studio（勾选「使用 C++ 的桌面开发」，含 MASM `ml.exe` 与 `link.exe`）
2. 双击运行 `build.bat`（自动通过 vswhere 定位工具链），生成 `tankwar.exe`
3. 不需要 MASM32 SDK——项目自带精简版 `inc/win32.inc` API 定义

## 玩法

- 移动：WASD（撞墙不动，转向即时生效）
- 开火：空格（约 0.33s 冷却），砖墙可打掉，钢墙挡子弹
- 命中对方坦克扣血，血量归零判负；按 R 重新开始
- 联机：双人 UDP 直连（协议 v1.1，已实测）——主菜单「联机大厅」局域网自动
  互发现，跨网/互联网在「手动连接」输对方 IP（配合 ZeroTier 等虚拟局域网），
  或在任意公网机器跑 `relay_server` 后输 `服务器IP:28900#房间号` 走**自建中继**
  （跨任意 NAT 含对称型）；实操见 [docs/ONLINE_PLAY.md](docs/ONLINE_PLAY.md)，
  协议规格见 [docs/PROTOCOL.md](docs/PROTOCOL.md)（联机模式不含换位术/定格虚影）
- **黑色人机**（会话38/42/44）：命令行 `tankwar bot` 直开挑战局，或在「开始游戏」人数
  选择页把空位补为 AI——主菜单已按要求移除专属入口（会话42）。黑色 AI 坦克，
  速度/转向/射速全面超标，血量与玩家相同（1 命）。会话44 起决策为**效用评分**
  （移植 Wesnoth 微 AI 候选动作打分的纯整数版）：目标按真人/视线/距离/威胁来源择优
  （带迟滞防乒乓，会反击"刚打到自己的人"），驾驶朝向在 17 个候选里按"主航向+敌弹
  威胁场+防抖锚"评分 argmax——侧移躲弹的同时不丢瞄准线；绕墙、抢技能道具并择时释放
  （激光等远距放长束或穿墙狙），近距离必射；本地独占，进联机大厅自动退出
- **音效**（会话43）：18 个音效全部为**内嵌 CC0 真实采样**——Juhani Junkala《The Essential
  Retro Video Game Sound Effects Collection [512 sounds]》（opengameart.org，CC0 公共领域），
  转成 22050Hz/8-bit WAV 镜像编入 exe（`inc/sfxdata.inc`，`tools/gen_sfx43.py` 生成），
  开炮=重炮、爆炸=短爆、拾取=金币、成就=三档号角+传奇开机音；BGM 仍为程序化八音盒
- **成就系统**（会话40/41/45）：24 条成就分 普通(6)/稀有(7)/史诗(6)/传奇(5) 四品阶（灰/蓝/紫/金），
  每条自带 24px 像素图标（会话45：图鉴行 icon+底色 chip、页眉品阶徽标、解锁横幅左图标，
  来源 [game-icons.net](https://game-icons.net/)，CC BY 3.0，署名见下条）；
  解锁即时品阶号角（四档音色）并弹出横幅（品阶色描边、滑入-驻留-滑出、约 4s 自隐，会话42 去末段闪烁），
  进度+解锁日期落盘 `achv.dat`（v2 格式，旧 v1 档自动迁移）跨重启保留；
  主菜单「成就图鉴」6 行×4 整页随意翻阅（←→/箭头钮/Esc/数字键 1-4 与 Home/End 直跳页），
  页眉四枚品阶徽章 n/总数、全收集金色标题，已达成项显示日期，有新解锁时菜单入口标「（新）」；
  联机仅己方计分，bot 击杀不刷计数
- **成就图标署名**：图标为 [game-icons/icons](https://github.com/game-icons/icons) 仓库
  SVG（站点 [game-icons.net](https://game-icons.net/)，**CC BY 3.0**，署名即此条），
  作者按仓库目录归属 lorc / delapouite / skoll / badges；经 `tools/pick45.py`（选品，
  顺序=图鉴行序）+ `tools/raster45.py`（自研纯 Python SVG 扫描线栅格器，无第三方依赖）
  转成 `inc/achvicons.inc` 24×24 四级覆盖字节表。选品清单：gunshot、skull、snowflake-1、
  fire-dash、droplet-splash、open-treasure-chest、crosshair、shield-impact、land-mine、
  ghost、crossed-swords、laser-blast、whirlwind、pentacle、laurel-crown、sport-medal、
  body-swapping、mine-explosion、globe、vintage-robot、compass、meat-cleaver、circle、
  minigun（成就 24 件）+ star、cut-diamond、templar-shield、imperial-crown（品阶徽标 4 件）

## 开发路线

见 [docs/ROADMAP.md](docs/ROADMAP.md)。当前进度：**M1（v2 对战版）完成，
双人联机（协议 v1.1，含自建 UDP 中继 M3.5）已落地实测**。
