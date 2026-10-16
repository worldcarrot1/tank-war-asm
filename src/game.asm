; ============================================================
; game.asm —— 游戏逻辑核心（GAME_DESIGN v2 / 里程碑 M1）
; 职责：
;   - 字符画对战地图解析（ARENA1..5，运行时随机选图）
;   - 砖墙 2x2 子块破坏（brickMask 每格 4 bit）
;   - 反弹子弹物理：钢/砖/屏幕边界反弹，水/冰/空地穿过
;   - 水域挡坦克、冰面滑行 6~10 tick
;   - 本地双坦克（P1: WASD+空格 / P2: 方向键+Enter）
; 确定性约定（联机地形事件依赖）：
;   - 子弹每 tick 固定顺序：age -> X 轴(边界->地形) -> Y 轴(边界->地形) -> 坦克命中
;   - 地形四角采样顺序固定：TL, TR, BR, BL，命中即返回
;   - 坦克命中遍历顺序固定：slot 0..MAX_PLAYERS-1
; ============================================================

.386
.model flat, stdcall
option casemap:none

include win32.inc
include game.inc

GameUpdate PROTO                   ; 同模块前向声明（自测助手先用后定义）
TileAtPx  PROTO :DWORD,:DWORD      ; 同模块前向声明
IsWallCell   PROTO :DWORD,:DWORD   ; 同模块前向声明
WallRects    PROTO :DWORD,:DWORD,:DWORD
WallRectsHit PROTO :DWORD,:DWORD,:DWORD,:DWORD
TankBlocked  PROTO :DWORD,:DWORD

; ---- 输入快照（本模块定义，input.asm / ui.asm 写入）----
public keyTable
public inputTable
public inputRestart
extern numPlayers :dword               ; ui.asm（当前玩家数 2..4）

; ---- 游戏状态（本模块定义，gfx.asm / net.asm 读取）----
public tanks
public bullets
public mapData
public mapIndex
public SpawnBullet
public GameInit
public GameUpdate
public WallRects                   ; gfx.asm 渲染细挡板共用
public fireHappened
public seqSelf
public SelfTestRun
public InitKeyDefaults

.data
    tanks       TANK MAX_PLAYERS dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)
    spawnX      dd 4 dup (0)         ; 出生点像素坐标（字符画 'S'）
    spawnY      dd 4 dup (0)
    spawnCount  dd 0
    mapIndex    dd 0                 ; 当前 ARENA 编号
    keyTable    dd MAX_PLAYERS*5 dup (0)   ; [slot*5+动作] VK 码: 0上1下2左3右4开火
    inputTable  dd MAX_PLAYERS*5 dup (0)   ; [slot*5+动作] 每 tick 快照 0/1
    inputRestart dd 0                      ; R 重开（固定键）
    roundOver   dd 0                 ; 回合结束定格中
    roundTimer  dd 0                 ; 定格剩余 tick
    roundScored dd 0                 ; 本回合已判分
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick P1 是否开火（发包 flag 用）
    rngState    dd 0                 ; xorshift32 状态

; ---- 字符画对战地图（20x15 字符/张，编译期嵌入）----
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  S 出生点
; ---- 字符画对战地图（31x20，tools/gen_wide_maze.py 生成）----
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水(3x3)  - 冰(走廊宽条)  d 泥土(减速)  S 出生点
; ---- 字符画对战地图（31x20，tools/gen_wide_maze.py v4 生成）----
; 1 格走廊复杂迷宫 + 开阔广场（冰/泥整场、水 3x3 居中带走道）
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰广场  d 泥广场  S 出生点
; ---- 字符画对战地图（31x20，tools/gen_wide_maze.py v5 生成）----
; 细粒度不对称复杂迷宫 + 分散小广场（冰/泥整块、水 3x3，均留走道不贴墙）
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  d 泥土  S 出生点
; ---- 字符画对战地图（31x20，tools/gen_wide_maze.py v6 生成）----
; 不对称复杂迷宫 + 12 块分散环境（4 水 3x3 / 4 冰 / 4 泥，均留走道不贴墙）
; 字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  d 泥土  S 出生点
; ---- 字符画对战地图（31x19，tools/gen_wide_maze.py v6 生成）----
; 不对称复杂迷宫 + 12 块分散环境（4 水 3x3 / 4 冰 / 4 泥，均留走道不贴墙）
; 单行底边界（奇数行）；字符表：. 空地  # 钢墙  b 砖墙  ~ 水  - 冰  d 泥土  S 出生点
ARENA1 db "###############################"
       db "#S..................#........S#"
       db "#....dd.#...###.....#.###.##..#"
       db "#....dd.b...#...--..#.#.....#.#"
       db "#.#..dd.#.#.#.b.--..#.b.###.b.#"
       db "#.#.....#.b...#.....#.#...#.#.#"
       db "###...###.....#...#.#.#.....#.#"
       db "#.....#....--.#...#.#...~~~...#"
       db "#.###.#.#..--.#.#.###.#.~~~.#.#"
       db "#.....#.#.......#.....#.~~~.#.#"
       db "#.#####.###...#.#b#.##b.....#.#"
       db "#.#.....#.....#.............#.#"
       db "#.###.b##.~~~.#..~~~..#....##.#"
       db "#...#.....~~~.b..~~~..#.dd....#"
       db "###.#.###.~~~.#..~~~..#.dd....#"
       db "#...#...#.....................#"
       db "#..##b###.#######...#b#.#.....#"
       db "#S........#.............#....S#"
       db "###############################"

ARENA2 db "###############################"
       db "#S........................#..S#"
       db "#..###b..---..#.---....dd.#...#"
       db "#.#...#..---..#.---....dd...#.#"
       db "#.#.#.b......#b.....##.dd...#.#"
       db "#...#...#.....#.............#.#"
       db "##.....##.....#.........#.###.#"
       db "#..~~~....~~~.#..ddd....#.....#"
       db "#..~~~..#.~~~.#..ddd.####.###.#"
       db "#..~~~..#.~~~.........#.#.....#"
       db "#......##.....##bb#.#.b.#...###"
       db "#.#.#...............#.........#"
       db "#.#.#...##.......--.#..~~~.##.#"
       db "#.......b..dd....--....~~~..#.#"
       db "#.###.###..dd....--.#b.~~~..#.#"
       db "#.............................#"
       db "#..##.#####.####b##.#b###.##..#"
       db "#S........................#..S#"
       db "###############################"

ARENA3 db "###############################"
       db "#S...........................S#"
       db "#....dd.########.~~~...--.#...#"
       db "#....dd.#........~~~...--.#...#"
       db "#.#..dd.#.#####..~~~......###.#"
       db "#.#.....#.....#...............#"
       db "#.#######......##.###.#.....#.#"
       db "#.......#..~~~........#.~~~.#.#"
       db "#.--..#.##.~~~..b.ddd.#.~~~.#.#"
       db "#.--..#....~~~..#.ddd.#.~~~...#"
       db "#....#####......#.....#.....#.#"
       db "#.....b.........#.....#.....#.#"
       db "#.###.#.#......b#.##b.....#.#.#"
       db "#.#...#.b..ddd......b..--.#.#.#"
       db "#.b...#.b#.ddd..b##.#..--.#.#.#"
       db "#.....#.#...........#.....#.#.#"
       db "#..##.#.#.###.###b#.#.#b###...#"
       db "#S..#...#...........#........S#"
       db "###############################"

ARENA4 db "###############################"
       db "#S..#...#.................#..S#"
       db "#...#.#.#.--.##.~~~.#b.--.#...#"
       db "#.#...#...--....~~~.#..--...#.#"
       db "#.#####......##.~~~.#..--.b##.#"
       db "#.............#.............#.#"
       db "#.##b##......b#.#####.#.#b#.#.#"
       db "#........~~~....#.....#.#.#.#.#"
       db "#.dd.###.~~~.####.###.#.b.#.#.#"
       db "#.dd.....~~~......#.....#.....#"
       db "#....##......b###.#...#######.#"
       db "#.............#.......#.......#"
       db "#.###b##......#...~~~.#..ddd..#"
       db "#.....#..---..#...~~~....ddd..#"
       db "#####.#..---.####.~~~.#b......#"
       db "#.....#.........b.....#...#...#"
       db "#..##b#...#####.#####.#.###...#"
       db "#S........#.............#....S#"
       db "###############################"

ARENA5 db "###############################"
       db "#S..#........................S#"
       db "#...#.#...~~~...~~~.....--....#"
       db "#.#...#...~~~...~~~.....--..#.#"
       db "#.#######.~~~...~~~.###.--..#.#"
       db "#...#.......................#.#"
       db "#.....#####.############b...#.#"
       db "#.~~~.#.....#...#...........#.#"
       db "#.~~~.#.#####.#.#.b########.#.#"
       db "#.~~~.#.#.....#.#.............#"
       db "#.....#.#.b####.###.b##...##b.#"
       db "#.#...#.......#.......#.......#"
       db "#.###.##.dd...##.ddd.##.--.##.#"
       db "#.....#..dd......ddd....--..#.#"
       db "#.#...#.....#.##............#.#"
       db "#.#...#.#...#.#...b.....#.#.b.#"
       db "#...###.#b#.b##.b.#.###.b.#...#"
       db "#S........#.....#.....#......S#"
       db "###############################"

ARENA6 db "###############################"
       db "#S......#.......#...#........S#"
       db "#....dd.#.~~~.b.#.#.#.b.###...#"
       db "#....dd...~~~.#...b.#.#.....#.#"
       db "#.##.dd...~~~.#####.#.#.b.#.#.#"
       db "#.............#...#...#.#.#...#"
       db "#b###.#.#.###.#.....###.#.....#"
       db "#.....b.#.....#.--......#.--..#"
       db "#.###.#.#.###b#.--.######.--..#"
       db "#...#...#.....b.........#.--..#"
       db "#b#.####b.#.#.#.....#.###.....#"
       db "#...#.....#.#.#.....#.........#"
       db "#.###.#......##.~~~.#.###.#####"
       db "#.#...#..ddd....~~~.#.....#...#"
       db "#.#b#.#..ddd....~~~.#.###.#.b.#"
       db "#.#...................#.#.#.#.#"
       db "#...#####.#.#####.###.#.#.#...#"
       db "#S..#.....#...........#......S#"
       db "###############################"

ARENA7 db "###############################"
       db "#S...........................S#"
       db "#....dd...ddd.########.~~~....#"
       db "#....dd...ddd.......#..~~~..#.#"
       db "###..dd.......##b##.#..~~~..#.#"
       db "#.#...............#.........#.#"
       db "#.#...................#.#b##b.#"
       db "#.b........~~~...~~~..#.......#"
       db "#.###.#b##.~~~...~~~..###.--..#"
       db "#.....#....~~~...~~~..#...--..#"
       db "#####.#..............##.#.....#"
       db "#.....#...........#.....#.....#"
       db "#..--.#.b......####.#.......###"
       db "#..--.#.#..ddd......#...--....#"
       db "#.....#.##.ddd..##b####.--.#b.#"
       db "#...#...#.......#.....#.......#"
       db "#...#...#.#.bb###.###.###.##..#"
       db "#S........#.......#..........S#"
       db "###############################"

ARENA8 db "###############################"
       db "#S..#........................S#"
       db "#...#....---.##.###.##b.dd....#"
       db "#...b....---..#...#.#.#.dd..#.#"
       db "#.######......#####.#.#.....#.#"
       db "#...............#...#.#.....#.#"
       db "#....###.....b#.....#.#.......#"
       db "#.--.....~~~....ddd.#....~~~..#"
       db "#.--..##.~~~..#.ddd.#.b#.~~~..#"
       db "#........~~~..#.....#....~~~..#"
       db "#.#..........##...###.##.....##"
       db "#.#.........#...............#.#"
       db "#.#.--.#b.#.###..~~~......###.#"
       db "#...--....#...#..~~~...dd...#.#"
       db "#bb.....#.###.##.~~~...dd.b.#.#"
       db "#...#.#.b.................#...#"
       db "#..##.#.##b####.###.###...##..#"
       db "#S....#.............#.....#..S#"
       db "###############################"

ARENA9 db "###############################"
       db "#S....#.............#........S#"
       db "#.....#.#.~~~...dd..#..--.....#"
       db "#.#.....#.~~~...dd.....--...#.#"
       db "#.#.#####.~~~......##..--.#.#.#"
       db "#.b.....b...........b.....#...#"
       db "#.....#.#.###.......#.###.#...#"
       db "#.--..b.b...#...~~~...#.......#"
       db "#.--.##.#.b.#...~~~.###.ddd...#"
       db "#.--..#.#.#.....~~~.....ddd...#"
       db "#.....#.###.###...............#"
       db "#.........................#...#"
       db "#...####.~~~.##.#....####.###.#"
       db "#...#....~~~..#.#.--..........#"
       db "#...#....~~~..b.#.--....#b#.###"
       db "#.............#.........#.....#"
       db "#..####.....b##...#.###.#.....#"
       db "#S....#.....#.....#..........S#"
       db "###############################"

ARENA10 db "###############################"
       db "#S............#..............S#"
       db "#....dd...--..##.~~~..###.....#"
       db "#....dd...--..#..~~~....#...#.#"
       db "#.##....#.--.#b..~~~.######.#.#"
       db "#.......#.................#...#"
       db "#.....#.#.###.###.######......#"
       db "#.--..#...#...b.#........~~~..#"
       db "#.--..#.#####.#.#.###.##.~~~..#"
       db "#.--..#.......#.b.#...#..~~~..#"
       db "#....##.#.#####.#.#.b.#......##"
       db "#.....b.#.........#.#...#.....#"
       db "#.###.#.#..~~~......#######.b.#"
       db "#.#.....#..~~~...dd.......#.#.#"
       db "#.#...###..~~~...dd.b####.#.#.#"
       db "#.b...#...............#...#.#.#"
       db "#..##.#...#...b######.#...b#..#"
       db "#S........#...........#......S#"
       db "###############################"

ARENA11 db "###############################"
       db "#S...........................S#"
       db "#..##.#.###.#.###b###.#.####..#"
       db "#.....#.....#...#...#.#.#...#.#"
       db "#...##b.#b###.##b.#.#.#.#.#.###"
       db "#.....#...........#.#.#...#...#"
       db "#.###.####.....#b#....#....##.#"
       db "#.....#....~~~.....--...dd..#.#"
       db "#######.#..~~~.b##.--.b.dd..#.#"
       db "#.....#.#..~~~........#.....#.#"
       db "#.b####.#b.....##.....#######.#"
       db "#.......#...#.................#"
       db "#..---..#...#.###.~~~....dd.#b#"
       db "#..---........#...~~~....dd...#"
       db "##........#####...~~~.##....#.#"
       db "#...#.........#.........#...#.#"
       db "#...#.###.#########...#.####..#"
       db "#S......#.............#......S#"
       db "###############################"

ARENA12 db "###############################"
       db "#S..............#...#........S#"
       db "#...####....###.#.....#.dd....#"
       db "#.b......dd...#.#.--..#.dd....#"
       db "#.#.###..dd.#.#.#.--..#....##.#"
       db "#.#.#.......#.................#"
       db "#......######b##b##.##......#.#"
       db "#..~~~........#...#....---..#.#"
       db "#b.~~~..##b##.#.#.###..---.##.#"
       db "#..~~~..........#...#.........#"
       db "#...............#...###...b##.#"
       db "#.#...#.............#.......#.#"
       db "#.#.####b.~~~...---.#..~~~..#.#"
       db "#...#...#.~~~...---.#..~~~..b.#"
       db "#...#.#.#.~~~.......#..~~~.##.#"
       db "#...#.#.............#.......#.#"
       db "#..b#.b####b#.#.##b##.###.#...#"
       db "#S....#.......#...........#..S#"
       db "###############################"

ARENA13 db "###############################"
       db "#S................#..........S#"
       db "#..##.#b#########.#####.--....#"
       db "#.#...#.#.......#.......--....#"
       db "#.b.###.#.#b###.###...b.--.##.#"
       db "#...#.#...#.......#...b.....b.#"
       db "##b.....b......##.....#####.#.#"
       db "#....dd.#..ddd..#.~~~.......#.#"
       db "#....dd.#..ddd..#.~~~.#...###.#"
       db "#....dd.........#.~~~.#.....#.#"
       db "#.##........#####.....#####.#.#"
       db "#...#.#...........#...#.....#.#"
       db "##b.#.#.#.~~~.##b.#.#......b#.#"
       db "#.#.....#.~~~.#.....#..---..#.#"
       db "#.#.#.#.#.~~~.#.....#..---..#.#"
       db "#...#.#.#...........#.......#.#"
       db "#..##.#.#...##b.#...#.....#...#"
       db "#S..............#...#.....#..S#"
       db "###############################"

ARENA14 db "###############################"
       db "#S....#.............#........S#"
       db "#..##.#..--.#b#.###.###.--....#"
       db "#...b.#..--...#...#.....--..#.#"
       db "#.###.#.....#.#.#.#.###.....#.#"
       db "#.#.........#...b...#.......#.#"
       db "#.....#b....#.#.#.....#.......#"
       db "#.~~~....--.#.#.#.dd..#..~~~..#"
       db "#.~~~.#..--.#.#.b.dd..#..~~~..#"
       db "#.~~~.#..--...#..........~~~..#"
       db "#.....#.....b#b.###...#.......#"
       db "#.....#.#.#.....#.....#.......#"
       db "#.#.###.#.#.###.#.~~~.#....##.#"
       db "#.#.#.....#...#.b.~~~.#.dd..b.#"
       db "#.b.#.#b#.#...#.#.~~~.#.dd..#.#"
       db "#.#.#.....#...#.......#.....#.#"
       db "#...###...#.#.#.###...#...##..#"
       db "#S........#.#.........#......S#"
       db "###############################"

ARENA15 db "###############################"
       db "#S...........................S#"
       db "#...##b####.--...ddd...~~~....#"
       db "#...........--...ddd...~~~....#"
       db "###.#######............~~~.##.#"
       db "#...#.......................b.#"
       db "#.###.##............#bb.#####.#"
       db "#...#....~~~....~~~.#.....#...#"
       db "#...#.##.~~~.##.~~~.#.#####.#.#"
       db "#...#....~~~..#.~~~...#...#.#.#"
       db "#...####......#.....###...b.#.#"
       db "#.....#.......b.....#.........#"
       db "#.---.##......#.....#.##.ddd..#"
       db "#.---....ddd....---.#.#..ddd..#"
       db "#.....#..ddd..#.---.#.b.......#"
       db "#.....#.......b.....#.#...#...#"
       db "#...#.#...#.###...#.#.b.#.#...#"
       db "#S..#.....#.......#...#.b....S#"
       db "###############################"

ARENA16 db "###############################"
       db "#S..............#............S#"
       db "#...###..~~~..#.#.~~~.#####...#"
       db "#.....#..~~~..#...~~~.......#.#"
       db "#.###.#..~~~.####.~~~.....###.#"
       db "#.#...#.......#...........#.#.#"
       db "#....##...###.#.#bb.b.......#.#"
       db "#.dd..#...#...#.#.#.#...---...#"
       db "#.dd..###.#.b##.#.#.#b#.---.###"
       db "#.....#.....#...#.#...#.......#"
       db "#.###.b####.#.###.#.###.#...#.#"
       db "#...............#.......#...#.#"
       db "#.dd.##.#.~~~.#.#.....####b#b.#"
       db "#.dd..#.#.~~~.#.#..--.#.......#"
       db "#.....#.#.~~~.#.##.--.b.#######"
       db "#...#.#.......#.......#.....b.#"
       db "#..#b.#.###.#.###...#.#####...#"
       db "#S......#...b.......#........S#"
       db "###############################"

ARENA17 db "###############################"
       db "#S......#.....#..............S#"
       db "#....dd.#.dd.##........~~~....#"
       db "#.#..dd...dd.....---...~~~..#.#"
       db "#.bb.........###.---...~~~.##.#"
       db "#.#...........b...............#"
       db "#.#.....#.#.....#.#...#.####b.#"
       db "#.#..--.#.#.--..#.#...#.....#.#"
       db "#.#..--.#.#.--..#.###.#####.#.#"
       db "#.........#.....#.....#.....#.#"
       db "#####.#.###.######b.###.b####.#"
       db "#.....#.....................#.#"
       db "#.###.#..ddd.##.~~~.##.~~~..b.#"
       db "#...#....ddd....~~~.#..~~~....#"
       db "##b.####.....##.~~~.#..~~~.##.#"
       db "#.#.#...............b.........#"
       db "#...###.bb#.###.#######...##..#"
       db "#S......#.....#...........#..S#"
       db "###############################"

ARENA18 db "###############################"
       db "#S................#..........S#"
       db "#....dd.###.dd..#.#.##.~~~....#"
       db "#....dd.....dd..#......~~~..#.#"
       db "#.#.....#...dd..#.###..~~~..#.#"
       db "#.#.....#...........#.......#.#"
       db "#.......#b##b##......##.###.###"
       db "#.~~~............~~~..#...#...#"
       db "#.~~~....---.bb..~~~..###.b##.#"
       db "#.~~~....---..#..~~~....#.#...#"
       db "#.....b.......#......##.###.#.#"
       db "#.....#.#.#...#.#...........#.#"
       db "#.##....#.#.....#......~~~.##.#"
       db "#.#..--...b.--..#.dd...~~~....#"
       db "#.##.--.#b#.--..#.dd...~~~....#"
       db "#...............b.............#"
       db "#.....b######.b##...#####.....#"
       db "#S....#......................S#"
       db "###############################"

ARENA19 db "###############################"
       db "#S......#.#...............#..S#"
       db "#..####.b.#.##bb.~~~...dd.#...#"
       db "#...#...#...#....~~~...dd.#...#"
       db "#.#.#.#######.##.~~~...dd.###.#"
       db "#.#.#.#.....#.#...............#"
       db "#.....#.....#.###.###.#...#b#.#"
       db "#.--.....--.#...#.....#.......#"
       db "#.--..##.--.#.#.#####.#.#.#b###"
       db "#........--.#.b.#.....#.#.....#"
       db "#.###.##....#.b.##b...#.###bb.#"
       db "#.....#.......#...............#"
       db "#.#####.#.#####.ddd....~~~..#.#"
       db "#.......#.....#.ddd....~~~..#.#"
       db "#############.#.....##.~~~..#.#"
       db "#.................#.#.........#"
       db "#...#.##########b.#.#.###.#...#"
       db "#S..b.....................#..S#"
       db "###############################"

ARENA20 db "###############################"
       db "#S...........................S#"
       db "#....dd...dd..#.--..#..~~~....#"
       db "#.#..dd...dd..#.--..#..~~~....#"
       db "#.#.....#.....#....###.~~~.b#.#"
       db "#.#.....b.....#.....#.........#"
       db "#.......b######.....#.##b.b##.#"
       db "#..~~~..#.....#.~~~.#.........#"
       db "#..~~~..b.###.#.~~~.###..---..#"
       db "#..~~~......#...~~~......---..#"
       db "#.......##b.#.......#.##.....##"
       db "#.#.#...............#.....#...#"
       db "#.##b####.---...###.#.....###.#"
       db "#.........---.....#....dd...#.#"
       db "#...###.........##b#b#.dd.#.#.#"
       db "#.........................#.#.#"
       db "#..##.#####.#######...#####b..#"
       db "#S....#......................S#"
       db "###############################"
arenaTable dd ARENA1,
           ARENA2,
           ARENA3,
           ARENA4,
           ARENA5,
           ARENA6,
           ARENA7,
           ARENA8,
           ARENA9,
           ARENA10,
           ARENA11,
           ARENA12,
           ARENA13,
           ARENA14,
           ARENA15,
           ARENA16,
           ARENA17,
           ARENA18,
           ARENA19,
           ARENA20
    logName     db "selftest.log", 0
    selftestArg db "selftest"
    nlStr       db 13, 10
    logHandle   dd 0
    written     dd 0
    logVal      dd 0
    t11x0       dd 0                    ; T11 泥土测试起始坐标
    t11y0       dd 0
    logBuf      db 64 dup (0)
    saveMap     db COLS*ROWS dup (0)

    nbRow       dd ?
    nbCol       dd ?
    nbIdx       dd ?
    nbDir       dd ?
    stT1  db "T1_P1_X_ROW13(expect112)="
    stT2  db "T2_ACTIVE_AFTER_FIRE="
    stT3  db "T3_ACTIVE_AFTER_620TICKS="
    stT4  db "T4_MAP_UNCHANGED(expect1)="
    stT5  db "T5_NOT_ON_WATER(expect1)="
    stT6  db "T6_SLIDE_ENGAGED(expect6-10)="
    stT7  db "T7_P2_X(expect120)="
    stT8  db "T8_BULLETS_AFTER_15FIRE(expect<=10)="
    stT9a db "T9_P2_DEAD_AT_TICK="
    stT9b db "T9_P2_ALIVE(expect0)="
    stT9c db "T9_P2_HP(expect0)="
    stT10 db "T10_P1_SCORE(expect1)="       ; 22 字符（勿多打 1 字节）
    stT11 db "T11_DIRT_SLOW_DISP(expect2)="
    stT12 db "T12_SELFKILL_HP(expect2)="    ; 25 字符

.code

; ------------------------------------------------------------
; RngNext —— xorshift32：x^=x<<13; x^=x>>17; x^=x<<5
; 返回 eax = 32 位随机数
; ------------------------------------------------------------
RngNext proc
    mov eax, rngState
    .if eax == 0
        mov eax, 2463534242       ; 防全零锁死
    .endif
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov rngState, eax
    ret
RngNext endp

; ------------------------------------------------------------
; RngBelow —— 返回 eax = [0, limit) 的随机整数
; ------------------------------------------------------------
RngBelow proc limit: dword
    invoke RngNext
    xor edx, edx
    div limit
    mov eax, edx
    ret
RngBelow endp

; ------------------------------------------------------------
; ParseArena —— 字符画 -> mapData / brickMask / 出生点
; 入参：pArena = 300 字节字符画首址
; ------------------------------------------------------------
ParseArena proc uses ebx esi edi ebp pArena: dword
    mov esi, pArena
    xor ebx, ebx                 ; i = 线性格子序号
    xor ebp, ebp                 ; row
RowLoop2:
    xor edi, edi                 ; col
ColLoop2:
    movzx eax, byte ptr [esi+ebx]
    mov dl, TILE_EMPTY
    .if al == '#'
        mov dl, TILE_STEEL
    .elseif al == 'b'
        mov dl, TILE_BRICK
    .elseif al == '~'
        mov dl, TILE_WATER
    .elseif al == '-'
        mov dl, TILE_ICE
    .elseif al == 'd'
        mov dl, TILE_DIRT
    .endif                       ; '.' 与 'S' 均落为空地
    mov mapData[ebx], dl
    ; 出生点记录（最多 4 个，顺序 = 图中 S 出现顺序）
    .if al == 'S'
        mov eax, spawnCount
        .if eax < 4
            mov ecx, edi
            imul ecx, ecx, CELL
            mov spawnX[eax*4], ecx
            mov ecx, ebp
            imul ecx, ecx, CELL
            mov spawnY[eax*4], ecx
            inc spawnCount
        .endif
    .endif
    inc ebx
    inc edi
    .if edi < COLS
        jmp ColLoop2
    .endif
    inc ebp
    .if ebp < ROWS
        jmp RowLoop2
    .endif
    ret
ParseArena endp

; ------------------------------------------------------------
; ResetTanks -- reset all tank slots, place tank0/tank1 at spawns,
; clear bullet pool (shared by GameInit and SelfTest)
; ------------------------------------------------------------
ResetTanks proc uses ebx esi edi
    lea esi, tanks
    xor ebx, ebx
RTLoop:
    mov (TANK ptr [esi]).alive, 0
    mov (TANK ptr [esi]).hp, TANK_HP
    mov (TANK ptr [esi]).fireCd, 0
    mov (TANK ptr [esi]).slide, 0
    mov (TANK ptr [esi]).sdir, 0
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp RTLoop
    .endif
    ; 按 numPlayers 激活坦克：2P=出生点0,3(对角) 3P=0,1,2 4P=0,1,2,3
    xor ebx, ebx
RT_Spawn:
    .if ebx >= numPlayers
        jmp RT_SpawnDone
    .endif
    mov esi, ebx
    .if numPlayers == 2 && ebx == 1
        mov esi, 3
    .endif
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edi, eax
    mov eax, esi
    mov eax, spawnX[eax*4]
    mov (TANK ptr [edi]).x, eax
    mov eax, esi
    mov eax, spawnY[eax*4]
    mov (TANK ptr [edi]).y, eax
    mov (TANK ptr [edi]).dir, DIR_DOWN
    mov (TANK ptr [edi]).alive, 1
    .if esi >= 2
        mov (TANK ptr [edi]).dir, DIR_UP      ; 下半出生点朝上
    .endif
    inc ebx
    jmp RT_Spawn
RT_SpawnDone:
    ; 清空弹池
    xor eax, eax
    mov ecx, MAX_BULLETS*(SIZEOF BULLET)/4
    lea edi, bullets
RTClearB:
    mov [edi], eax
    add edi, 4
    loop RTClearB
    mov roundOver, 0
    mov roundTimer, 0
    mov roundScored, 0
    mov seqSelf, 0
    mov fireHappened, 0
    ret
ResetTanks endp

; ------------------------------------------------------------
; OpenLog / LogStr / LogNum / CloseLog -- selftest log file helpers
; ------------------------------------------------------------
OpenLog proc
    invoke CreateFileA, offset logName, GENERIC_WRITE, 0, NULL,
           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    mov logHandle, eax
    ret
OpenLog endp

CloseLog proc
    invoke CloseHandle, logHandle
    ret
CloseLog endp

LogStr proc pStr: dword, len: dword
    invoke WriteFile, logHandle, pStr, len, addr written, NULL
    ret
LogStr endp

LogNum proc num: dword
    mov eax, num
    mov edi, offset logBuf
    add edi, 60
    mov byte ptr [edi], 0
    .if eax == 0
        dec edi
        mov byte ptr [edi], '0'
    .endif
    mov ecx, 10
LNLoop:
    .if eax != 0
        xor edx, edx
        div ecx
        add dl, '0'
        dec edi
        mov [edi], dl
        jmp LNLoop
    .endif
    mov eax, offset logBuf + 60
    sub eax, edi
    invoke WriteFile, logHandle, edi, eax, addr written, NULL
    invoke WriteFile, logHandle, offset nlStr, 2, addr written, NULL
    ret
LogNum endp

; ------------------------------------------------------------
; AdvanceTicks -- run GameUpdate n times (selftest driver)
; ------------------------------------------------------------
AdvanceTicks proc uses ebx n: dword
    mov ebx, n
ATLoop:
    invoke GameUpdate
    dec ebx
    .if ebx != 0
        jmp ATLoop
    .endif
    ret
AdvanceTicks endp

; ------------------------------------------------------------
; FindOpenNeighbor -- 找某格四邻中第一个可通行格（空地/冰）
; 入参：cellIdx；返回 eax = 方向码 0上 1右 2下 3左，nbIdx = 邻居格索引
; ------------------------------------------------------------
FindOpenNeighbor proc uses ebx ecx edx cellIdx: dword
    mov eax, cellIdx
    xor edx, edx
    mov ebx, COLS
    div ebx
    mov nbRow, eax
    mov nbCol, edx
    mov nbDir, 99
    mov nbIdx, 99
    ; 上
    mov eax, nbRow
    .if eax > 0
        dec eax
        imul eax, eax, COLS
        add eax, nbCol
        mov ecx, eax
        movzx eax, mapData[ecx]
        .if eax == TILE_EMPTY || eax == TILE_ICE || eax == TILE_DIRT
            mov nbDir, 0
            mov nbIdx, ecx
        .endif
    .endif
    ; 右
    .if nbDir == 99
        mov eax, nbCol
        .if eax < COLS-1
            mov eax, nbRow
            imul eax, eax, COLS
            add eax, nbCol
            inc eax
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE || eax == TILE_DIRT
                mov nbDir, 1
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    ; 下
    .if nbDir == 99
        mov eax, nbRow
        .if eax < ROWS-1
            mov eax, nbRow
            inc eax
            imul eax, eax, COLS
            add eax, nbCol
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE || eax == TILE_DIRT
                mov nbDir, 2
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    ; 左
    .if nbDir == 99
        mov eax, nbCol
        .if eax > 0
            mov eax, nbRow
            imul eax, eax, COLS
            add eax, nbCol
            dec eax
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_EMPTY || eax == TILE_ICE || eax == TILE_DIRT
                mov nbDir, 3
                mov nbIdx, ecx
            .endif
        .endif
    .endif
    mov eax, nbDir
    ret
FindOpenNeighbor endp

; ------------------------------------------------------------
; SetDirInput -- 按方向码设置 P1 输入（99 = 全部清零）
; ------------------------------------------------------------
SetDirInput proc dir: dword
    mov inputTable[0], 0
    mov inputTable[4], 0
    mov inputTable[8], 0
    mov inputTable[12], 0
    mov eax, dir
    .if eax == 0
        mov inputTable[0], 1
    .elseif eax == 1
        mov inputTable[12], 1
    .elseif eax == 2
        mov inputTable[4], 1
    .elseif eax == 3
        mov inputTable[8], 1
    .endif
    ret
SetDirInput endp

; ------------------------------------------------------------
; InitKeyDefaults -- 默认键位表（设置界面可覆盖）
; P1 WASD+空格  P2 方向键+Enter  P3 IJKL+U  P4 TFGH+B
; 动作顺序：0上 1下 2左 3右 4开火
; ------------------------------------------------------------
InitKeyDefaults proc
    mov keyTable[0],  VK_W
    mov keyTable[4],  VK_S
    mov keyTable[8],  VK_A
    mov keyTable[12], VK_D
    mov keyTable[16], VK_SPACE
    mov keyTable[20], VK_UP
    mov keyTable[24], VK_DOWN
    mov keyTable[28], VK_LEFT
    mov keyTable[32], VK_RIGHT
    mov keyTable[36], VK_RETURN
    mov keyTable[40], VK_I
    mov keyTable[44], VK_K
    mov keyTable[48], VK_J
    mov keyTable[52], VK_L
    mov keyTable[56], VK_U
    mov keyTable[60], VK_T
    mov keyTable[64], VK_G
    mov keyTable[68], VK_F
    mov keyTable[72], VK_H
    mov keyTable[76], VK_B
    ret
InitKeyDefaults endp

; ------------------------------------------------------------
; CountOwnBullets -- number of active bullets owned by ownerIdx
; ------------------------------------------------------------
CountOwnBullets proc uses ebx esi ownerIdx: dword
    xor eax, eax
    xor ecx, ecx
    mov esi, offset bullets
    mov ebx, ownerIdx
CB2Loop:
    .if ecx >= MAX_BULLETS
        jmp CB2Done
    .endif
    cmp (BULLET ptr [esi]).active, 0
    je CB2Skip
    cmp (BULLET ptr [esi]).owner, ebx
    jne CB2Skip
    inc eax
CB2Skip:
    add esi, SIZEOF BULLET
    inc ecx
    jmp CB2Loop
CB2Done:
    ret
CountOwnBullets endp

; ------------------------------------------------------------
; SelfTestRun -- M1 headless acceptance test (run with: tankwar selftest)
; Deterministic: fixed ARENA1, simulated inputs, results -> selftest.log
; ------------------------------------------------------------
SelfTestRun proc uses ebx esi edi
    ; 固定 ARENA1 保证确定性
    mov rngState, 1
    mov spawnCount, 0
    invoke ParseArena, offset ARENA1
    ; 自测专用：清空第 13 行做水平测试走廊（T1/T7/T9 依赖）
    mov ecx, 13*COLS+1
STClear13:
    mov mapData[ecx], TILE_EMPTY
    inc ecx
    .if ecx < 13*COLS+COLS-1
        jmp STClear13
    .endif
    call ResetTanks
    ; 地图快照（验证墙体不可摧毁）
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    rep movsb
    call OpenLog

    ; T1: P1 沿第 13 行走廊右移 40 tick（32 -> 112）
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    invoke SetDirInput, 1
    invoke AdvanceTicks, 40
    invoke SetDirInput, 99
    invoke LogStr, offset stT1, 25
    invoke LogNum, tanks[0*SIZEOF TANK].x          ; expect 112

    ; T2: 开火 -> 一颗弹在飞
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT2, 21
    invoke LogNum, logVal                          ; expect 1

    ; T3: 620 tick 后弹全部消亡（反弹耗尽或超时）
    invoke AdvanceTicks, 620
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT3, 25
    invoke LogNum, logVal                          ; expect 0

    ; T4: 墙体不可摧毁 —— 轰一炮再跑 900 tick，地图逐字节不变
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    invoke AdvanceTicks, 900
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    repe cmpsb
    mov logVal, 0
    .if ZERO?
        mov logVal, 1
    .endif
    invoke LogStr, offset stT4, 26
    invoke LogNum, logVal                          ; expect 1

    ; T5: 水域挡坦克 —— 找第一个 '~'，从开放邻居向水推进 30 tick，
    ;     坦克中心格必须不是水
    xor esi, esi
T5Find:
    .if esi >= COLS*ROWS
        mov logVal, 99
        invoke LogStr, offset stT5, 25
        invoke LogNum, logVal
        ; 直接落入 T6 段
    .endif
    cmp mapData[esi], TILE_WATER
    je T5Found
    inc esi
    jmp T5Find
T5Found:
    invoke FindOpenNeighbor, esi
    mov ebx, eax                                   ; dirCode（邻居相对水格的方向）
    mov eax, nbIdx
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, edx
    imul ecx, ecx, CELL
    mov tanks[0*SIZEOF TANK].x, ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    invoke SetDirInput, ebx                        ; 朝水推进
    invoke AdvanceTicks, 30
    invoke SetDirInput, 99                         ; 清输入
    mov eax, tanks[0*SIZEOF TANK].x
    add eax, CELL/2
    mov ecx, tanks[0*SIZEOF TANK].y
    add ecx, CELL/2
    invoke TileAtPx, eax, ecx
    mov logVal, 1
    .if eax == TILE_WATER
        mov logVal, 0                              ; 坦克中心在水上 = 失败
    .endif
    invoke LogStr, offset stT5, 25
    invoke LogNum, logVal                          ; expect 1

    ; T6: 冰面滑行 —— 站上第一个 '-'，向开放邻居方向走 1 tick，
    ;     slide 应被置为 6..10
    xor esi, esi
T6Find:
    .if esi >= COLS*ROWS
        mov logVal, 99
        invoke LogStr, offset stT6, 29
        invoke LogNum, logVal
        jmp T7Start
    .endif
    cmp mapData[esi], TILE_ICE
    je T6Found
    inc esi
    jmp T6Find
T6Found:
    invoke FindOpenNeighbor, esi
    mov ebx, eax
    mov eax, esi                       ; 传送目标是冰面格本身
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, edx
    imul ecx, ecx, CELL
    mov tanks[0*SIZEOF TANK].x, ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    invoke SetDirInput, ebx
    invoke GameUpdate
    invoke SetDirInput, 99
    invoke LogStr, offset stT6, 29
    invoke LogNum, tanks[0*SIZEOF TANK].slide      ; expect 6..10

    ; T7: P2 方向键 —— 第 13 行走廊左移 20 tick（160 -> 120）
T7Start:
    call ResetTanks
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputTable[28], 1
    invoke AdvanceTicks, 20
    mov inputTable[28], 0
    invoke LogStr, offset stT7, 19
    invoke LogNum, tanks[1*SIZEOF TANK].x          ; expect 120

    ; T8: 每坦同屏 <=10 发（15 次快速开火 -> 场上 10 颗）
    call ResetTanks
    mov ebx, 15
T8Loop:
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    dec ebx
    .if ebx != 0
        jmp T8Loop
    .endif
    invoke CountOwnBullets, 0
    mov logVal, eax
    invoke LogStr, offset stT8, 36
    invoke LogNum, logVal                          ; expect 10

    ; T9: 反弹/直射击杀 —— 第 13 行同走廊，3 发命中判负
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputTable[16], 1
    xor esi, esi
T9Loop:
    .if esi >= 300
        jmp T9Done
    .endif
    invoke GameUpdate
    inc esi
    cmp tanks[1*SIZEOF TANK].alive, 0
    je T9Done
    jmp T9Loop
T9Done:
    mov inputTable[16], 0
    invoke LogStr, offset stT9a, 19
    invoke LogNum, esi                             ; kill tick (<300)
    invoke LogStr, offset stT9b, 21
    invoke LogNum, tanks[1*SIZEOF TANK].alive      ; expect 0
    invoke LogStr, offset stT9c, 18
    invoke LogNum, tanks[1*SIZEOF TANK].hp         ; expect 0
    invoke AdvanceTicks, 100                       ; 等定格结束（90 tick）开新一轮
    invoke LogStr, offset stT10, 22
    invoke LogNum, tanks[0*SIZEOF TANK].score      ; expect 1

    ; T11: 泥土减速 —— 找第一个 'd'，坦克置于其上，朝开放邻居方向推
    ;      2 tick：泥上速度 1 -> 位移 2（普通地面会是 4）
    xor esi, esi
T11Find:
    .if esi >= COLS*ROWS
        mov logVal, 99
        invoke LogStr, offset stT11, 28
        invoke LogNum, logVal
        jmp T11Done
    .endif
    cmp mapData[esi], TILE_DIRT
    je T11Found
    inc esi
    jmp T11Find
T11Found:
    invoke FindOpenNeighbor, esi
    mov ebx, eax                          ; 方向代码（跨 invoke 存 ebx）
    mov eax, esi
    xor edx, edx
    mov ecx, COLS
    div ecx
    mov ecx, edx
    imul ecx, ecx, CELL
    mov t11x0, ecx
    mov tanks[0*SIZEOF TANK].x, ecx
    imul eax, eax, CELL
    mov t11y0, eax
    mov tanks[0*SIZEOF TANK].y, eax
    mov tanks[0*SIZEOF TANK].alive, 1
    invoke SetDirInput, ebx
    invoke AdvanceTicks, 2
    invoke SetDirInput, 99
    ; 位移 = |dx| + |dy|（手写比较，不用 .if 的符号语义）
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, t11x0
    cmp eax, 0
    jge T11dxPos
    neg eax
T11dxPos:
    mov ecx, eax
    mov eax, tanks[0*SIZEOF TANK].y
    sub eax, t11y0
    cmp eax, 0
    jge T11dyPos
    neg eax
T11dyPos:
    add eax, ecx
    mov logVal, eax                      ; 中转（invoke 会破坏 eax）
    invoke LogStr, offset stT11, 28
    invoke LogNum, logVal                ; expect 2
T11Done:
    ; T12: 反弹自伤 —— P1 贴右侧边界墙朝右发射，出膛弹立即撞墙反弹
    ;      回来命中自己 -> hp 3->2（Tank Trouble 核心规则：弹可自杀）
    mov tanks[0*SIZEOF TANK].x, 951      ; 贴 col30 挡板（972..980）
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov edi, offset bullets
    xor ecx, ecx
ST12ClrB:
    mov (BULLET ptr [edi]).active, 0
    add edi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp ST12ClrB
    .endif
    mov inputTable[16], 1
    invoke GameUpdate                    ; 发射
    mov inputTable[16], 0
    invoke AdvanceTicks, 30              ; 出膛->撞墙->反弹->自中
    mov eax, tanks[0*SIZEOF TANK].hp
    mov logVal, eax                      ; 中转（invoke 会破坏 eax）
    invoke LogStr, offset stT12, 25
    invoke LogNum, logVal                ; expect 2
    call CloseLog
    ret
SelfTestRun endp

; ------------------------------------------------------------
; GameInit —— 随机选图解析 + 重置坦克/子弹
; tank0 = 出生点0（左上，朝下），tank1 = 出生点3（右下，朝上）
; ------------------------------------------------------------
GameInit proc uses ebx esi edi
    ; xorshift32 seed (first time only)
    .if rngState == 0
        invoke GetTickCount
        mov rngState, eax
    .endif
    ; pick a random arena
    invoke RngBelow, ARENA_COUNT
    mov mapIndex, eax
    mov spawnCount, 0
    mov ecx, arenaTable[eax*4]
    invoke ParseArena, ecx
    call ResetTanks
    call InitKeyDefaults
    mov tanks[0*SIZEOF TANK].score, 0
    mov tanks[1*SIZEOF TANK].score, 0
    mov tanks[2*SIZEOF TANK].score, 0
    mov tanks[3*SIZEOF TANK].score, 0
    ret
GameInit endp

; ------------------------------------------------------------
; TileAtPx —— 取像素坐标所在格子的类型
; 入参：px, py；返回 eax = 格子类型（越界按钢墙）
; ------------------------------------------------------------
TileAtPx proc uses ebx px: dword, py: dword
    mov eax, px
    mov ebx, CELL
    xor edx, edx
    div ebx                          ; eax = 列
    mov ecx, eax
    mov eax, py
    xor edx, edx
    div ebx                          ; eax = 行
    .if ecx >= COLS || eax >= ROWS
        mov eax, TILE_STEEL
        ret
    .endif
    mov ebx, COLS
    imul eax, ebx
    add eax, ecx
    movzx eax, mapData[eax]
    ret
TileAtPx endp

; ------------------------------------------------------------
; IsWallCell —— 格子是否为实体墙（钢/砖）
; 越界返回 0（地图四周自带整圈边界墙，无需虚拟延伸）
; ------------------------------------------------------------
IsWallCell proc colX: dword, rowX: dword
    ; 注意：MASM 的 .if eax < 0 会编译成无符号 jb 恒为假（已两次踩坑），
    ; 负数判断一律手写 test + js。
    mov eax, colX
    test eax, eax
    js ISW_No
    .if eax >= COLS
        jmp ISW_No
    .endif
    mov eax, rowX
    test eax, eax
    js ISW_No
    .if eax >= ROWS
        jmp ISW_No
    .endif
    mov eax, rowX
    imul eax, eax, COLS
    add eax, colX
    movzx eax, mapData[eax]
    .if eax == TILE_STEEL || eax == TILE_BRICK
        mov eax, 1
    .else
        xor eax, eax
    .endif
    ret
ISW_No:
    xor eax, eax
    ret
IsWallCell endp

; ------------------------------------------------------------
; WallRects —— 枚举墙格 (colX,rowX) 的挡板矩形（最多 5 个）：
;   [0] 格中心 WALL_THICK x WALL_THICK 点
;   [1..4] 朝相邻墙格(左/右/上/下)的连接条（相邻墙连成细线的关键）
; 入参：pRects = 5 个 RECT 的缓冲；返回 eax = 实际个数 1..5
; gfx.asm 的渲染与本模块碰撞共用此几何 -> 所见即所撞
; ------------------------------------------------------------
WallRects proc uses ebx ecx edx esi edi colX: dword, rowX: dword, pRects: dword
    local x0:dword, y0:dword, wL:dword, wR:dword, wU:dword, wD:dword
    ; 四邻是否墙（决定连接条）
    mov eax, colX
    dec eax
    mov ecx, rowX
    invoke IsWallCell, eax, ecx
    mov wL, eax
    mov eax, colX
    inc eax
    mov ecx, rowX
    invoke IsWallCell, eax, ecx
    mov wR, eax
    mov eax, rowX
    dec eax
    mov ecx, colX
    invoke IsWallCell, ecx, eax
    mov wU, eax
    mov eax, rowX
    inc eax
    mov ecx, colX
    invoke IsWallCell, ecx, eax
    mov wD, eax
    ; 格子像素原点
    mov eax, colX
    imul eax, eax, CELL
    mov x0, eax
    mov eax, rowX
    imul eax, eax, CELL
    mov y0, eax
    ; 注：孤立墙柱（四邻无墙）不再保持整格 —— 用户要求全部细墙。
    ; 此时只有 [0] 中心点，1 个矩形返回（细点间隙可穿弹，所见即所撞）。
    mov edi, pRects
    mov esi, 1                        ; 个数计数
    ; [0] 中心点（格内居中，WALL_THICK 见方）
    mov eax, x0
    add eax, (CELL - WALL_THICK)/2
    mov (RECT ptr [edi]).left, eax
    add eax, WALL_THICK
    mov (RECT ptr [edi]).right, eax
    mov eax, y0
    add eax, (CELL - WALL_THICK)/2
    mov (RECT ptr [edi]).top, eax
    add eax, WALL_THICK
    mov (RECT ptr [edi]).bottom, eax
    add edi, SIZEOF RECT
    ; [1] 左连接条：x∈[x0, x0+CELL/2)
    .if wL != 0
        mov eax, x0
        mov (RECT ptr [edi]).left, eax
        add eax, CELL/2
        mov (RECT ptr [edi]).right, eax
        mov eax, y0
        add eax, (CELL - WALL_THICK)/2
        mov (RECT ptr [edi]).top, eax
        add eax, WALL_THICK
        mov (RECT ptr [edi]).bottom, eax
        add edi, SIZEOF RECT
        inc esi
    .endif
    ; [2] 右连接条：x∈[x0+CELL/2, x0+CELL)
    .if wR != 0
        mov eax, x0
        add eax, CELL/2
        mov (RECT ptr [edi]).left, eax
        add eax, CELL/2
        mov (RECT ptr [edi]).right, eax
        mov eax, y0
        add eax, (CELL - WALL_THICK)/2
        mov (RECT ptr [edi]).top, eax
        add eax, WALL_THICK
        mov (RECT ptr [edi]).bottom, eax
        add edi, SIZEOF RECT
        inc esi
    .endif
    ; [3] 上连接条：y∈[y0, y0+CELL/2)
    .if wU != 0
        mov eax, x0
        add eax, (CELL - WALL_THICK)/2
        mov (RECT ptr [edi]).left, eax
        add eax, WALL_THICK
        mov (RECT ptr [edi]).right, eax
        mov eax, y0
        mov (RECT ptr [edi]).top, eax
        add eax, CELL/2
        mov (RECT ptr [edi]).bottom, eax
        add edi, SIZEOF RECT
        inc esi
    .endif
    ; [4] 下连接条：y∈[y0+CELL/2, y0+CELL)
    .if wD != 0
        mov eax, x0
        add eax, (CELL - WALL_THICK)/2
        mov (RECT ptr [edi]).left, eax
        add eax, WALL_THICK
        mov (RECT ptr [edi]).right, eax
        mov eax, y0
        add eax, CELL/2
        mov (RECT ptr [edi]).top, eax
        add eax, CELL/2
        mov (RECT ptr [edi]).bottom, eax
        add edi, SIZEOF RECT
        inc esi
    .endif
    mov eax, esi
    ret
WallRects endp

; ------------------------------------------------------------
; WallRectsHit —— 矩形 (px0,py0,w0,h0) 是否与任一挡板矩形相交
; 只需检查矩形所覆盖格子的 3x3 邻域（挡板矩形不会伸出本格）
; 返回 eax = 1 命中 / 0 未命中
; ------------------------------------------------------------
WallRectsHit proc uses ebx esi edi px0: dword, py0: dword, w0: dword, h0: dword
    local c0:dword, r0:dword, cc:dword, rr:dword, cnt:dword, i:dword
    local rbuf[5]:RECT
    ; 防御性 clamp 后取所在格（.if eax < 0 恒假，手写 test/jns）
    mov eax, px0
    test eax, eax
    jns WRH_PxOk
    xor eax, eax
WRH_PxOk:
    xor edx, edx
    mov ebx, CELL
    div ebx
    mov c0, eax
    mov eax, py0
    test eax, eax
    jns WRH_PyOk
    xor eax, eax
WRH_PyOk:
    xor edx, edx
    div ebx                           ; ebx 仍是 CELL（中间无 invoke）
    mov r0, eax
    mov eax, r0
    dec eax
    mov rr, eax
WRH_Row:
    mov eax, r0
    inc eax
    .if rr > eax
        xor eax, eax
        ret
    .endif
    mov eax, c0
    dec eax
    mov cc, eax
WRH_Col:
    mov eax, c0
    inc eax
    .if cc > eax
        inc rr
        jmp WRH_Row
    .endif
    mov eax, cc
    test eax, eax
    js WRH_CNext
    .if eax >= COLS
        jmp WRH_CNext
    .endif
    mov eax, rr
    test eax, eax
    js WRH_CNext
    .if eax >= ROWS
        jmp WRH_CNext
    .endif
    mov eax, rr
    imul eax, eax, COLS
    add eax, cc
    movzx eax, mapData[eax]
    .if eax == TILE_STEEL || eax == TILE_BRICK
        invoke WallRects, cc, rr, addr rbuf
        mov cnt, eax
        mov i, 0
WRH_R:
        mov eax, cnt
        .if i >= eax
            jmp WRH_CNext
        .endif
        mov eax, i
        shl eax, 4                    ; SIZEOF RECT = 16
        lea esi, rbuf
        add esi, eax
        ; AABB 相交：left < px0+w0 && right > px0 && top < py0+h0 && bottom > py0
        mov eax, px0
        add eax, w0
        mov ecx, (RECT ptr [esi]).left
        .if eax <= ecx
            jmp WRH_RN
        .endif
        mov eax, (RECT ptr [esi]).right
        .if eax <= px0
            jmp WRH_RN
        .endif
        mov eax, py0
        add eax, h0
        mov ecx, (RECT ptr [esi]).top
        .if eax <= ecx
            jmp WRH_RN
        .endif
        mov eax, (RECT ptr [esi]).bottom
        .if eax <= py0
            jmp WRH_RN
        .endif
        mov eax, 1                    ; 命中
        ret
WRH_RN:
        inc i
        jmp WRH_R
    .endif
WRH_CNext:
    inc cc
    jmp WRH_Col
WallRectsHit endp

; ------------------------------------------------------------
; TankBlocked —— 坦克 TANK_SIZE x TANK_SIZE 目标矩形是否被地形挡住
; 挡板墙：矩形级 AABB（与视觉一致）；水域：整格阻挡
; ------------------------------------------------------------
TankBlocked proc uses ebx nx0: dword, ny0: dword
    local c0:dword, c1:dword, r0:dword, r1:dword, cc:dword, rr:dword
    invoke WallRectsHit, nx0, ny0, TANK_SIZE, TANK_SIZE
    .if eax != 0
        ret                           ; eax=1
    .endif
    ; 水域整格：坦克矩形覆盖到的所有格子
    mov eax, nx0
    xor edx, edx
    mov ebx, CELL
    div ebx
    mov c0, eax
    mov eax, nx0
    add eax, TANK_SIZE-1
    xor edx, edx
    div ebx
    mov c1, eax
    mov eax, ny0
    xor edx, edx
    div ebx
    mov r0, eax
    mov eax, ny0
    add eax, TANK_SIZE-1
    xor edx, edx
    div ebx
    mov r1, eax
    mov eax, r0
    mov rr, eax
TB_Row:
    mov eax, r1
    .if rr > eax
        xor eax, eax
        ret
    .endif
    mov eax, c0
    mov cc, eax
TB_Col:
    mov eax, c1
    .if cc > eax
        inc rr
        jmp TB_Row
    .endif
    mov eax, cc
    test eax, eax
    js TB_CNext
    .if eax >= COLS
        jmp TB_CNext
    .endif
    mov eax, rr
    test eax, eax
    js TB_CNext
    .if eax >= ROWS
        jmp TB_CNext
    .endif
    mov eax, rr
    imul eax, eax, COLS
    add eax, cc
    movzx eax, mapData[eax]
    .if eax == TILE_WATER
        mov eax, 1
        ret
    .endif
TB_CNext:
    inc cc
    jmp TB_Col
TankBlocked endp

; ------------------------------------------------------------
; SpawnBullet —— 按坦克朝向生成一颗子弹（§3：同屏每坦 <=10 发）
; 入参：ownerIdx = 玩家编号；弹池满 / 该坦弹满 / 坦克死亡则忽略
; ------------------------------------------------------------
SpawnBullet proc uses ebx esi edi ownerIdx: dword
    local ptank:dword
    mov edi, ownerIdx

    ; 统计该坦克同屏弹数（顺序固定遍历）
    xor eax, eax                     ; count
    xor ecx, ecx
    mov esi, offset bullets
CountLoop:
    .if ecx >= MAX_BULLETS
        jmp CountDone
    .endif
    cmp (BULLET ptr [esi]).active, 0
    je CountSkip
    cmp (BULLET ptr [esi]).owner, edi
    jne CountSkip
    inc eax
CountSkip:
    add esi, SIZEOF BULLET
    inc ecx
    jmp CountLoop
CountDone:
    .if eax >= MAX_PER_TANK
        ret                          ; 池满禁射
    .endif

    ; 坦克指针
    mov eax, edi
    mov ebx, SIZEOF TANK
    imul ebx, eax
    add ebx, offset tanks
    mov ptank, ebx
    mov eax, (TANK ptr [ebx]).alive
    .if eax == 0
        ret
    .endif

    ; 找空闲弹槽
    mov esi, offset bullets
    xor ecx, ecx
FindSlot:
    cmp (BULLET ptr [esi]).active, 0
    je SlotFound
    add esi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp FindSlot
    .endif
    ret                              ; 弹池满

SlotFound:
    ; 速度向量由朝向决定（vx/vy 只取 0 / ±BULLET_SPEED）
    mov eax, (TANK ptr [ebx]).dir
    xor edx, edx                     ; vx 候选
    xor ecx, ecx                     ; vy 候选
    .if eax == DIR_UP
        mov ecx, -BULLET_SPEED
    .elseif eax == DIR_RIGHT
        mov edx, BULLET_SPEED
    .elseif eax == DIR_DOWN
        mov ecx, BULLET_SPEED
    .else
        mov edx, -BULLET_SPEED
    .endif
    mov (BULLET ptr [esi]).vx, edx
    mov (BULLET ptr [esi]).vy, ecx
    ; 位置：炮口（坦克边缘之外 8px = 炮管尖端）—— 否则开启自伤后
    ; 子弹出膛即命中自己
    mov eax, (TANK ptr [ebx]).dir
    .if eax == DIR_UP
        mov eax, (TANK ptr [ebx]).x
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov (BULLET ptr [esi]).x, eax
        mov eax, (TANK ptr [ebx]).y
        sub eax, BULLET_SIZE_PX
        mov (BULLET ptr [esi]).y, eax
    .elseif eax == DIR_DOWN
        mov eax, (TANK ptr [ebx]).x
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov (BULLET ptr [esi]).x, eax
        mov eax, (TANK ptr [ebx]).y
        add eax, TANK_SIZE
        mov (BULLET ptr [esi]).y, eax
    .elseif eax == DIR_LEFT
        mov eax, (TANK ptr [ebx]).x
        sub eax, BULLET_SIZE_PX
        mov (BULLET ptr [esi]).x, eax
        mov eax, (TANK ptr [ebx]).y
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov (BULLET ptr [esi]).y, eax
    .else
        mov eax, (TANK ptr [ebx]).x
        add eax, TANK_SIZE
        mov (BULLET ptr [esi]).x, eax
        mov eax, (TANK ptr [ebx]).y
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov (BULLET ptr [esi]).y, eax
    .endif
    mov (BULLET ptr [esi]).owner, edi
    mov (BULLET ptr [esi]).active, 1
    mov (BULLET ptr [esi]).bounces, 0
    mov (BULLET ptr [esi]).age, 0
    ret
SpawnBullet endp

; ------------------------------------------------------------
; BounceOne —— 记一次反弹；反弹数 >= 上限则销毁子弹
; 入参：bp = 子弹指针
; ------------------------------------------------------------
BounceOne proc pb: dword
    mov eax, pb
    inc (BULLET ptr [eax]).bounces
    mov eax, (BULLET ptr [eax]).bounces
    .if eax >= BULLET_MAX_BOUNCE
        mov edx, pb
        mov (BULLET ptr [edx]).active, 0
    .endif
    ret
BounceOne endp

; ------------------------------------------------------------
; BulletWallHit -- 8x8 bullet vs terrain, rect-level AABB
; in: pb = bullet ptr
; ret eax: 0=pass(water/ice/empty); 1=wall bounce (steel OR brick:
;          walls are INDESTRUCTIBLE per design change 2026-10-16)
; 挡板墙按矩形精确判定（与渲染几何共用），无采样空档
; ------------------------------------------------------------
BulletWallHit proc uses ebx pb: dword
    mov ebx, pb
    mov eax, (BULLET ptr [ebx]).x
    mov ecx, (BULLET ptr [ebx]).y
    invoke WallRectsHit, eax, ecx, BULLET_SIZE_PX, BULLET_SIZE_PX
    ret
BulletWallHit endp

; ------------------------------------------------------------
; MoveTank —— 坦克移动（水/钢/砖实心，冰/泥/空地可通行）
; 冰面：位移成功且中心格是冰 -> 刷新滑行 tick（6..10）与滑行方向
; 泥土：中心格是泥土 -> 本 tick 速度 DIRT_SPEED（1），否则 TANK_SPEED
; ------------------------------------------------------------
MoveTank proc ownerIdx: dword, wantDir: dword
    local nx:dword, ny:dword, solid:dword, ptank:dword, dirL:dword
    local spd:dword
    ; ptank = &tanks[ownerIdx]（跨 invoke 保存，用局部变量存指针）
    mov eax, ownerIdx
    mov ecx, SIZEOF TANK
    imul ecx, eax
    add ecx, offset tanks
    mov ptank, ecx
    mov eax, wantDir
    mov dirL, eax

    mov ecx, ptank
    mov edx, dirL
    mov (TANK ptr [ecx]).dir, edx            ; 转向即时生效

    ; 泥土减速：坦克中心格地形决定本 tick 速度
    mov eax, (TANK ptr [ecx]).x
    add eax, TANK_SIZE/2
    mov edx, (TANK ptr [ecx]).y
    add edx, TANK_SIZE/2
    invoke TileAtPx, eax, edx
    .if eax == TILE_DIRT
        mov eax, DIRT_SPEED
    .else
        mov eax, TANK_SPEED
    .endif
    mov spd, eax

    ; 计算新坐标
    mov ecx, ptank
    mov eax, (TANK ptr [ecx]).x
    mov nx, eax
    mov eax, (TANK ptr [ecx]).y
    mov ny, eax
    mov eax, dirL
    .if eax == DIR_UP
        mov ecx, spd
        sub ny, ecx
    .elseif eax == DIR_DOWN
        mov ecx, spd
        add ny, ecx
    .elseif eax == DIR_LEFT
        mov ecx, spd
        sub nx, ecx
    .else
        mov ecx, spd
        add nx, ecx
    .endif

    ; 目标位置整体阻挡判定：
    ; 挡板墙 = 矩形级 AABB（与渲染一致）；水 = 覆盖格任一整格阻挡
    invoke TankBlocked, nx, ny
    mov solid, eax

    mov ecx, ptank
    .if solid == 0
        mov edx, nx
        mov (TANK ptr [ecx]).x, edx
        mov edx, ny
        mov (TANK ptr [ecx]).y, edx
        ; 冰面判定：坦克中心格
        mov eax, (TANK ptr [ecx]).x
        add eax, TANK_SIZE/2
        mov edx, (TANK ptr [ecx]).y
        add edx, TANK_SIZE/2
        invoke TileAtPx, eax, edx
        .if eax == TILE_ICE
            invoke RngBelow, ICE_SLIDE_RNG   ; 0..4
            add eax, ICE_SLIDE_MIN           ; 6..10 tick
            mov ecx, ptank
            mov edx, dirL
            mov (TANK ptr [ecx]).sdir, edx
            mov (TANK ptr [ecx]).slide, eax
        .else
            mov ecx, ptank
            mov (TANK ptr [ecx]).slide, 0
        .endif
    .else
        mov (TANK ptr [ecx]).slide, 0        ; 撞墙立即停滑
    .endif
    ret
MoveTank endp

; ------------------------------------------------------------
; GameUpdate —— 推进一个逻辑 tick
; ------------------------------------------------------------
GameUpdate proc uses ebx esi edi
    local dirWanted:dword

    ; ---- 任一坦克死亡时按 R 重新开始 ----
    xor ecx, ecx                       ; 存活数
    xor edx, edx
GUR_Count:
    .if edx >= numPlayers
        jmp GUR_CountDone
    .endif
    mov eax, edx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ebx, (TANK ptr [eax]).alive
    add ecx, ebx
    inc edx
    jmp GUR_Count
GUR_CountDone:
    .if ecx < numPlayers && inputRestart != 0
        invoke GameInit
        ret
    .endif

    ; ---- 各玩家槽位：移动 / 冰面滑行 / 开火 ----
    mov fireHappened, 0
    xor ebx, ebx                       ; slot（跨 invoke 保持）
GU_Slot:
    .if ebx >= numPlayers
        jmp GU_SlotsDone
    .endif
    mov esi, ebx
    imul esi, esi, 20                  ; esi = slot*5*4（输入表字节偏移）
    ; 方向选择
    mov dirWanted, -1
    mov eax, inputTable[esi]
    .if eax != 0
        mov dirWanted, DIR_UP
    .else
        mov eax, inputTable[esi+4]
        .if eax != 0
            mov dirWanted, DIR_DOWN
        .else
            mov eax, inputTable[esi+8]
            .if eax != 0
                mov dirWanted, DIR_LEFT
            .else
                mov eax, inputTable[esi+12]
                .if eax != 0
                    mov dirWanted, DIR_RIGHT
                .endif
            .endif
        .endif
    .endif
    mov eax, dirWanted
    .if eax != -1
        invoke MoveTank, ebx, eax
    .else
        ; 无输入 -> 冰面滑行
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax
        mov eax, (TANK ptr [edx]).slide
        .if eax > 0
            dec (TANK ptr [edx]).slide
            mov eax, (TANK ptr [edx]).sdir
            invoke MoveTank, ebx, eax
        .endif
    .endif
    ; 开火（冷却 20 tick）
    mov eax, inputTable[esi+16]
    .if eax != 0
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax
        mov eax, (TANK ptr [edx]).fireCd
        .if eax == 0
            mov eax, (TANK ptr [edx]).alive
            .if eax != 0
                invoke SpawnBullet, ebx
                mov eax, ebx
                imul eax, eax, SIZEOF TANK
                add eax, offset tanks
                mov edx, eax
                mov (TANK ptr [edx]).fireCd, FIRE_CD
                .if ebx == 0
                    mov fireHappened, 1
                .endif
            .endif
        .endif
    .endif
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edx, eax
    mov eax, (TANK ptr [edx]).fireCd
    .if eax > 0
        dec (TANK ptr [edx]).fireCd
    .endif
    inc ebx
    jmp GU_Slot
GU_SlotsDone:

    ; ---- 子弹更新（edi = &bullets[ebx]，遍历顺序固定）----
    ; 每 tick 顺序：age -> X 轴(边界->地形) -> Y 轴(边界->地形) -> 坦克命中
    xor ebx, ebx
    mov edi, offset bullets
BulletTick:
    mov eax, (BULLET ptr [edi]).active
    .if eax != 0
        ; 0) 寿命
        inc (BULLET ptr [edi]).age
        mov eax, (BULLET ptr [edi]).age
        .if eax >= BULLET_LIFE
            mov (BULLET ptr [edi]).active, 0
            jmp BulletNext
        .endif
        ; 1) X 轴
        mov eax, (BULLET ptr [edi]).vx
        .if eax != 0
            add (BULLET ptr [edi]).x, eax
            ; 屏幕边界反弹（.if eax < 0 恒假，手写 test/jns）
            mov eax, (BULLET ptr [edi]).x
            test eax, eax
            jns BT_XPos
            ; x < 0：左边界反弹
            mov (BULLET ptr [edi]).x, 0
            neg (BULLET ptr [edi]).vx
            invoke BounceOne, edi
            jmp BT_XEnd
BT_XPos:
            .if eax > MAP_W - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).x, MAP_W - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vx
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi
                .if eax != 0            ; 1=钢 2=砖(已清子块)
                    ; 命中：逐像素回退直到弹体完全出墙再反弹。
                    ; （旧逻辑只回退一步：出膛/斜射嵌墙时回退后仍在墙里，
                    ;  弹在挡板内抖动耗尽反弹次数消失，或沿墙内滑出另一侧
                    ;  = "子弹穿墙" + "贴墙射弹无法反弹自杀" 的根因）
                    mov eax, (BULLET ptr [edi]).vx
                    .if eax > 0
BT_XBackR:
                        dec (BULLET ptr [edi]).x
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).x
                            .if eax > 0
                                jmp BT_XBackR
                            .endif
                        .endif
                    .else
BT_XBackL:
                        inc (BULLET ptr [edi]).x
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).x
                            .if eax < MAP_W - BULLET_SIZE_PX
                                jmp BT_XBackL
                            .endif
                        .endif
                    .endif
                    neg (BULLET ptr [edi]).vx       ; 反弹
                    invoke BounceOne, edi
                .endif
            .endif
BT_XEnd:
            mov eax, (BULLET ptr [edi]).active
            .if eax == 0
                jmp BulletNext          ; 反弹次数耗尽
            .endif
        .endif
        ; 2) Y 轴
        mov eax, (BULLET ptr [edi]).vy
        .if eax != 0
            add (BULLET ptr [edi]).y, eax
            mov eax, (BULLET ptr [edi]).y
            test eax, eax
            jns BT_YPos
            ; y < 0：上边界反弹
            mov (BULLET ptr [edi]).y, 0
            neg (BULLET ptr [edi]).vy
            invoke BounceOne, edi
            jmp BT_YEnd
BT_YPos:
            .if eax > MAP_H - BULLET_SIZE_PX
                mov (BULLET ptr [edi]).y, MAP_H - BULLET_SIZE_PX
                neg (BULLET ptr [edi]).vy
                invoke BounceOne, edi
            .else
                invoke BulletWallHit, edi
                .if eax != 0
                    ; 命中：逐像素回退到出墙（同 X 轴，防嵌墙抖动）
                    mov eax, (BULLET ptr [edi]).vy
                    .if eax > 0
BT_YBackD:
                        dec (BULLET ptr [edi]).y
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).y
                            .if eax > 0
                                jmp BT_YBackD
                            .endif
                        .endif
                    .else
BT_YBackU:
                        inc (BULLET ptr [edi]).y
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).y
                            .if eax < MAP_H - BULLET_SIZE_PX
                                jmp BT_YBackU
                            .endif
                        .endif
                    .endif
                    neg (BULLET ptr [edi]).vy       ; 反弹
                    invoke BounceOne, edi
                .endif
            .endif
BT_YEnd:
            mov eax, (BULLET ptr [edi]).active
            .if eax == 0
                jmp BulletNext
            .endif
        .endif
        ; 3) 命中坦克：任何坦克（含发射者自己——反弹弹自伤）
        ;    slot 0..3 顺序固定（确定性）
        xor esi, esi
TankHitLoop:
        .if esi >= MAX_PLAYERS
            jmp TankHitDone
        .endif
        mov eax, esi
        imul eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, eax                    ; edx = &tanks[esi]（此段无 invoke）
        mov eax, (TANK ptr [edx]).alive
        .if eax == 0
            jmp TankNext2
        .endif
        ; AABB：弹体 8x8 (x,y,+8,+8) vs 坦克 TANK_SIZE 见方
        mov eax, (TANK ptr [edx]).x
        add eax, TANK_SIZE
        mov ecx, (BULLET ptr [edi]).x
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).x
        mov ecx, (BULLET ptr [edi]).x
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).y
        add eax, TANK_SIZE
        mov ecx, (BULLET ptr [edi]).y
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).y
        mov ecx, (BULLET ptr [edi]).y
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        ; 命中：扣血、销毁子弹
        dec (TANK ptr [edx]).hp
        mov (BULLET ptr [edi]).active, 0
        mov eax, (TANK ptr [edx]).hp
        .if eax <= 0
            mov (TANK ptr [edx]).alive, 0
        .endif
        jmp BulletNext
TankNext2:
        inc esi
        jmp TankHitLoop
TankHitDone:
BulletNext:
    .endif
    add edi, SIZEOF BULLET
    inc ebx
    .if ebx < MAX_BULLETS
        jmp BulletTick
    .endif

    ; ---- 回合计分：只剩 1 辆存活 且 已毁坦克的子弹全部消失 ----
    ; 满足 -> 存活者 +1 分并定格 ROUND_PAUSE_TICKS；全灭 -> 不加分只定格
    .if roundOver != 0
        dec roundTimer
        .if roundTimer == 0
            call ResetTanks             ; 开新一轮（不清比分）
        .endif
        jmp GU_Done
    .endif
    ; 存活统计（slot 0..3 顺序固定）
    xor eax, eax                        ; eax = 存活数
    xor esi, esi                        ; esi = 幸存者槽位
    xor ebx, ebx
SC_Alive:
    .if ebx >= MAX_PLAYERS
        jmp SC_AliveDone
    .endif
    mov edx, ebx
    imul edx, edx, SIZEOF TANK
    add edx, offset tanks
    mov ecx, (TANK ptr [edx]).alive
    .if ecx != 0
        inc eax
        mov esi, ebx
    .endif
    inc ebx
    jmp SC_Alive
SC_AliveDone:
    .if eax > 1
        jmp GU_Done                     ; 多车存活：不判分
    .endif
    ; 已毁坦克的子弹是否全部消失（弹序固定）
    xor ebx, ebx
SC_Bul:
    .if ebx >= MAX_BULLETS
        jmp SC_BulDone
    .endif
    mov edx, ebx
    shl edx, 5                          ; * SIZEOF BULLET(32)
    add edx, offset bullets
    mov ecx, (BULLET ptr [edx]).active
    .if ecx != 0
        mov ecx, (BULLET ptr [edx]).owner
        imul ecx, ecx, SIZEOF TANK
        add ecx, offset tanks
        mov edx, (TANK ptr [ecx]).alive
        .if edx == 0
            jmp GU_Done                 ; 亡者的弹还在飞：不判分
        .endif
    .endif
    inc ebx
    jmp SC_Bul
SC_BulDone:
    ; 条件成立：幸存者加分（同归于尽不加）
    .if eax == 1 && roundScored == 0
        mov edx, esi
        imul edx, edx, SIZEOF TANK
        add edx, offset tanks
        inc (TANK ptr [edx]).score
    .endif
    mov roundScored, 1
    mov roundOver, 1
    mov roundTimer, ROUND_PAUSE_TICKS
GU_Done:
    ret
GameUpdate endp

end
