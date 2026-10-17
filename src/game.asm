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
FindOpenNeighbor PROTO :DWORD
DamageTankRaw PROTO :DWORD
EndPhantom   PROTO :DWORD
SndPlay      PROTO :DWORD
WallRectsHit PROTO :DWORD,:DWORD,:DWORD,:DWORD
TankBlocked  PROTO :DWORD,:DWORD
SpawnBullet  PROTO :DWORD
DamageTank   PROTO :DWORD
SpawnIce2x2  PROTO :DWORD

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
public matchOver
public maxRounds
public roundsPlayed
public shakeT
public cosTBL
public sinTBL
public pickupType
public pickupX
public pickupY
public laserN
public laserX
public laserY
public laserT
public prevN
public prevX
public prevY
public prevTank

.data
    tanks       TANK MAX_PLAYERS dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)
    spawnX      dd 4 dup (0)         ; 出生点像素坐标（字符画 'S'）
    spawnY      dd 4 dup (0)
    spawnCount  dd 0
    mapIndex    dd 0                 ; 当前 ARENA 编号
    keyTable    dd MAX_PLAYERS*KEY_PER dup (0)   ; [slot*KEY_PER+动作] VK 码: 0上1下2左3右4开火5技能
    inputTable  dd MAX_PLAYERS*KEY_PER dup (0)   ; [slot*KEY_PER+动作] 每 tick 快照 0/1
    prevUse     dd MAX_PLAYERS dup (0)  ; 技能键上帧状态（边沿检测）
    gTick       dd 0                 ; 全局 tick 计数（坦克 4/5 交替速度用）
    shakeT      dd 0                 ; 坦克爆炸震屏剩余 tick
    testLives   dd LIVES_INIT        ; 自测时置 1（击杀即淘汰，保持旧断言）
    cosTBL      dd 360 dup (?)       ; cos(a*PI/180)*1024
    sinTBL      dd 360 dup (?)       ; sin(a*PI/180)*1024
    itmp        dd ?
    c180        dd 180
    k1000       dd 1024
    tval        dd ?
    tval2       dd ?
    testNoShuffle dd 0               ; 自测置 1：不换图/不随机出生（保持 ARENA1 确定性）
    arenaBag    dd ARENA_COUNT dup (?) ; 本场比赛的地图洗牌袋（索引到 arenaTable）
    arenaBagPos dd ARENA_COUNT       ; 袋内游标（>=COUNT 触发重洗）
    maxRounds   dd 11                ; 比赛局数（11..51，人数页可调）
    roundsPlayed dd 0                 ; 已完成局数
    matchOver   dd 0                  ; 1=打满局数，显示胜者等待回菜单
    inputRestart dd 0                      ; R 重开（固定键）
    roundOver   dd 0                 ; 回合结束定格中
    roundTimer  dd 0                 ; 定格剩余 tick
    roundScored dd 0                 ; 本回合已判分
    seqSelf     dw 0                 ; 本端发包序号
    fireHappened dd 0                ; 本 tick P1 是否开火（发包 flag 用）
    rngState    dd 0                 ; xorshift32 状态
    ; ---- 技能系统 ----
    pickupType  dd 0                 ; 当前拾取物技能 id（0=无）
    pickupX     dd 0                 ; 拾取物左上像素
    pickupY     dd 0
    pickupTimer dd PICKUP_PERIOD      ; 距下次生成 tick
    mineCell    dd MAX_MINES dup (-1) ; 地雷格 index（-1=空槽）
    mineArm     dd MAX_MINES dup (0)  ; 生效倒计时 tick
    mineOwner   dd MAX_MINES dup (0)
    ; 激光渲染路径（发射后显示）与预览路径（瞄准中虚线）
    laserN      dd 0
    laserX      dd MAX_LASER_PTS dup (0)
    laserY      dd MAX_LASER_PTS dup (0)
    laserT      dd 0                 ; 显示剩余 tick
    prevN       dd 0
    prevX       dd MAX_LASER_PTS dup (0)
    prevY       dd MAX_LASER_PTS dup (0)
    prevTank    dd -1                ; 瞄准中的槽位（-1=无）

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
    stT1  db "T1_P1_X_ROW13(expect212)="
    stT2  db "T2_ACTIVE_AFTER_FIRE="
    stT3  db "T3_ACTIVE_AFTER_620TICKS="
    stT4  db "T4_MAP_UNCHANGED(expect1)="
    stT5  db "T5_NOT_ON_WATER(expect1)="
    stT6  db "T6_SLIDE_ENGAGED(expect6-15)="
    stT7  db "T7_P2_X(expect070)="
    stT8  db "T8_BULLETS_AFTER_15FIRE(expect<=10)="
    stT9a db "T9_P2_DEAD_AT_TICK="
    stT9b db "T9_P2_ALIVE(expect0)="
    stT9c db "T9_P2_HP(expect0)="
    stT10 db "T10_P1_SCORE(expect1)="       ; 22 字符（勿多打 1 字节）
    stT11 db "T11_DIRT_SLOW_DISP(expect4)="
    stT12 db "T12_SELFKILL_HP(expect2)="    ; 25 字符
    stT13a db "T13_SPAWN(expect1..8)="     ; 22 字符
    stT13b db "T13_PICKUP(expect3)="       ; 20 字符
    stT13c db "T13_USED(expect1)="         ; 18 字符
    stT14a db "T14_SHIELD_HP(expect3)="    ; 23 字符
    stT14b db "T14_ICE_CELLS(expect2)="    ; 23 字符
    stT15a db "T15_LASER_HP(expect2)="     ; 22 字符
    stT15b db "T15_LASER_PTS(expect2)="    ; 23 字符
    stT16a db "T16_REFL_HP(expect2)="      ; 21 字符
    stT16b db "T16_REFL_PTS(expect9)="     ; 22 字符
    stT17a db "T17_BLOCKED(expect1)="      ; 21 字符
    stT17b db "T17_PASSED(expect1)="       ; 20 字符
    stT17c db "T17_USES_LEFT(expect2)="    ; 23 字符
    stT18a db "T18_ARM_HP(expect3)="       ; 20 字符
    stT18b db "T18_BOOM_HP(expect2)="      ; 21 字符
    stT18c db "T18_MINE_GONE(expect1)="    ; 23 字符
    stT19a db "T19_NORM_DX(expect4)="      ; 21 字符
    stT19b db "T19_BOOST_DX(expect6)="     ; 22 字符
    stT19c db "T19_MUD_BOOST(expect4)="    ; 23 字符
    stT20a db "T20_SWAPPED(expect1)="      ; 21 字符
    stT20b db "T20_BUL_BACK(expect1)="     ; 22 字符
    stT20c db "T20_DIR(expect1)="          ; 17 字符
    stT20d db "T20_UNBOUND(expect1)="      ; 21 字符
    stT21a db "T21_WATER_BLOCK(expect1)="  ; 25 字符
    stT21b db "T21_IN_WATER(expect1)="     ; 23 字符
    stT21c db "T21_HOLD(expect1)="        ; 18 字符
    stT21d db "T21_OFF(expect0)="          ; 17 字符
    stT22a db "T22_PHANTOM_SET(expect1)="  ; 24 字符
    stT22b db "T22_SPLIT(expect1)="        ; 19 字符
    stT22c db "T22_IMMUNE(expect1)="       ; 20 字符
    stT22d db "T22_HIT_PH(expect1)="       ; 20 字符
    stT22e db "T22_2ND(expect1)="          ; 17 字符
    stT22f db "T22_CLEAR(expect1)="        ; 19 字符
    stT23a db "T23_LIVES_AFTER(expect2)="  ; 25 字符
    stT23b db "T23_ALIVE_RESPAWN(expect1)=" ; 27 字符
    stT23c db "T23_HP_RESPAWN(expect3)="   ; 24 字符
    stT23d db "T23_PROT_AFTER(expect120)=" ; 27 字符

.code

; ------------------------------------------------------------
; InitTrig —— FPU 生成 360 项整数三角表（cos/sin * 1000）
; ------------------------------------------------------------
InitTrig proc
    xor ecx, ecx
IT_L:
    mov itmp, ecx
    fild itmp
    fldpi
    fmulp st(1), st(0)              ; a*pi
    fdiv c180                     ; 弧度
    fcos
    fild k1000
    fmulp st(1), st(0)
    fistp cosTBL[ecx*4]
    fild itmp
    fldpi
    fmulp st(1), st(0)
    fdiv c180
    fsin
    fild k1000
    fmulp st(1), st(0)
    fistp sinTBL[ecx*4]
    inc ecx
    .if ecx < 360
        jmp IT_L
    .endif
    ret
InitTrig endp

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
; NextArena -- 本场比赛内不重复抽图：Fisher-Yates 洗牌后依次取；
; 袋子取空（局数 > 地图数）重新洗牌开始新一轮
; 返回 eax = arenaTable 索引
; ------------------------------------------------------------
NextArena proc uses ebx ecx edx esi edi
    mov eax, arenaBagPos
    .if eax >= ARENA_COUNT
        ; 重洗：bag[i] = i；从尾向前与随机位交换
        xor ebx, ebx
NA_Fill:
        mov arenaBag[ebx*4], ebx
        inc ebx
        .if ebx < ARENA_COUNT
            jmp NA_Fill
        .endif
        mov ecx, ARENA_COUNT          ; i = COUNT..1
NA_Shuf:
        .if ecx <= 1
            jmp NA_ShufDone
        .endif
        dec ecx
        mov eax, ecx
        inc eax
        invoke RngBelow, eax          ; j = RngBelow(i+1)
        mov edi, eax                  ; j
        mov esi, ecx                  ; i
        mov eax, arenaBag[esi*4]
        mov edx, arenaBag[edi*4]
        mov arenaBag[esi*4], edx
        mov arenaBag[edi*4], eax
        jmp NA_Shuf
NA_ShufDone:
        mov arenaBagPos, 0
    .endif
    mov eax, arenaBagPos
    mov ecx, arenaBag[eax*4]
    inc arenaBagPos
    mov eax, ecx
    ret
NextArena endp

; ------------------------------------------------------------
; PickRandomSpawns -- 每局随机出生点：从空地格随机挑 numPlayers 个，
; 两两曼哈顿距离 >= 6 格（避免开局贴脸），500 次重试后放弃
; （保留 ParseArena 的原出生点作兜底）
; ------------------------------------------------------------
PickRandomSpawns proc uses ebx ecx edx esi edi
    local picked:dword, tries:dword, cand:dword, cx0:dword, cy0:dword
    mov picked, 0
    mov tries, 0
PRS_Try:
    mov eax, picked
    .if eax >= numPlayers
        jmp PRS_Done
    .endif
    mov eax, tries
    .if eax >= 500
        jmp PRS_Done                  ; 放弃：保留 ParseArena 原出生点
    .endif
    inc tries
    invoke RngBelow, COLS*ROWS
    mov cand, eax
    mov ebx, eax
    movzx eax, mapData[ebx]
    .if eax != TILE_EMPTY
        jmp PRS_Try                   ; 只允许空地格
    .endif
    mov eax, cand
    xor edx, edx
    mov ecx, COLS
    div ecx                           ; eax=行 edx=列
    .if eax < 1 || eax >= ROWS-1
        jmp PRS_Try                   ; 边界内缩 1 格
    .endif
    .if edx < 1 || edx >= COLS-1
        jmp PRS_Try
    .endif
    mov cy0, eax
    mov cx0, edx
    ; 与已选出生点两两距离 >= 6 格
    xor ebx, ebx
PRS_Dist:
    .if ebx >= picked
        jmp PRS_DistOk
    .endif
    mov eax, spawnY[ebx*4]
    add eax, TANK_SIZE/2
    shr eax, 5
    sub eax, cy0
    .if eax < 0
        neg eax
    .endif
    mov ecx, eax
    mov eax, spawnX[ebx*4]
    add eax, TANK_SIZE/2
    shr eax, 5
    sub eax, cx0
    .if eax < 0
        neg eax
    .endif
    add ecx, eax
    .if ecx < 6
        jmp PRS_Try                   ; 太近：重挑
    .endif
    inc ebx
    jmp PRS_Dist
PRS_DistOk:
    mov eax, picked
    mov ecx, cx0
    imul ecx, ecx, CELL
    add ecx, (CELL-TANK_SIZE)/2
    mov spawnX[eax*4], ecx
    mov ecx, cy0
    imul ecx, ecx, CELL
    add ecx, (CELL-TANK_SIZE)/2
    mov spawnY[eax*4], ecx
    inc picked
    jmp PRS_Try
PRS_Done:
    ret
PickRandomSpawns endp

; ------------------------------------------------------------
; ResetTanks -- reset all tank slots, place tank0/tank1 at spawns,
; clear bullet pool (shared by GameInit and SelfTest)
; 每局换图（本场不重复）+ 随机出生点；自测模式保持 ARENA1 固定
; ------------------------------------------------------------
ResetTanks proc uses ebx esi edi
    mov eax, testNoShuffle
    .if eax == 0
        invoke NextArena
        mov mapIndex, eax
        mov spawnCount, 0
        mov ecx, arenaTable[eax*4]
        invoke ParseArena, ecx
        invoke PickRandomSpawns
    .endif
    lea esi, tanks
    xor ebx, ebx
RTLoop:
    mov (TANK ptr [esi]).alive, 0
    mov (TANK ptr [esi]).hp, TANK_HP
    mov (TANK ptr [esi]).fireCd, 0
    mov (TANK ptr [esi]).slide, 0
    mov (TANK ptr [esi]).sdir, 0
    ; 技能状态清零
    mov (TANK ptr [esi]).skill, SKILL_NONE
    mov (TANK ptr [esi]).effOn, 0
    mov (TANK ptr [esi]).shieldT, 0
    mov (TANK ptr [esi]).effT, 0
    mov (TANK ptr [esi]).wallPass, 0
    mov (TANK ptr [esi]).swapBul, -1
    mov (TANK ptr [esi]).aimT, 0
    mov (TANK ptr [esi]).aimSkill, SKILL_NONE
    mov (TANK ptr [esi]).lastCell, -1
    mov (TANK ptr [esi]).phantomX, 0
    mov (TANK ptr [esi]).phantomY, 0
    mov (TANK ptr [esi]).phantomUses, 0
    mov eax, testLives
    mov (TANK ptr [esi]).lives, eax
    mov (TANK ptr [esi]).respawnT, 0
    mov (TANK ptr [esi]).protT, 0
    add esi, SIZEOF TANK
    inc ebx
    .if ebx < MAX_PLAYERS
        jmp RTLoop
    .endif
    ; 地雷 / 激光 / 拾取物清空
    xor eax, eax
    dec eax                           ; eax = -1
    xor ebx, ebx
RT_Mines:
    .if ebx >= MAX_MINES
        jmp RT_MinesDone
    .endif
    mov mineCell[ebx*4], eax
    mov mineArm[ebx*4], 0
    inc ebx
    jmp RT_Mines
RT_MinesDone:
    mov pickupType, 0
    mov eax, PICKUP_PERIOD
    mov pickupTimer, eax
    mov laserN, 0
    mov laserT, 0
    mov prevN, 0
    mov prevTank, -1
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
    mov esi, ebx
    .if numPlayers == 2 && ebx == 1
        mov esi, 3
    .endif
    mov eax, esi
    mov eax, spawnX[eax*4]
    mov (TANK ptr [edi]).spawnX, eax     ; 记录本回合出生点（重生用）
    mov eax, esi
    mov eax, spawnY[eax*4]
    mov (TANK ptr [edi]).spawnY, eax
    ; 朝向按出生位半场：上半场朝下、下半场朝上（随机出生点适用）
    mov eax, (TANK ptr [edi]).spawnY
    add eax, TANK_SIZE/2
    .if eax < MAP_H/2
        mov (TANK ptr [edi]).dir, DIR_DOWN
        mov (TANK ptr [edi]).spawnDir, DIR_DOWN
    .else
        mov (TANK ptr [edi]).dir, DIR_UP
        mov (TANK ptr [edi]).spawnDir, DIR_UP
    .endif
    mov (TANK ptr [edi]).alive, 1
    ; 出生保护：出生位嵌墙/出界 -> 挪到最近开放格（防卡边界）
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).x
    mov edx, (TANK ptr [eax]).y
    invoke TankBlocked, ecx, edx
    .if eax != 0
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov ecx, (TANK ptr [eax]).y
        add ecx, TANK_SIZE/2
        shr ecx, 5
        imul ecx, ecx, COLS
        mov edx, (TANK ptr [eax]).x
        add edx, TANK_SIZE/2
        shr edx, 5
        add ecx, edx
        invoke FindOpenNeighbor, ecx
        .if nbIdx != 99
            mov eax, ebx
            imul eax, eax, SIZEOF TANK
            add eax, offset tanks
            mov edi, eax
            mov eax, nbIdx
            xor edx, edx
            mov ecx, COLS
            div ecx
            imul eax, eax, CELL          ; 行 -> y
            add eax, (CELL-TANK_SIZE)/2
            mov (TANK ptr [edi]).y, eax
            mov eax, edx                 ; 列 -> x
            imul eax, eax, CELL
            add eax, (CELL-TANK_SIZE)/2
            mov (TANK ptr [edi]).x, eax
        .endif
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
; InitKeyDefaults -- 默认键位表（设置界面/人数页容器可覆盖）
; P1 WASD+空格+Q  P2 方向键+Enter+右Shift  P3 IJKL+U+O  P4 TFGH+B+V
; 动作顺序：0上 1下 2左 3右 4开火 5技能
; ------------------------------------------------------------
InitKeyDefaults proc
    mov keyTable[0],  VK_W
    mov keyTable[4],  VK_S
    mov keyTable[8],  VK_A
    mov keyTable[12], VK_D
    mov keyTable[16], VK_SPACE
    mov keyTable[20], VK_Q
    mov keyTable[24], VK_UP
    mov keyTable[28], VK_DOWN
    mov keyTable[32], VK_LEFT
    mov keyTable[36], VK_RIGHT
    mov keyTable[40], VK_RETURN
    mov keyTable[44], VK_RSHIFT
    mov keyTable[48], VK_I
    mov keyTable[52], VK_K
    mov keyTable[56], VK_J
    mov keyTable[60], VK_L
    mov keyTable[64], VK_U
    mov keyTable[68], VK_O
    mov keyTable[72], VK_T
    mov keyTable[76], VK_G
    mov keyTable[80], VK_F
    mov keyTable[84], VK_H
    mov keyTable[88], VK_B
    mov keyTable[92], VK_V
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
    call InitTrig                    ; 无头路径不经过 GameInit，补三角表
    call InitKeyDefaults             ; 无头路径不经过 UiInit，补默认键位
    mov testLives, 1                 ; 旧断言基于"击杀即淘汰"，自测固定单命
    mov testNoShuffle, 1             ; 自测固定 ARENA1 + 原出生点（确定性）
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
    ; （KEY_PER=6 后 slot1 左键 = 24 + 2*4 = 32）
T7Start:
    call ResetTanks
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov inputTable[32], 1
    invoke AdvanceTicks, 20
    mov inputTable[32], 0
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
    ; 单命制下流弹会误伤 P1 导致判分统计为 0 —— 清空弹池
    mov edi, offset bullets
    xor ecx, ecx
T9ClrB:
    mov (BULLET ptr [edi]).active, 0
    add edi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp T9ClrB
    .endif
    invoke LogStr, offset stT9a, 19
    invoke LogNum, esi                             ; kill tick (<300)
    invoke LogStr, offset stT9b, 21
    invoke LogNum, tanks[1*SIZEOF TANK].alive      ; expect 0
    invoke LogStr, offset stT9c, 18
    invoke LogNum, tanks[1*SIZEOF TANK].hp         ; expect 0
    invoke AdvanceTicks, 350                       ; 等 5s 判分定格结束（300 tick）开新一轮
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
    mov tanks[0*SIZEOF TANK].x, 947      ; 贴 col30 挡板（972..980），25px 车身
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
T12Done:
    ; T13: 技能框架 —— 补给生成 / 拾取 / 技能键边沿发动
    call ResetTanks
    ; a) 生成：2 tick 后应出现 1..8 号拾取物
    mov pickupType, 0
    mov pickupTimer, 2
    invoke AdvanceTicks, 3
    mov eax, pickupType
    mov logVal, eax
    invoke LogStr, offset stT13a, 22
    invoke LogNum, logVal                ; expect 1..8
    ; b) 拾取：拾取物放到 P1 中心格 -> 1 tick 覆盖持有
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov pickupX, 32+(CELL-PICKUP_SIZE)/2
    mov pickupY, 416+(CELL-PICKUP_SIZE)/2
    mov pickupType, 3                    ; 反射激光
    invoke AdvanceTicks, 1
    mov eax, tanks[0*SIZEOF TANK].skill
    mov logVal, eax
    invoke LogStr, offset stT13b, 20
    invoke LogNum, logVal                ; expect 3
    ; c) 使用键边沿：inputTable[20] 0->1 发动冰盾
    mov prevUse[0], 0
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    invoke GameUpdate
    mov eax, tanks[0*SIZEOF TANK].effOn
    mov logVal, eax
    invoke LogStr, offset stT13c, 18
    invoke LogNum, logVal                ; expect 1 (EFF_SHIELD)
T13cDone:
    ; T14: 冰盾 —— 挡一次伤害 + 坦克周围生成 2x2 冰面
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 发动冰盾
    mov inputTable[20], 0
    ; 一颗弹压在 P1 身上（owner=P2）-> 冰盾应抵挡
    mov bullets[0].active, 1
    mov bullets[0].owner, 1
    mov eax, tanks[0*SIZEOF TANK].x
    mov bullets[0].x, eax
    mov eax, tanks[0*SIZEOF TANK].y
    mov bullets[0].y, eax
    mov bullets[0].vx, 0
    mov bullets[0].vy, 0
    mov bullets[0].bounces, 0
    mov bullets[0].age, 0
    invoke GameUpdate
    mov eax, tanks[0*SIZEOF TANK].hp
    mov logVal, eax
    invoke LogStr, offset stT14a, 23
    invoke LogNum, logVal                ; expect 3（被盾挡下）
    ; 冰面：走廊行 (1,13)(2,13) 空地应变冰；(1,14)(2,14) 是墙不动
    xor eax, eax
    .if mapData[13*COLS+1] == TILE_ICE
        inc eax
    .endif
    .if mapData[13*COLS+2] == TILE_ICE
        inc eax
    .endif
    mov logVal, eax
    invoke LogStr, offset stT14b, 23
    invoke LogNum, logVal                ; expect 2
T14Done:
    ; T15: 激光炮 —— 0.7s 后穿墙直线激光，路径上坦克（墙后也）受伤
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov tanks[0*SIZEOF TANK].alive, 1
    ; 墙后目标：col10(x320..351) 放一堵钢墙，tank1 在 x=400
    mov mapData[13*COLS+10], TILE_STEEL
    mov tanks[1*SIZEOF TANK].x, 400
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_LASER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 进入瞄准
    mov inputTable[20], 0
    invoke AdvanceTicks, 41              ; 0.7s 到 -> 发射
    mov eax, tanks[1*SIZEOF TANK].hp
    mov logVal, eax
    invoke LogStr, offset stT15a, 22
    invoke LogNum, logVal                ; expect 2（穿墙击中）
    mov eax, laserN
    mov logVal, eax
    invoke LogStr, offset stT15b, 23
    invoke LogNum, logVal                ; expect 2（两点直线路径）
    mov mapData[13*COLS+10], TILE_EMPTY  ; 还原走廊
T15Done:
    ; T16: 反射激光 —— 预览反弹路径，0.7s 后全路径伤害（含反弹段）
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, DIR_RIGHT
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].x, 200
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_REFLASER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 进入瞄准（预览生成）
    mov inputTable[20], 0
    invoke AdvanceTicks, 41              ; 到时发射
    mov eax, tanks[1*SIZEOF TANK].hp
    mov logVal, eax
    invoke LogStr, offset stT16a, 21
    invoke LogNum, logVal                ; expect 2
    mov eax, laserN
    .if eax != 9                         ; 起点 + 7 反弹 + 终点 = 9
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT16b, 22
    invoke LogNum, logVal                ; expect 1（9 折点 = 满 7 次反射）
T16Done:
    ; T17: 穿墙术 —— 无技能被墙挡；发动后穿过并计一次
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov mapData[13*COLS+6], TILE_STEEL   ; col6 挡路（x192..223）
    ; a) 无技能：右移被挡
    mov inputTable[12], 1
    invoke AdvanceTicks, 40
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    .if eax > 180
        mov eax, 0                       ; 穿过去了 = 失败
    .else
        mov eax, 1                       ; 被挡在墙前
    .endif
    mov logVal, eax
    invoke LogStr, offset stT17a, 21
    invoke LogNum, logVal                ; expect 1（被挡）
    ; b) 发动穿墙术 -> 穿过墙且剩余次数 3-1=2
    mov tanks[0*SIZEOF TANK].skill, SK_GHOST
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov inputTable[12], 1
    invoke AdvanceTicks, 30
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    .if eax > 200
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT17b, 20
    invoke LogNum, logVal                ; expect 1（已穿过）
    mov eax, tanks[0*SIZEOF TANK].wallPass
    mov logVal, eax
    invoke LogStr, offset stT17c, 23
    invoke LogNum, logVal                ; expect 2（用掉 1 次）
    mov mapData[13*COLS+6], TILE_EMPTY
T17Done:
    ; T18: 地雷 —— 2s 后生效；生效时踩雷者（含自己）受伤；引爆后消失
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_MINE
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 布雷（就埋在自己脚下）
    mov inputTable[20], 0
    invoke AdvanceTicks, 60              ; 未到 2s
    mov eax, tanks[0*SIZEOF TANK].hp
    mov logVal, eax
    invoke LogStr, offset stT18a, 20
    invoke LogNum, logVal                ; expect 3（未生效）
    invoke AdvanceTicks, 61              ; 到时 -> 仍踩在雷上 -> 自伤
    mov eax, tanks[0*SIZEOF TANK].hp
    mov logVal, eax
    invoke LogStr, offset stT18b, 21
    invoke LogNum, logVal                ; expect 2（含自己）
    mov eax, mineCell[0]
    .if eax == -1
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT18c, 23
    invoke LogNum, logVal                ; expect 1（引爆后消失）
T18Done:
    ; T19: 燃油加速 —— 常速 2->3；泥地减速叠加：1->2
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    ; a) 常速一步
    mov inputTable[12], 1
    invoke GameUpdate
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 96
    mov logVal, eax
    invoke LogStr, offset stT19a, 21
    invoke LogNum, logVal                ; expect 2
    ; b) 发动燃油加速 -> 一步 3px
    mov tanks[0*SIZEOF TANK].skill, SK_NITRO
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].x      ; 发动后位置（前进一步 = 98）
    mov ebx, eax                         ; ebx = 步前 x（ebx 跨 invoke 保存）
    mov inputTable[12], 1
    invoke GameUpdate
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, ebx
    mov logVal, eax
    invoke LogStr, offset stT19b, 22
    invoke LogNum, logVal                ; expect 3
    ; c) 泥地叠加：当前格设为泥，再走一步应 2px（(1*3+1)/2）
    mov tanks[0*SIZEOF TANK].x, 96       ; 重置到 col3
    mov mapData[13*COLS+3], TILE_DIRT
    mov inputTable[12], 1
    invoke GameUpdate
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 96
    mov logVal, eax
    invoke LogStr, offset stT19c, 23
    invoke LogNum, logVal                ; expect 2（泥1 + 加速叠加）
    mov mapData[13*COLS+3], TILE_EMPTY
T19Done:
    ; T20: 换位术 —— 发射子弹 -> 再按使用键与之换位（方向继承）
    ; 用 UP 发射：旧版 SpawnBullet 把 vy 候选（-6）当弹索引返回的 bug
    ; 只有 UP/DOWN 才暴露（RIGHT 碰巧返回 0 正确），此场景即回归锁
    call ResetTanks
    mov ebx, 2                           ; 清 col3 rows 2..16 做向上弹道
T20Clr:
    mov eax, ebx
    imul eax, eax, COLS
    add eax, 3
    mov mapData[eax], TILE_EMPTY
    inc ebx
    .if ebx <= 16
        jmp T20Clr
    .endif
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, DIR_UP
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov tanks[0*SIZEOF TANK].skill, SK_SWAP
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 发射换位弹（占配额）
    mov inputTable[20], 0
    invoke AdvanceTicks, 20              ; 弹飞 ~120px（y 408 -> 288）
    mov inputTable[20], 1
    invoke GameUpdate                    ; 换位
    mov inputTable[20], 0
    ; a) 坦克已瞬移到子弹处（x=96, y~282）
    mov eax, tanks[0*SIZEOF TANK].y
    .if eax < 350
        mov eax, tanks[0*SIZEOF TANK].x
        .if eax == 96
            mov eax, 1
        .else
            mov eax, 0
        .endif
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT20a, 21
    invoke LogNum, logVal                ; expect 1
    ; b) 子弹回到坦克原位附近（原位 x=96+6=102，UP 场景 x 不变）
    mov eax, bullets[0].x
    .if eax >= 100 && eax <= 140
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT20b, 22
    invoke LogNum, logVal                ; expect 1
    ; c) 坦克朝向 = 子弹方向（UP = 0）
    mov eax, tanks[0*SIZEOF TANK].dir
    .if eax == DIR_UP
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT20c, 17
    invoke LogNum, logVal                ; expect 1
    ; d) 换位后绑定解除
    mov eax, tanks[0*SIZEOF TANK].swapBul
    .if eax == -1
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT20d, 21
    invoke LogNum, logVal                ; expect 1
T20Done:
    ; T21: 驭水术 —— 无技能被水挡；发动后行走水上；到期保护；离水失效
    call ResetTanks
    mov mapData[13*COLS+5], TILE_WATER   ; row13 走廊 col5/col6 设水（测后还原）
    mov mapData[13*COLS+6], TILE_WATER
    mov tanks[0*SIZEOF TANK].x, 96       ; col3
    mov tanks[0*SIZEOF TANK].y, 416      ; row13
    mov tanks[0*SIZEOF TANK].alive, 1
    ; a) 无技能：右移 25 tick 被水挡在水前（col5 水 160..191，坦克 25px
    ;    最深 x=135；4/5 交替步进落点不固定，断言区间+中心格非水）
    mov inputTable[12], 1
    invoke AdvanceTicks, 25
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    .if eax > 140 || eax < 120
        mov eax, 0
    .else
        mov eax, tanks[0*SIZEOF TANK].x
        add eax, TANK_SIZE/2
        mov ecx, tanks[0*SIZEOF TANK].y
        add ecx, TANK_SIZE/2
        invoke TileAtPx, eax, ecx
        .if eax == TILE_WATER
            mov eax, 0                  ; 中心在水里 = 没被挡住
        .else
            mov eax, 1
        .endif
    .endif
    mov logVal, eax
    invoke LogStr, offset stT21a, 25
    invoke LogNum, logVal                ; expect 1（被挡在水边）
    ; b) 发动驭水 -> 穿进水域（15 tick 约 67px，中心格必须在水上）
    mov tanks[0*SIZEOF TANK].skill, SK_WATER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov inputTable[12], 1
    invoke AdvanceTicks, 15
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    add eax, TANK_SIZE/2
    mov ecx, tanks[0*SIZEOF TANK].y
    add ecx, TANK_SIZE/2
    invoke TileAtPx, eax, ecx
    .if eax == TILE_WATER
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT21b, 22
    invoke LogNum, logVal                ; expect 1（水上行走）
    ; c) 到期保护：中心仍在水上 -> 延寿不掉效
    mov tanks[0*SIZEOF TANK].effT, 1
    invoke AdvanceTicks, 1
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_WATER
    .if eax != 0
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT21c, 18
    invoke LogNum, logVal                ; expect 1（水上延寿）
    ; d) 离开水 -> 到期即失效
    mov tanks[0*SIZEOF TANK].x, 96       ; 传回 row13 走廊（非水）
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].effT, 1
    invoke AdvanceTicks, 1
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_WATER
    mov logVal, eax
    invoke LogStr, offset stT21d, 17
    invoke LogNum, logVal                ; expect 0（已失效）
    mov mapData[13*COLS+5], TILE_EMPTY   ; 还原走廊
    mov mapData[13*COLS+6], TILE_EMPTY
T21Done:
    ; T22: 定格术 —— 虚影免伤 / 虚影被打=受伤+消失 / 2 次 / 收回清技能
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].skill, SK_PHANTOM
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 放虚影 #1
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    .if eax != 0
    mov eax, tanks[0*SIZEOF TANK].phantomX
    .if eax == 96
        mov eax, 1
        jmp T22aOk
    .endif
    .endif
    mov eax, 0
T22aOk:
    mov logVal, eax
    invoke LogStr, offset stT22a, 25
    invoke LogNum, logVal                ; expect 1（虚影就位在原地）
    ; b) 实像自由移动 -> 与虚影分离
    mov inputTable[12], 1
    invoke AdvanceTicks, 15
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].x
    .if eax > 110
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT22b, 19
    invoke LogNum, logVal                ; expect 1（实像远离虚影）
    ; c) 敌弹打实像位置 -> 虚影期间免疫
    mov edi, offset bullets
    xor ecx, ecx
ST22Clr:
    mov (BULLET ptr [edi]).active, 0
    add edi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp ST22Clr
    .endif
    mov bullets[0].active, 1
    mov eax, tanks[0*SIZEOF TANK].x
    mov bullets[0].x, eax
    mov bullets[0].y, 420
    mov bullets[0].vx, 0
    mov bullets[0].vy, 0
    invoke AdvanceTicks, 2
    mov eax, tanks[0*SIZEOF TANK].hp
    .if eax == TANK_HP
        mov eax, 1
    .else
        mov eax, 0
    .endif
    mov logVal, eax
    invoke LogStr, offset stT22c, 20
    invoke LogNum, logVal                ; expect 1（实像免伤）
    ; d) 弹移到虚影位置 -> 视为被击中（掉血）+ 虚影消失
    mov bullets[0].x, 104
    invoke AdvanceTicks, 2
    mov eax, tanks[0*SIZEOF TANK].hp
    .if eax == TANK_HP - 1
        mov eax, tanks[0*SIZEOF TANK].effOn
        and eax, EFF_PHANTOM
        .if eax == 0
            mov eax, 1
            jmp T22dOk
        .endif
    .endif
    mov eax, 0
T22dOk:
    mov logVal, eax
    invoke LogStr, offset stT22d, 20
    invoke LogNum, logVal                ; expect 1（虚影被打=受伤+消失）
    ; e) 再按 = 第二只虚影（uses 2->1->0）
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    .if eax != 0
    mov eax, tanks[0*SIZEOF TANK].phantomUses
    .if eax == 0
        mov eax, 1
        jmp T22eOk
    .endif
    .endif
    mov eax, 0
T22eOk:
    mov logVal, eax
    invoke LogStr, offset stT22e, 17
    invoke LogNum, logVal                ; expect 1（第二只虚影，次数用尽）
    ; f) 再按收回 -> 虚影消失且技能用尽清空
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    .if eax == 0
    mov eax, tanks[0*SIZEOF TANK].skill
    .if eax == SKILL_NONE
        mov eax, 1
        jmp T22fOk
    .endif
    .endif
    mov eax, 0
T22fOk:
    mov logVal, eax
    invoke LogStr, offset stT22f, 19
    invoke LogNum, logVal                ; expect 1（收回+清空）
T22Done:
    ; T23: 多命制 —— 3 命击杀后 1.5s 原地重生（满血+保护），命尽才淘汰
    mov testLives, 3
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
T23Kill:
    .if esi >= 300
        jmp T23KillDone
    .endif
    invoke GameUpdate
    inc esi
    cmp tanks[1*SIZEOF TANK].alive, 0
    je T23KillDone
    jmp T23Kill
T23KillDone:
    mov inputTable[16], 0
    invoke LogStr, offset stT23a, 25
    invoke LogNum, tanks[1*SIZEOF TANK].lives      ; expect 2（扣一命）
    invoke AdvanceTicks, 120                       ; 1.5s 重生 + 30 tick 保护
    invoke LogStr, offset stT23b, 27
    invoke LogNum, tanks[1*SIZEOF TANK].alive      ; expect 1（已重生）
    invoke LogStr, offset stT23c, 24
    invoke LogNum, tanks[1*SIZEOF TANK].hp         ; expect 3（满血）
    invoke LogStr, offset stT23d, 27
    invoke LogNum, tanks[1*SIZEOF TANK].protT      ; expect 120（保护剩余）
    mov testLives, 1                               ; 恢复（保险）
    call CloseLog
    ret
SelfTestRun endp

; ------------------------------------------------------------
; GameInit —— 随机选图解析 + 重置坦克/子弹
; tank0 = 出生点0（左上，朝下），tank1 = 出生点3（右下，朝上）
; ------------------------------------------------------------
GameInit proc uses ebx esi edi
    call InitTrig                   ; 三角表（每次初始化，幂等）
    ; xorshift32 seed (first time only)
    .if rngState == 0
        invoke GetTickCount
        mov rngState, eax
    .endif
    mov arenaBagPos, ARENA_COUNT    ; 新比赛：重置洗牌袋（首局触发重洗）
    call ResetTanks                  ; 选图(不重复)+随机出生点+布坦克
    ; 键位默认值改由 UiInit 启动时设一次；
    ; 此处不再重置，避免人数页自定义键位每局被洗掉
    mov tanks[0*SIZEOF TANK].score, 0
    mov tanks[1*SIZEOF TANK].score, 0
    mov tanks[2*SIZEOF TANK].score, 0
    mov tanks[3*SIZEOF TANK].score, 0
    mov roundsPlayed, 0
    mov matchOver, 0
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
    test eax, eax
    jns WRH_RrOk
    xor eax, eax                  ; r0-1 < 0 -> clamp 0（否则无符号比较恒"超界"，
WRH_RrOk:                         ;  整个 3x3 邻域被跳过 = 左/上边界碰撞失效）
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
    test eax, eax
    jns WRH_CcOk
    xor eax, eax                  ; 同上 clamp（c0=0 时 cc 起点 -1）
WRH_CcOk:
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
        mov eax, 2                   ; 2=水（驭水术可穿，墙 1 不可混判）
        ret
    .endif
TB_CNext:
    inc cc
    jmp TB_Col
TankBlocked endp

; ------------------------------------------------------------
; ShiftToOpen -- 坦克重生位嵌墙时，迁移到最近的开放格（复用出生保护逻辑）
; ------------------------------------------------------------
ShiftToOpen proc uses ebx ecx edx esi edi slotIdx: dword
    mov esi, slotIdx
    imul esi, esi, SIZEOF TANK
    add esi, offset tanks
    mov ecx, (TANK ptr [esi]).y
    add ecx, TANK_SIZE/2
    shr ecx, 5
    imul ecx, ecx, COLS
    mov edx, (TANK ptr [esi]).x
    add edx, TANK_SIZE/2
    shr edx, 5
    add ecx, edx
    invoke FindOpenNeighbor, ecx
    .if nbIdx != 99
        mov eax, nbIdx
        xor edx, edx
        mov ecx, COLS
        div ecx                        ; eax=行 edx=列
        imul eax, eax, CELL
        add eax, (CELL-TANK_SIZE)/2
        mov (TANK ptr [esi]).y, eax
        mov eax, edx
        imul eax, eax, CELL
        add eax, (CELL-TANK_SIZE)/2
        mov (TANK ptr [esi]).x, eax
    .endif
    ret
ShiftToOpen endp

; ============================================================
; 技能系统
; ============================================================

; ------------------------------------------------------------
; DamageTankRaw -- 真实扣血（无任何免疫；虚影被击中/子弹直接命中）
; 多命制：血尽 -> lives-1 进入重生倒计时；lives 用尽彻底淘汰。
; 重生保护期（protT>0）完全免伤。
; ------------------------------------------------------------
DamageTankRaw proc uses ebx slotIdx: dword
    mov ebx, slotIdx
    imul ebx, ebx, SIZEOF TANK
    add ebx, offset tanks
    mov eax, (TANK ptr [ebx]).protT
    .if eax > 0
        ret                          ; 重生保护期：免伤
    .endif
    dec (TANK ptr [ebx]).hp
    mov eax, (TANK ptr [ebx]).hp
    .if eax <= 0
        mov (TANK ptr [ebx]).alive, 0
        dec (TANK ptr [ebx]).lives
        mov eax, RESPAWN_TICKS
        mov (TANK ptr [ebx]).respawnT, eax
        ; 死亡清技能/效果（重生后重新拾取）
        mov (TANK ptr [ebx]).skill, SKILL_NONE
        mov (TANK ptr [ebx]).effOn, 0
        mov (TANK ptr [ebx]).shieldT, 0
        mov (TANK ptr [ebx]).effT, 0
        mov (TANK ptr [ebx]).wallPass, 0
        mov (TANK ptr [ebx]).swapBul, -1
        mov (TANK ptr [ebx]).aimT, 0
        mov (TANK ptr [ebx]).aimSkill, SKILL_NONE
        mov (TANK ptr [ebx]).lastCell, -1
        mov (TANK ptr [ebx]).phantomUses, 0
        invoke SndPlay, 2            ; 坦克被击败：爆炸音
        mov shakeT, 15               ; 震屏 0.25s
    .endif
    mov eax, 1
    ret
DamageTankRaw endp

; ------------------------------------------------------------
; DamageTank —— 统一受伤入口：定格虚影免疫 > 冰盾抵挡 > 扣血
; 入参：slotIdx；返回 eax = 1 实际扣血 / 0 被冰盾挡下 / 2 虚影免疫
; ------------------------------------------------------------
DamageTank proc uses ebx slotIdx: dword
    mov ebx, slotIdx
    imul ebx, ebx, SIZEOF TANK
    add ebx, offset tanks
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_PHANTOM
        mov eax, 2                   ; 定格虚影期间本体免疫一切伤害
        ret
    .endif
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_SHIELD
        ; 冰盾抵挡：消耗护盾 + 坦克周围生成 2x2 冰面
        and (TANK ptr [ebx]).effOn, not EFF_SHIELD
        invoke SpawnIce2x2, slotIdx
        mov eax, 0
        ret
    .endif
    invoke DamageTankRaw, slotIdx
    ret
DamageTank endp

; ------------------------------------------------------------
; EndPhantom -- 结束虚影（手动/超时/被击中共用）
; 虚影次数用尽时同时清空持有技能
; ------------------------------------------------------------
EndPhantom proc uses ebx slotIdx: dword
    mov ebx, slotIdx
    imul ebx, ebx, SIZEOF TANK
    add ebx, offset tanks
    and (TANK ptr [ebx]).effOn, not EFF_PHANTOM
    mov (TANK ptr [ebx]).effT, 0
    mov eax, (TANK ptr [ebx]).phantomUses
    .if eax == 0
        mov (TANK ptr [ebx]).skill, SKILL_NONE
    .endif
    ret
EndPhantom endp

; ------------------------------------------------------------
; SpawnIce2x2 —— 以坦克中心格为左上角生成 2x2 冰面
; 只把空地格变成冰（不破坏墙/水/泥/边界）
; ------------------------------------------------------------
SpawnIce2x2 proc uses ebx edi slotIdx: dword
    local cc:dword, rr:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).x
    add ecx, TANK_SIZE/2
    shr ecx, 5
    mov cc, ecx
    mov edx, (TANK ptr [eax]).y
    add edx, TANK_SIZE/2
    shr edx, 5
    mov rr, edx
    xor edi, edi                     ; dy
SI2_Row:
    .if edi >= 2
        ret
    .endif
    xor ebx, ebx                     ; dx
SI2_Col:
    .if ebx >= 2
        inc edi
        jmp SI2_Row
    .endif
    mov eax, cc
    add eax, ebx
    .if eax >= COLS
        jmp SI2_Next
    .endif
    mov ecx, rr
    add ecx, edi
    .if ecx >= ROWS
        jmp SI2_Next
    .endif
    imul ecx, ecx, COLS
    add ecx, eax
    movzx eax, mapData[ecx]
    .if eax == TILE_EMPTY
        mov mapData[ecx], TILE_ICE
    .endif
SI2_Next:
    inc ebx
    jmp SI2_Col
SpawnIce2x2 endp

; ------------------------------------------------------------
; SegmentDamage —— 折线路段（轴对齐）上的所有存活坦克受击
; ------------------------------------------------------------
SegmentDamage proc uses ebx esi edi pXs: dword, pYs: dword, nPts: dword
    local x0:dword, x1:dword, y0:dword, y1:dword
    local ymin:dword, ymax:dword, xmin:dword, xmax:dword
    local tright:dword, tbottom:dword
    .if nPts < 2
        ret
    .endif
    xor esi, esi                     ; 坦克槽位
SD_Tank:
    .if esi >= MAX_PLAYERS
        ret
    .endif
    mov eax, esi
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edi, eax
    cmp (TANK ptr [edi]).alive, 0
    je SD_Next
    xor ebx, ebx                     ; 线段起点下标
SD_Seg:
    mov eax, nPts
    dec eax
    .if ebx >= eax
        jmp SD_Next
    .endif
    mov ecx, pXs
    mov eax, [ecx+ebx*4]
    mov x0, eax
    mov eax, [ecx+ebx*4+4]
    mov x1, eax
    mov ecx, pYs
    mov eax, [ecx+ebx*4]
    mov y0, eax
    mov eax, [ecx+ebx*4+4]
    mov y1, eax
    mov eax, y0
    mov ecx, y1
    .if ecx < eax
        mov ymin, ecx
    .else
        mov ymin, eax
    .endif
    .if ecx > eax
        mov ymax, ecx
    .else
        mov ymax, eax
    .endif
    mov eax, x0
    mov ecx, x1
    .if ecx < eax
        mov xmin, ecx
    .else
        mov xmin, eax
    .endif
    .if ecx > eax
        mov xmax, ecx
    .else
        mov xmax, eax
    .endif
    ; 坦克矩形 [tx,tx+TS) x [ty,ty+TS)
    mov eax, (TANK ptr [edi]).x          ; tx
    mov ecx, (TANK ptr [edi]).y          ; ty
    mov tright, eax
    add tright, TANK_SIZE
    mov tbottom, ecx
    add tbottom, TANK_SIZE
    ; 垂直段：x0==x1（注意 .if 里 reg+const 是内存寻址，边界先算好）
    mov edx, x0
    .if edx == x1
        .if edx >= eax && edx < tright
            mov edx, ymin
            .if edx < tbottom
                mov edx, ymax
                .if edx > ecx
                    push esi
                    push edi
                    invoke DamageTank, esi
                    pop edi
                    pop esi
                    jmp SD_Next          ; 每辆坦克只伤一次
                .endif
            .endif
        .endif
    .else
        ; 水平段：y0==y1
        mov edx, y0
        .if edx >= ecx && edx < tbottom
            mov edx, xmin
            .if edx < tright
                mov edx, xmax
                .if edx > eax
                    push esi
                    push edi
                    invoke DamageTank, esi
                    pop edi
                    pop esi
                    jmp SD_Next
                .endif
            .endif
        .endif
    .endif
    inc ebx
    jmp SD_Seg
SD_Next:
    inc esi
    jmp SD_Tank
SegmentDamage endp

; ------------------------------------------------------------
; SimReflectPath —— 从坦克炮口模拟反弹弹道（最多 7 次反射）
; 出参：写入 pXs/pYs 折点数组（含起点/反弹点/终点），
;       pHits 非空时对路径命中的坦克置 1；
;       返回 eax = 折点数
; ------------------------------------------------------------
SimReflectPath proc uses ebx esi edi slotIdx: dword, pXs: dword, pYs: dword, pHits: dword
    local x:dword, y:dword, vx:dword, vy:dword
    local bn:dword, steps:dword, pc:dword, ptank:dword, sgn:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ptank, eax
    .if pHits != 0
        mov edi, pHits
        mov dword ptr [edi], 0
        mov dword ptr [edi+4], 0
        mov dword ptr [edi+8], 0
        mov dword ptr [edi+12], 0
    .endif
    ; 起点 = 炮口（与 SpawnBullet 公式一致）
    mov ecx, ptank
    mov eax, (TANK ptr [ecx]).dir
    mov edx, (TANK ptr [ecx]).x
    mov ebx, (TANK ptr [ecx]).y
    .if eax == DIR_UP
        mov x, edx
        add x, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov y, ebx
        sub y, BULLET_SIZE_PX
        mov vx, 0
        mov vy, -BULLET_SPEED
    .elseif eax == DIR_DOWN
        mov x, edx
        add x, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov y, ebx
        add y, TANK_SIZE
        mov vx, 0
        mov vy, BULLET_SPEED
    .elseif eax == DIR_LEFT
        mov x, edx
        sub x, BULLET_SIZE_PX
        mov y, ebx
        add y, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov vx, -BULLET_SPEED
        mov vy, 0
    .else
        mov x, edx
        add x, TANK_SIZE
        mov y, ebx
        add y, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov vx, BULLET_SPEED
        mov vy, 0
    .endif
    ; 第 0 点 = 炮口
    mov eax, pXs
    mov ecx, x
    mov [eax], ecx
    mov eax, pYs
    mov ecx, y
    mov [eax], ecx
    mov pc, 1
    mov bn, 0
    mov steps, 0
SRP_Step:
    mov eax, steps
    inc eax
    mov steps, eax
    .if eax > 9000                       ; 7 次反弹全图横穿约 6600 步
        jmp SRP_Done
    .endif
    ; ---- X 轴 ----
    mov eax, vx
    .if eax != 0
        ; sgn = vx 的符号（vx 可为负：勿用 .if > 0，无符号比较恒真）
        mov sgn, 1
        test eax, eax
        js SRP_XNeg
        jmp SRP_XSgnDone
SRP_XNeg:
        mov sgn, -1
SRP_XSgnDone:
        mov eax, x
        add eax, sgn
        mov x, eax
        invoke WallRectsHit, x, y, BULLET_SIZE_PX, BULLET_SIZE_PX
        .if eax != 0
            ; 逐像素回退到弹体完全出墙再反弹（出膛嵌墙时与真实弹道一致）
SRP_XBack:
            mov eax, x
            sub eax, sgn
            mov x, eax
            test eax, eax
            js SRP_XBackDone           ; 已贴左界
            cmp eax, MAP_W - BULLET_SIZE_PX
            ja SRP_XBackDone           ; 已贴右界
            invoke WallRectsHit, x, y, BULLET_SIZE_PX, BULLET_SIZE_PX
            .if eax != 0
                jmp SRP_XBack
            .endif
SRP_XBackDone:
            mov eax, vx
            neg eax
            mov vx, eax
            mov eax, bn
            inc eax
            mov bn, eax
            ; 记录反弹折点
            mov ecx, pc
            .if ecx < MAX_LASER_PTS
                mov eax, pXs
                mov edx, x
                mov [eax+ecx*4], edx
                mov eax, pYs
                mov edx, y
                mov [eax+ecx*4], edx
                inc pc
            .endif
            ; 反射次数用尽 -> 终止（eax 被记录代码破坏，从 bn 重载）
            mov eax, bn
            .if eax >= LASER_BOUNCE_MAX   ; 第 7 次反弹后停止
                jmp SRP_Done
            .endif
        .endif
    .endif
    ; ---- Y 轴 ----
    mov eax, vy
    .if eax != 0
        mov sgn, 1
        test eax, eax
        js SRP_YNeg
        jmp SRP_YSgnDone
SRP_YNeg:
        mov sgn, -1
SRP_YSgnDone:
        mov eax, y
        add eax, sgn
        mov y, eax
        invoke WallRectsHit, x, y, BULLET_SIZE_PX, BULLET_SIZE_PX
        .if eax != 0
            ; 逐像素回退到弹体完全出墙再反弹（同 X 轴）
SRP_YBack:
            mov eax, y
            sub eax, sgn
            mov y, eax
            test eax, eax
            js SRP_YBackDone           ; 已贴上界
            cmp eax, MAP_H - BULLET_SIZE_PX
            ja SRP_YBackDone           ; 已贴下界
            invoke WallRectsHit, x, y, BULLET_SIZE_PX, BULLET_SIZE_PX
            .if eax != 0
                jmp SRP_YBack
            .endif
SRP_YBackDone:
            mov eax, vy
            neg eax
            mov vy, eax
            mov eax, bn
            inc eax
            mov bn, eax
            mov ecx, pc
            .if ecx < MAX_LASER_PTS
                mov eax, pXs
                mov edx, x
                mov [eax+ecx*4], edx
                mov eax, pYs
                mov edx, y
                mov [eax+ecx*4], edx
                inc pc
            .endif
            ; 反射次数用尽 -> 终止（eax 被记录代码破坏，从 bn 重载）
            mov eax, bn
            .if eax >= LASER_BOUNCE_MAX   ; 第 7 次反弹后停止
                jmp SRP_Done
            .endif
        .endif
    .endif
    ; ---- 路径上的坦克标记（含自己，穿透不停）----
    .if pHits != 0
        mov edi, pHits                    ; edi = 命中标记数组
        xor esi, esi
SRP_Hit:
        .if esi >= MAX_PLAYERS
            jmp SRP_HitDone
        .endif
        mov eax, esi
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        ; AABB：模拟弹体 8x8 vs 坦克 21
        mov ecx, (TANK ptr [eax]).x
        cmp x, ecx
        jl SRP_HNext                      ; x < tx
        mov edx, x
        add edx, BULLET_SIZE_PX
        cmp edx, ecx
        jle SRP_HNext                     ; x+8 <= tx
        mov ecx, (TANK ptr [eax]).y
        cmp y, ecx
        jl SRP_HNext
        mov edx, y
        add edx, BULLET_SIZE_PX
        cmp edx, ecx
        jle SRP_HNext
        mov dword ptr [edi+esi*4], 1
SRP_HNext:
        inc esi
        jmp SRP_Hit
SRP_HitDone:
    .endif
    jmp SRP_Step
SRP_Done:
    ; 终点折点
    mov ecx, pc
    .if ecx < MAX_LASER_PTS
        mov eax, pXs
        mov edx, x
        mov [eax+ecx*4], edx
        mov eax, pYs
        mov edx, y
        mov [eax+ecx*4], edx
        inc pc
    .endif
    mov eax, pc
    ret
SimReflectPath endp

; ------------------------------------------------------------
; MuzzleEdge —— 直线激光终点（炮口沿朝向到地图边界）
; 写入 laserX/Y[0..1]，laserN=2
; ------------------------------------------------------------
MuzzleEdge proc uses ebx ecx edx slotIdx: dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).dir
    mov edx, (TANK ptr [eax]).x
    mov ebx, (TANK ptr [eax]).y
    .if ecx == DIR_UP
        mov eax, edx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserX[0], eax
        mov laserX[4], eax               ; 垂直段 x 恒定
        mov eax, ebx
        sub eax, BULLET_SIZE_PX          ; 炮口在坦克上缘之外
        mov laserY[0], eax
        mov laserY[4], 0
    .elseif ecx == DIR_DOWN
        mov eax, edx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserX[0], eax
        mov eax, ebx
        add eax, TANK_SIZE
        mov laserY[0], eax
        mov eax, edx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserX[4], eax
        mov laserY[4], MAP_H
    .elseif ecx == DIR_LEFT
        mov eax, edx
        sub eax, BULLET_SIZE_PX
        mov laserX[0], eax
        mov eax, ebx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserY[0], eax
        mov laserX[4], 0
        mov eax, ebx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserY[4], eax
    .else
        mov eax, edx
        add eax, TANK_SIZE
        mov laserX[0], eax
        mov eax, ebx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserY[0], eax
        mov laserX[4], MAP_W
        mov eax, ebx
        add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
        mov laserY[4], eax
    .endif
    mov laserN, 2
    ret
MuzzleEdge endp

; ------------------------------------------------------------
; RefreshLaserPreview —— 瞄准期间每 tick 刷新虚线预览
; ------------------------------------------------------------
RefreshLaserPreview proc uses ebx slotIdx: dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).aimSkill
    mov eax, slotIdx
    mov prevTank, eax
    .if ecx == SK_LASER
        invoke MuzzleEdge, slotIdx
        mov eax, laserX[0]
        mov prevX[0], eax
        mov eax, laserY[0]
        mov prevY[0], eax
        mov eax, laserX[4]
        mov prevX[4], eax
        mov eax, laserY[4]
        mov prevY[4], eax
        mov prevN, 2
    .elseif ecx == SK_REFLASER
        invoke SimReflectPath, slotIdx, offset prevX, offset prevY, 0
        mov prevN, eax
    .endif
    ret
RefreshLaserPreview endp

; ------------------------------------------------------------
; FireAimedLaser —— 瞄准到时：生成激光路径并造成伤害
; ------------------------------------------------------------
FireAimedLaser proc uses ebx slotIdx: dword
    local hits[4]:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).aimSkill
    .if ecx == SK_LASER
        invoke MuzzleEdge, slotIdx
        invoke SegmentDamage, offset laserX, offset laserY, laserN
    .elseif ecx == SK_REFLASER
        lea ebx, hits
        invoke SimReflectPath, slotIdx, offset laserX, offset laserY, ebx
        mov laserN, eax
        invoke SegmentDamage, offset laserX, offset laserY, laserN
    .endif
    mov laserT, 24                   ; 0.4s 显示
    ; 清瞄准状态与预览
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov (TANK ptr [eax]).aimT, 0
    mov (TANK ptr [eax]).aimSkill, SKILL_NONE
    mov prevTank, -1
    mov prevN, 0
    ret
FireAimedLaser endp

; ------------------------------------------------------------
; PlaceMine —— 在坦克中心格布雷（非水域才可）
; 返回 eax = 1 成功 / 0 失败（技能不消耗）
; ------------------------------------------------------------
PlaceMine proc uses ebx ecx edx slotIdx: dword
    xor ecx, ecx
PM_Slot:
    .if ecx >= MAX_MINES
        xor eax, eax
        ret
    .endif
    cmp mineCell[ecx*4], -1
    je PM_Found
    inc ecx
    jmp PM_Slot
PM_Found:
    mov ebx, slotIdx
    imul ebx, ebx, SIZEOF TANK
    add ebx, offset tanks
    mov eax, (TANK ptr [ebx]).x
    add eax, TANK_SIZE/2
    shr eax, 5
    mov edx, (TANK ptr [ebx]).y
    add edx, TANK_SIZE/2
    shr edx, 5
    imul edx, edx, COLS
    add eax, edx                     ; 中心格 index
    movzx edx, mapData[eax]
    .if edx == TILE_WATER
        xor eax, eax                 ; 水域不可布
        ret
    .endif
    mov mineCell[ecx*4], eax
    mov mineArm[ecx*4], MINE_ARM_TICKS
    mov eax, slotIdx
    mov mineOwner[ecx*4], eax
    mov eax, 1
    ret
PlaceMine endp

; ------------------------------------------------------------
; DoSwap —— 换位术第二段：坦克与绑定子弹换位
; 坦克出现在子弹处且朝向 = 子弹方向；子弹回到坦克原位原方向继续飞
; ------------------------------------------------------------
DoSwap proc uses ebx esi edi slotIdx: dword
    local ptank:dword, nx:dword, ny:dword, oldx:dword, oldy:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ptank, eax
    mov eax, (TANK ptr [eax]).swapBul
    .if eax == -1                    ; 无绑定（勿写 < 0：MASM 无符号恒假）
        ret
    .endif
    mov edi, eax
    shl eax, 5
    add eax, offset bullets
    mov esi, eax                     ; esi = &bullets[bi]
    cmp (BULLET ptr [esi]).active, 0
    jne DS_Live
    ; 子弹已消失：解除绑定
    mov ecx, ptank
    mov (TANK ptr [ecx]).swapBul, -1
    ret
DS_Live:
    ; 坦克目标 = 子弹中心对齐
    mov eax, (BULLET ptr [esi]).x
    add eax, BULLET_SIZE_PX/2
    sub eax, TANK_SIZE/2
    mov nx, eax
    mov eax, (BULLET ptr [esi]).y
    add eax, BULLET_SIZE_PX/2
    sub eax, TANK_SIZE/2
    mov ny, eax
    ; 硬边界防御：子弹贴边飞行时换位目标可能越界
    mov eax, nx
    test eax, eax
    js DS_GiveUp
    cmp eax, MAP_W - TANK_SIZE
    ja DS_GiveUp
    mov eax, ny
    test eax, eax
    js DS_GiveUp
    cmp eax, MAP_H - TANK_SIZE
    ja DS_GiveUp
    invoke TankBlocked, nx, ny
    .if eax != 0
        ; 目标被挡（子弹贴墙缝隙）-> 放弃换位
DS_GiveUp:
        mov ecx, ptank
        mov (TANK ptr [ecx]).swapBul, -1
        ret
    .endif
    ; TankBlocked 破坏了 esi（只保护 ebx）-> 重新装载子弹指针
    mov eax, edi
    shl eax, 5
    add eax, offset bullets
    mov esi, eax
    mov ecx, ptank
    mov eax, (TANK ptr [ecx]).x
    mov oldx, eax
    mov eax, (TANK ptr [ecx]).y
    mov oldy, eax
    mov eax, nx
    mov (TANK ptr [ecx]).x, eax
    mov eax, ny
    mov (TANK ptr [ecx]).y, eax
    ; 坦克朝向 = 子弹方向（vx/vy 可为负：勿用 .if > 0，MASM 无符号恒真）
    mov eax, (BULLET ptr [esi]).vx
    test eax, eax
    jz DS_ChkVy
    js DS_VxNeg
    mov (TANK ptr [ecx]).dir, DIR_RIGHT
    jmp DS_DirDone
DS_VxNeg:
    mov (TANK ptr [ecx]).dir, DIR_LEFT
    jmp DS_DirDone
DS_ChkVy:
    mov eax, (BULLET ptr [esi]).vy
    test eax, eax
    js DS_VyNeg
    mov (TANK ptr [ecx]).dir, DIR_DOWN
    jmp DS_DirDone
DS_VyNeg:
    mov (TANK ptr [ecx]).dir, DIR_UP
DS_DirDone:
    ; 子弹回到坦克原位（速度不变 = 方向与原来相同）
    mov eax, oldx
    add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).x, eax
    mov eax, oldy
    add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).y, eax
    mov ecx, ptank
    mov (TANK ptr [ecx]).swapBul, -1
    ret
DoSwap endp

; ------------------------------------------------------------
; TryUseSkill —— 技能键边沿触发：按持有技能分发
; ------------------------------------------------------------
TryUseSkill proc uses ebx esi edi slotIdx: dword
    local ptank:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ptank, eax
    mov eax, (TANK ptr [eax]).alive
    .if eax == 0
        ret
    .endif
    mov ecx, ptank
    ; 换位术第二段优先（skill 已在发射时消耗）
    mov eax, (TANK ptr [ecx]).swapBul
    .if eax != -1
        invoke DoSwap, slotIdx
        ret
    .endif
    ; 定格虚影激活中：再按 = 收回虚影（skill 保留给第二只）
    mov eax, (TANK ptr [ecx]).effOn
    .if eax & EFF_PHANTOM
        invoke EndPhantom, slotIdx
        ret
    .endif
    mov eax, (TANK ptr [ecx]).skill
    .if eax == SKILL_NONE
        ret
    .endif
    .if eax == SK_ICE_SHIELD
        mov ecx, ptank
        mov edx, (TANK ptr [ecx]).effOn
        or edx, EFF_SHIELD
        mov (TANK ptr [ecx]).effOn, edx
    .elseif eax == SK_LASER || eax == SK_REFLASER
        mov ecx, ptank
        mov edx, (TANK ptr [ecx]).skill
        mov (TANK ptr [ecx]).aimSkill, edx
        mov (TANK ptr [ecx]).aimT, LASER_AIM_TICKS
        invoke RefreshLaserPreview, slotIdx
    .elseif eax == SK_GHOST
        mov ecx, ptank
        mov edx, (TANK ptr [ecx]).effOn
        or edx, EFF_GHOST
        mov (TANK ptr [ecx]).effOn, edx
        mov (TANK ptr [ecx]).effT, GHOST_TICKS
        mov (TANK ptr [ecx]).wallPass, GHOST_USES
    .elseif eax == SK_MINE
        invoke PlaceMine, slotIdx
        .if eax == 0
            ret                      ; 水域/雷槽满：不消耗
        .endif
    .elseif eax == SK_NITRO
        mov ecx, ptank
        mov edx, (TANK ptr [ecx]).effOn
        or edx, EFF_NITRO
        mov (TANK ptr [ecx]).effOn, edx
        mov (TANK ptr [ecx]).effT, NITRO_TICKS
    .elseif eax == SK_SWAP
        invoke SpawnBullet, slotIdx
        .if eax == -1
            ret                      ; 弹池/配额满：不消耗（SpawnBullet 失败返回 -1）
        .endif
        mov ecx, ptank
        mov (TANK ptr [ecx]).swapBul, eax
    .elseif eax == SK_WATER
        mov ecx, ptank
        mov edx, (TANK ptr [ecx]).effOn
        or edx, EFF_WATER
        mov (TANK ptr [ecx]).effOn, edx
        mov (TANK ptr [ecx]).effT, WATER_TICKS
    .elseif eax == SK_PHANTOM
        ; 定格术：原地放虚影（2 次）；skill 保留供收回/第二只
        mov ecx, ptank
        mov eax, (TANK ptr [ecx]).phantomUses
        .if eax <= 0
            ; 拾取后首次发动：初始化 2 次（回合重置为 0）
            mov (TANK ptr [ecx]).phantomUses, PHANTOM_USES
        .endif
        dec (TANK ptr [ecx]).phantomUses
        mov eax, (TANK ptr [ecx]).x
        mov (TANK ptr [ecx]).phantomX, eax
        mov eax, (TANK ptr [ecx]).y
        mov (TANK ptr [ecx]).phantomY, eax
        mov edx, (TANK ptr [ecx]).effOn
        or edx, EFF_PHANTOM
        mov (TANK ptr [ecx]).effOn, edx
        mov (TANK ptr [ecx]).effT, PHANTOM_TICKS
        invoke SndPlay, 5            ; 虚影音
        ret                          ; 不走通用消耗（虚影期间 skill 保留）
    .endif
    ; 消耗技能
    mov ecx, ptank
    mov (TANK ptr [ecx]).skill, SKILL_NONE
    ret
TryUseSkill endp

; ------------------------------------------------------------
; EffTick —— 每槽位每 tick：效果倒计时 + 到期保护
; 穿墙到期仍在墙里 / 驭水到期仍在水里 -> 延寿 1 tick 直到离开
; ------------------------------------------------------------
EffTick proc uses ebx slotIdx: dword
    mov ebx, slotIdx
    imul ebx, ebx, SIZEOF TANK
    add ebx, offset tanks
    mov eax, (TANK ptr [ebx]).shieldT
    .if eax > 0
        dec (TANK ptr [ebx]).shieldT
        .if eax == 1
            ; 护盾到时（未被消耗）也清除
            and (TANK ptr [ebx]).effOn, not EFF_SHIELD
        .endif
    .endif
    mov eax, (TANK ptr [ebx]).effT
    .if eax > 0
        dec (TANK ptr [ebx]).effT
    .endif
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_GHOST
        mov eax, (TANK ptr [ebx]).effT
        .if eax == 0
            mov ecx, (TANK ptr [ebx]).x
            mov edx, (TANK ptr [ebx]).y
            invoke WallRectsHit, ecx, edx, TANK_SIZE, TANK_SIZE
            .if eax != 0
                mov (TANK ptr [ebx]).effT, 1
            .else
                and (TANK ptr [ebx]).effOn, not EFF_GHOST
            .endif
        .endif
    .endif
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_WATER
        mov eax, (TANK ptr [ebx]).effT
        .if eax == 0
            mov ecx, (TANK ptr [ebx]).x
            add ecx, TANK_SIZE/2
            mov edx, (TANK ptr [ebx]).y
            add edx, TANK_SIZE/2
            invoke TileAtPx, ecx, edx
            .if eax == TILE_WATER
                mov (TANK ptr [ebx]).effT, 1
            .else
                and (TANK ptr [ebx]).effOn, not EFF_WATER
            .endif
        .endif
    .endif
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_NITRO
        mov eax, (TANK ptr [ebx]).effT
        .if eax == 0
            and (TANK ptr [ebx]).effOn, not EFF_NITRO
        .endif
    .endif
    ; 定格虚影 6s 到：自动收回（坦克本就在实像位置）
    mov eax, (TANK ptr [ebx]).effOn
    .if eax & EFF_PHANTOM
        mov eax, (TANK ptr [ebx]).effT
        .if eax == 0
            invoke EndPhantom, slotIdx
            invoke SndPlay, 5        ; 收回音
        .endif
    .endif
    ret
EffTick endp

; ------------------------------------------------------------
; SpawnPickup —— 随机挑一个可行格生成技能拾取物
; 可行 = 空地/冰/泥（非水非墙）；重试最多 128 次
; ------------------------------------------------------------
SpawnPickup proc uses ebx ecx edx
    mov ebx, 128
SP_Try:
    invoke RngBelow, COLS*ROWS
    mov ecx, eax
    movzx eax, mapData[ecx]
    .if eax == TILE_EMPTY || eax == TILE_ICE || eax == TILE_DIRT
        ; 生成：随机挑一种技能
        invoke RngBelow, SKILL_COUNT
        inc eax
        mov pickupType, eax
        mov eax, ecx
        xor edx, edx
        mov ebx, COLS
        div ebx                      ; eax=行, edx=列
        mov eax, edx
        shl eax, 5
        add eax, (CELL - PICKUP_SIZE)/2
        mov pickupX, eax
        mov eax, ecx
        xor edx, edx
        mov ebx, COLS
        div ebx
        shl eax, 5
        add eax, (CELL - PICKUP_SIZE)/2
        mov pickupY, eax
        mov eax, PICKUP_PERIOD
        mov pickupTimer, eax
        ret
    .endif
    dec ebx
    .if ebx > 0
        jmp SP_Try
    .endif
    mov pickupTimer, 60               ; 本轮无可行格：1s 后重试（防永久卡死）
    ret
SpawnPickup endp

; ------------------------------------------------------------
; SpawnBullet —— 按坦克朝向生成一颗子弹（§3：同屏每坦 <=10 发）
; 入参：ownerIdx = 玩家编号；弹池满 / 该坦弹满 / 坦克死亡则忽略
; ------------------------------------------------------------
SpawnBullet proc uses ebx esi edi ownerIdx: dword
    local ptank:dword, bulIdx:dword
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
        mov eax, -1                  ; 配额满（调用方检查 == -1）
        ret
    .endif

    ; 坦克指针
    mov eax, edi
    mov ebx, SIZEOF TANK
    imul ebx, eax
    add ebx, offset tanks
    mov ptank, ebx
    mov eax, (TANK ptr [ebx]).alive
    .if eax == 0
        mov eax, -1                  ; 坦克死亡
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
    mov eax, -1                      ; 弹池满
    ret

SlotFound:
    mov eax, ecx
    mov bulIdx, eax                 ; 先存槽索引（ecx 马上被 vy 候选占用）
    ; 任意角度：vx = cos(dir)*SPD/1000；vy = sin(dir)*SPD/1000
    mov eax, (TANK ptr [ebx]).dir
    mov ecx, cosTBL[eax*4]
    imul ecx, BULLET_SPEED
    mov tval, ecx
    mov ecx, sinTBL[eax*4]
    imul ecx, BULLET_SPEED
    mov tval2, ecx
    mov eax, tval
    sar eax, 10
    mov (BULLET ptr [esi]).vx, eax
    mov eax, tval2
    sar eax, 10
    mov (BULLET ptr [esi]).vy, eax
    ; 炮口：坦克中心沿朝向前移 TANK_SIZE/2 + 4（炮管尖端）
    mov eax, (TANK ptr [ebx]).x
    add eax, TANK_SIZE/2
    mov tval, eax                    ; 中心 x
    mov eax, (TANK ptr [ebx]).dir
    mov ecx, cosTBL[eax*4]
    imul ecx, TANK_SIZE/2+4
    sar ecx, 10
    mov eax, ecx
    add eax, tval
    sub eax, (BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).x, eax
    mov eax, (TANK ptr [ebx]).y
    add eax, TANK_SIZE/2
    mov tval, eax                    ; 中心 y
    mov eax, (TANK ptr [ebx]).dir
    mov ecx, sinTBL[eax*4]
    imul ecx, TANK_SIZE/2+4
    sar ecx, 10
    mov eax, ecx
    add eax, tval
    sub eax, (BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).y, eax
    mov (BULLET ptr [esi]).owner, edi
    mov (BULLET ptr [esi]).active, 1
    mov (BULLET ptr [esi]).bounces, 0
    mov (BULLET ptr [esi]).age, 0
    invoke SndPlay, 1                ; 开炮音
    mov eax, bulIdx                  ; 返回子弹池索引（换位术绑定用）
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
; TankTerrain —— 坦克所压地形（四角采样：任一角在泥/冰格即触发，
; 与视觉一致——履带压上就算）；返回 TILE_DIRT/TILE_ICE/TILE_EMPTY
; ------------------------------------------------------------
cornerX    dd 2, TANK_SIZE-3, 2, TANK_SIZE-3
cornerY    dd 2, 2, TANK_SIZE-3, TANK_SIZE-3
TankTerrain proc uses ebx ecx edx esi slotIdx: dword
    mov esi, slotIdx
    imul esi, esi, SIZEOF TANK
    add esi, offset tanks
    xor ebx, ebx
TT_L:
    mov eax, (TANK ptr [esi]).x
    add eax, cornerX[ebx*4]
    mov ecx, (TANK ptr [esi]).y
    add ecx, cornerY[ebx*4]
    invoke TileAtPx, eax, ecx
    .if eax == TILE_DIRT || eax == TILE_ICE
        ret
    .endif
    inc ebx
    .if ebx < 4
        jmp TT_L
    .endif
    mov eax, TILE_EMPTY
    ret
TankTerrain endp

; ------------------------------------------------------------
; MoveTank —— 坦克移动（水/钢/砖实心，冰/泥/空地可通行）
; 冰面：位移成功且中心格是冰 -> 刷新滑行 tick（6..10）与滑行方向
; 泥土：中心格是泥土 -> 本 tick 速度 DIRT_SPEED（1），否则 TANK_SPEED
; ------------------------------------------------------------
MoveTank proc ownerIdx: dword, wantDir: dword
    local nx:dword, ny:dword, solid:dword, ptank:dword, dirL:dword
    local moveF:dword
    local spd:dword
    ; ptank = &tanks[ownerIdx]（跨 invoke 保存，用局部变量存指针）
    mov eax, ownerIdx
    mov ecx, SIZEOF TANK
    imul ecx, eax
    add ecx, offset tanks
    mov ptank, ecx
    mov eax, wantDir
    mov dirL, eax
    ; 360 度转向：左键逆时针、右键顺时针（转向 tick 不位移）
    mov ecx, ptank
    .if dirL == 2
        mov eax, (TANK ptr [ecx]).dir
        sub eax, TURN_SPEED
        .if eax < 0
            add eax, 360
        .endif
        mov (TANK ptr [ecx]).dir, eax
        ret
    .elseif dirL == 3
        mov eax, (TANK ptr [ecx]).dir
        add eax, TURN_SPEED
        .if eax >= 360
            sub eax, 360
        .endif
        mov (TANK ptr [ecx]).dir, eax
        ret
    .endif

    mov ecx, ptank
    mov edx, dirL
    mov (TANK ptr [ecx]).dir, edx            ; 转向即时生效

    ; 泥土减速：坦克四角任一压泥格即减速（视觉一致）
    mov eax, ownerIdx
    invoke TankTerrain, eax
    .if eax == TILE_DIRT
        mov eax, DIRT_SPEED
    .else
        ; 4/5 交替（平均 4.5 = 子弹 6 的 75%）：奇数 tick 用 HI
        mov eax, TANK_SPEED
        mov edx, gTick
        test edx, 1
        jz MT_SpdEven
        mov eax, TANK_SPEED_HI
MT_SpdEven:
    .endif
    ; 燃油加速：+2（4->6, 5->7 平均 6.5 ≈ +44%），与泥地减速叠加
    mov ecx, ptank
    mov edx, (TANK ptr [ecx]).effOn
    .if edx & EFF_NITRO
        add eax, 2
    .endif
    mov spd, eax

    ; 计算新坐标
    mov ecx, ptank
    mov eax, (TANK ptr [ecx]).x
    mov nx, eax
    mov eax, (TANK ptr [ecx]).y
    mov ny, eax
    ; 三角位移：nx += cos(dir)*spd*moveF/1000；ny += sin(dir)*spd*moveF/1000
    ; dirL==0 前进（moveF=1）、dirL==1 后退（moveF=-1）
    mov eax, dirL
    mov moveF, 1
    .if eax == 1
        mov moveF, -1
    .endif
    mov ecx, ptank                 ; 速度段破坏了 ecx，重载
    mov eax, (TANK ptr [ecx]).dir
    mov ecx, cosTBL[eax*4]
    imul ecx, spd
    mov edx, moveF
    imul ecx, edx
    sar ecx, 10
    add nx, ecx
    mov ecx, ptank                 ; nx 计算破坏了 ecx，重载
    mov eax, (TANK ptr [ecx]).dir
    mov ecx, sinTBL[eax*4]
    imul ecx, spd
    mov edx, moveF
    imul ecx, edx
    sar ecx, 10
    add ny, ecx

    ; 硬边界保护：坦克整体必须在地图内。出界目标判为 solid=3
    ; （任何技能都不放行）——否则 ghost 在边界墙上被 clamp 恒判定命中，
    ; 会一直放行把坦克送出地图并永久卡死。
    mov eax, nx
    test eax, eax
    js MT_Out
    cmp eax, MAP_W - TANK_SIZE
    ja MT_Out
    mov eax, ny
    test eax, eax
    js MT_Out
    cmp eax, MAP_H - TANK_SIZE
    jbe MT_InMap
MT_Out:
    mov solid, 3                     ; 3=界外：不可放行
    jmp MT_AfterBlock
MT_InMap:
    ; 目标位置整体阻挡判定：
    ; 挡板墙 = 矩形级 AABB（与渲染一致）；水 = 覆盖格任一整格阻挡
    invoke TankBlocked, nx, ny
    mov solid, eax
MT_AfterBlock:
    ; 技能放行：驭水术穿过水(2)；穿墙术穿过墙(1)并计数
    mov ecx, ptank
    .if solid == 2
        mov eax, (TANK ptr [ecx]).effOn
        .if eax & EFF_WATER
            mov solid, 0
        .endif
    .elseif solid == 1
        mov eax, (TANK ptr [ecx]).effOn
        .if eax & EFF_GHOST
            mov eax, (TANK ptr [ecx]).wallPass
            .if eax > 0
                mov solid, 0
            .endif
        .endif
    .endif

    mov ecx, ptank
    .if solid == 0
        mov edx, nx
        mov (TANK ptr [ecx]).x, edx
        mov edx, ny
        mov (TANK ptr [ecx]).y, edx
        ; 穿墙计数：中心进入与上 tick 不同的墙格 -> 剩余次数-1
        mov eax, (TANK ptr [ecx]).x
        add eax, TANK_SIZE/2
        shr eax, 5
        mov edx, (TANK ptr [ecx]).y
        add edx, TANK_SIZE/2
        shr edx, 5
        imul edx, edx, COLS
        add eax, edx
        mov edx, (TANK ptr [ecx]).lastCell
        mov (TANK ptr [ecx]).lastCell, eax
        .if eax != edx
            mov ecx, eax
            movzx eax, mapData[ecx]
            .if eax == TILE_STEEL || eax == TILE_BRICK
                mov ecx, ptank
                mov eax, (TANK ptr [ecx]).wallPass
                .if eax > 0
                    dec (TANK ptr [ecx]).wallPass
                .endif
            .endif
        .endif
        mov ecx, ptank                 ; 恢复坦克指针（后续冰面判定依赖 ecx）
        ; 冰面判定：四角采样
        mov eax, ownerIdx
        invoke TankTerrain, eax
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
    inc gTick
    ; 比赛已结束：冻结（等待回菜单）
    mov eax, matchOver
    .if eax != 0
        jmp GU_Done
    .endif
    ; 震屏倒计时
    mov eax, shakeT
    .if eax > 0
        dec shakeT
    .endif

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

    ; ---- 技能拾取物：无拾取物时每 10s 计时生成 ----
    .if pickupType == 0
        mov eax, pickupTimer
        .if eax > 0
            dec pickupTimer
        .endif
        .if eax == 1
            invoke SpawnPickup
        .endif
    .endif
    ; ---- 激光显示倒计时 ----
    mov eax, laserT
    .if eax > 0
        dec laserT
        .if eax == 1
            mov laserN, 0
        .endif
    .endif

    ; ---- 各玩家槽位：移动 / 冰面滑行 / 开火 / 技能 ----
    mov fireHappened, 0
    xor ebx, ebx                       ; slot（跨 invoke 保持）
GU_Slot:
    .if ebx >= numPlayers
        jmp GU_SlotsDone
    .endif
    ; ---- 多命制：重生倒计时 / 重生保护递减 ----
    mov esi, ebx
    imul esi, esi, SIZEOF TANK
    add esi, offset tanks
    mov eax, (TANK ptr [esi]).protT
    .if eax > 0
        dec (TANK ptr [esi]).protT
    .endif
    mov eax, (TANK ptr [esi]).alive
    .if eax == 0
        mov eax, (TANK ptr [esi]).lives
        .if eax > 0
            dec (TANK ptr [esi]).respawnT
            mov eax, (TANK ptr [esi]).respawnT
            .if eax <= 0
                ; 重生：回出生点，满血+保护
                mov eax, (TANK ptr [esi]).spawnX
                mov (TANK ptr [esi]).x, eax
                mov eax, (TANK ptr [esi]).spawnY
                mov (TANK ptr [esi]).y, eax
                mov eax, (TANK ptr [esi]).spawnDir
                mov (TANK ptr [esi]).dir, eax
                mov eax, TANK_HP
                mov (TANK ptr [esi]).hp, eax
                mov (TANK ptr [esi]).alive, 1
                mov eax, SPAWN_PROT_TICKS
                mov (TANK ptr [esi]).protT, eax
                mov (TANK ptr [esi]).respawnT, 0
                mov (TANK ptr [esi]).fireCd, 0
                mov (TANK ptr [esi]).slide, 0
                ; 出生位嵌墙（本回合墙型变化）-> 就近迁移
                invoke TankBlocked, (TANK ptr [esi]).x, (TANK ptr [esi]).y
                .if eax != 0
                    invoke ShiftToOpen, ebx
                .endif
            .endif
        .endif
    .endif
    mov esi, ebx
    imul esi, esi, KEY_PER*4           ; esi = slot*KEY_PER*4（输入表字节偏移）
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
    ; ---- 技能：效果计时 / 拾取 / 使用键（边沿）/ 换位绑定检查 ----
    invoke EffTick, ebx
    ; 拾取：中心格 = 拾取物格 -> 覆盖持有（连续拾取覆盖前一个）
    ; 瞄准中 / 换位等待中不拾取（防止激光 + 新技能双技能并发）
    .if pickupType != 0
        mov eax, ebx
        imul eax, eax, SIZEOF TANK
        add eax, offset tanks
        mov edx, (TANK ptr [eax]).alive
        .if edx != 0
        mov edx, (TANK ptr [eax]).aimT
        .if edx == 0
        mov edx, (TANK ptr [eax]).swapBul
        .if edx == -1                ; 无换位绑定（勿写 < 0：无符号恒假）
        mov edx, (TANK ptr [eax]).effOn
        test edx, EFF_PHANTOM
        .if ZERO?                    ; 定格虚影中不拾取（防覆盖进行中的技能）
            mov edx, (TANK ptr [eax]).x
            add edx, TANK_SIZE/2
            shr edx, 5
            mov ecx, (TANK ptr [eax]).y
            add ecx, TANK_SIZE/2
            shr ecx, 5
            imul ecx, ecx, COLS
            add ecx, edx               ; ecx = 中心格
            mov edx, pickupX
            shr edx, 5
            mov eax, pickupY
            shr eax, 5
            imul eax, eax, COLS
            add eax, edx               ; eax = 拾取物格
            .if ecx == eax
                mov eax, ebx
                imul eax, eax, SIZEOF TANK
                add eax, offset tanks
                mov edx, pickupType
                mov (TANK ptr [eax]).skill, edx
                mov pickupType, 0
                mov eax, PICKUP_PERIOD
                mov pickupTimer, eax
                invoke SndPlay, 3    ; 拾取音
            .endif
        .endif
        .endif
        .endif
        .endif
    .endif
    ; 技能键边沿
    mov eax, inputTable[esi+20]
    mov ecx, prevUse[ebx*4]
    mov prevUse[ebx*4], eax
    .if eax != 0 && ecx == 0
        invoke TryUseSkill, ebx
    .endif
    ; 换位绑定子弹消失 -> 解除
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edx, (TANK ptr [eax]).swapBul
    .if edx != -1                    ; 有绑定（勿写 >= 0：无符号恒真）
        mov ecx, edx
        shl ecx, 5
        add ecx, offset bullets
        cmp (BULLET ptr [ecx]).active, 0
        jne GU_SwapOk
        mov (TANK ptr [eax]).swapBul, -1
GU_SwapOk:
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
                    ; vx 可为负：回退方向手写 test/js（.if > 0 无符号恒真）
                    mov eax, (BULLET ptr [edi]).vx
                    test eax, eax
                    js BT_XBackL
BT_XBackR:
                        dec (BULLET ptr [edi]).x
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).x
                            .if eax > 0
                                jmp BT_XBackR
                            .endif
                        .endif
                        jmp BT_XBackDone
BT_XBackL:
                        inc (BULLET ptr [edi]).x
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).x
                            .if eax < MAP_W - BULLET_SIZE_PX
                                jmp BT_XBackL
                            .endif
                        .endif
BT_XBackDone:
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
                    ; 命中：逐像素回退到出墙（同 X 轴；vy 可为负：test/js）
                    mov eax, (BULLET ptr [edi]).vy
                    test eax, eax
                    js BT_YBackU
BT_YBackD:
                        dec (BULLET ptr [edi]).y
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).y
                            .if eax > 0
                                jmp BT_YBackD
                            .endif
                        .endif
                        jmp BT_YBackDone
BT_YBackU:
                        inc (BULLET ptr [edi]).y
                        invoke BulletWallHit, edi
                        .if eax != 0
                            mov eax, (BULLET ptr [edi]).y
                            .if eax < MAP_H - BULLET_SIZE_PX
                                jmp BT_YBackU
                            .endif
                        .endif
BT_YBackDone:
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
        ; 定格虚影激活 -> 判定矩形 = 虚影位置（实像免伤，虚像可被打中）
        mov eax, (TANK ptr [edx]).effOn
        test eax, EFF_PHANTOM
        jz THR_B1
        mov eax, (TANK ptr [edx]).phantomX
        jmp THR_G1
THR_B1:
        mov eax, (TANK ptr [edx]).x
THR_G1:
        add eax, TANK_SIZE
        mov ecx, (BULLET ptr [edi]).x
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).effOn
        test eax, EFF_PHANTOM
        jz THR_B2
        mov eax, (TANK ptr [edx]).phantomX
        jmp THR_G2
THR_B2:
        mov eax, (TANK ptr [edx]).x
THR_G2:
        mov ecx, (BULLET ptr [edi]).x
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).effOn
        test eax, EFF_PHANTOM
        jz THR_B3
        mov eax, (TANK ptr [edx]).phantomY
        jmp THR_G3
THR_B3:
        mov eax, (TANK ptr [edx]).y
THR_G3:
        add eax, TANK_SIZE
        mov ecx, (BULLET ptr [edi]).y
        .if ecx >= eax
            jmp TankNext2
        .endif
        mov eax, (TANK ptr [edx]).effOn
        test eax, EFF_PHANTOM
        jz THR_B4
        mov eax, (TANK ptr [edx]).phantomY
        jmp THR_G4
THR_B4:
        mov eax, (TANK ptr [edx]).y
THR_G4:
        mov ecx, (BULLET ptr [edi]).y
        add ecx, BULLET_SIZE_PX
        .if ecx <= eax
            jmp TankNext2
        .endif
        ; 命中：虚影激活 -> 打中虚影（真实扣血 + 虚影消失）；
        ; 否则统一伤害入口（冰盾可抵挡一次）；销毁子弹
        push edi
        push esi
        mov eax, (TANK ptr [edx]).effOn
        test eax, EFF_PHANTOM
        jz THR_Normal
        invoke DamageTankRaw, esi
        invoke EndPhantom, esi
        jmp THR_HitDone
THR_Normal:
        invoke DamageTank, esi
THR_HitDone:
        pop esi
        pop edi
        mov (BULLET ptr [edi]).active, 0
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

    ; ---- 激光瞄准倒计时（到时发射）----
    xor ebx, ebx
GU_Aim:
    .if ebx >= numPlayers
        jmp GU_AimDone
    .endif
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).aimT
    .if ecx == 0
        jmp GU_ANext
    .endif
    ; 瞄准期间死亡：取消瞄准（死人不开炮）
    mov ecx, (TANK ptr [eax]).alive
    .if ecx == 0
        mov (TANK ptr [eax]).aimT, 0
        mov (TANK ptr [eax]).aimSkill, SKILL_NONE
        mov prevTank, -1
        mov prevN, 0
        jmp GU_ANext
    .endif
    dec (TANK ptr [eax]).aimT
    invoke RefreshLaserPreview, ebx   ; 预览随位置/朝向刷新
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ecx, (TANK ptr [eax]).aimT
    .if ecx == 0
        invoke FireAimedLaser, ebx
    .endif
GU_ANext:
    inc ebx
    jmp GU_Aim
GU_AimDone:

    ; ---- 地雷：生效倒计时 + 触发（含自己）----
    xor ebx, ebx
GU_Mine:
    .if ebx >= MAX_MINES
        jmp GU_MineDone
    .endif
    mov eax, mineCell[ebx*4]
    .if eax == -1                    ; 空槽（勿写 < 0：无符号恒假）
        jmp GU_MineNext
    .endif
    mov eax, mineArm[ebx*4]
    .if eax > 0
        dec mineArm[ebx*4]
        jmp GU_MineNext
    .endif
    ; 已生效：任一存活坦克中心格 == 雷格 -> 引爆
    xor esi, esi
GU_MTank:
    .if esi >= MAX_PLAYERS
        jmp GU_MineClear              ; 没踩到：地雷保留
    .endif
    mov eax, esi
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edx, (TANK ptr [eax]).alive
    .if edx == 0
        jmp GU_MTNext
    .endif
    mov edx, (TANK ptr [eax]).x
    add edx, TANK_SIZE/2
    shr edx, 5
    mov ecx, (TANK ptr [eax]).y
    add ecx, TANK_SIZE/2
    shr ecx, 5
    imul ecx, ecx, COLS
    add ecx, edx
    .if ecx == mineCell[ebx*4]
        push ebx
        invoke DamageTank, esi
        pop ebx
        jmp GU_MineClear              ; 引爆后消失
    .endif
GU_MTNext:
    inc esi
    jmp GU_MTank
GU_MineClear:
    mov mineCell[ebx*4], -1
GU_MineNext:
    inc ebx
    jmp GU_Mine
GU_MineDone:

    ; ---- 回合流程：剩 <=1 辆存活 -> 定格 5s（期间继续模拟：
    ;      幸存者可能被亡者弹/雷击杀成同归）-> 到时恰剩 1 辆才计一分；
    ;      打满局数 -> 比赛结束（等待回菜单）----
    .if roundOver != 0
        dec roundTimer
        .if roundTimer == 0
            ; 5s 到：重新统计存活并判分
            xor eax, eax
            xor esi, esi
            xor ebx, ebx
SCJ_Alive:
            .if ebx >= numPlayers          ; 只统计激活槽位（slot2/3 的 lives 不算在场）
                jmp SCJ_Done
            .endif
            mov edx, ebx
            imul edx, edx, SIZEOF TANK
            add edx, offset tanks
            mov ecx, (TANK ptr [edx]).alive
            .if ecx != 0
                inc eax
                mov esi, ebx
            .else
                mov ecx, (TANK ptr [edx]).lives
                .if ecx > 0
                    inc eax                 ; 待复活的坦克也算在场
                    mov esi, ebx
                .endif
            .endif
            inc ebx
            jmp SCJ_Alive
SCJ_Done:
            .if eax == 1
                mov edx, esi
                imul edx, edx, SIZEOF TANK
                add edx, offset tanks
                inc (TANK ptr [edx]).score   ; 最后存活的坦克才计一分
            .endif
            inc roundsPlayed
            mov eax, roundsPlayed
            .if eax >= maxRounds
                mov matchOver, 1             ; 打满局数：比赛结束
                jmp GU_Done
            .endif
            call ResetTanks                  ; 开新一轮（不清比分）
        .endif
        jmp GU_Done
    .endif
    ; 存活统计（slot 0..3 顺序固定）
    xor eax, eax                        ; eax = 存活数
    xor esi, esi                        ; esi = 幸存者槽位
    xor ebx, ebx
SC_Alive:
    .if ebx >= numPlayers                 ; 只统计激活槽位
        jmp SC_AliveDone
    .endif
    mov edx, ebx
    imul edx, edx, SIZEOF TANK
    add edx, offset tanks
    mov ecx, (TANK ptr [edx]).alive
    .if ecx != 0
        inc eax
        mov esi, ebx
    .else
        mov ecx, (TANK ptr [edx]).lives
        .if ecx > 0
            inc eax                     ; 待复活的坦克也算在场
            mov esi, ebx
        .endif
    .endif
    inc ebx
    jmp SC_Alive
SC_AliveDone:
    .if eax > 1
        jmp GU_Done                     ; 多车存活：不判分
    .endif
    ; 剩 0 或 1 辆：进入 5s 判分定格（期间模拟照常）
    mov roundScored, 0
    mov roundOver, 1
    mov roundTimer, ROUND_JUDGE_TICKS
GU_Done:
    ret
GameUpdate endp

end
