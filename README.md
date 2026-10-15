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
│   └── net.asm       # 网络：Winsock 初始化、UDP 收发、状态包编解码
├── inc/
│   └── game.inc      # 公共常量与结构体定义（坦克、子弹、网络包格式）
├── docs/
│   ├── ROADMAP.md    # 开发路线图（分阶段，每阶段可验证）
│   └── PROTOCOL.md   # 网络协议设计（包格式、同步策略）
├── build.bat         # 一键汇编 + 链接
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
- 联机：局域网 UDP 直连（阶段 3 实现，当前为单机/等待联机状态）

## 开发路线

见 [docs/ROADMAP.md](docs/ROADMAP.md)。当前进度：**阶段 0 —— 工程骨架已建立**。
