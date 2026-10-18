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
MuzzlePoint  PROTO :DWORD          ; 炮口分离偏移（eax=offx edx=offy）
SpawnBullet  PROTO :DWORD
DamageTank   PROTO :DWORD
SpawnIce2x2  PROTO :DWORD
SimReflectPath PROTO :DWORD,:DWORD,:DWORD,:DWORD

; ---- 输入快照（本模块定义，input.asm / ui.asm 写入）----
public keyTable
public inputTable
public inputRestart
extern numPlayers :dword               ; ui.asm（当前玩家数 2..4）

; ---- 游戏状态（本模块定义，gfx.asm / net.asm 读取）----
public tanks
public bullets
public cosTBL                      ; gfx.asm 旋转渲染读取（会话 19 整车旋转）
public sinTBL
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
    include trig.inc               ; 360 度整度三角表 x1024（tools/gen_trig.py 生成）
    tanks       TANK MAX_PLAYERS dup (<>)
    bullets     BULLET MAX_BULLETS dup (<>)
    mapData     db COLS*ROWS dup(TILE_EMPTY)
    spawnX      dd 4 dup (0)         ; 出生点像素坐标（字符画 'S'）
    spawnY      dd 4 dup (0)
    spawnCount  dd 0
    mapIndex    dd 0                 ; 当前 ARENA 编号
    keyTable    dd MAX_PLAYERS*KEY_PER dup (0)   ; [slot*KEY_PER+动作] VK 码: 0前进1后退2左转3右转4开火5技能
    inputTable  dd MAX_PLAYERS*KEY_PER dup (0)   ; [slot*KEY_PER+动作] 每 tick 快照 0/1
    prevUse     dd MAX_PLAYERS dup (0)  ; 技能键上帧状态（边沿检测）
    gTick       dd 0                 ; 全局 tick 计数（坦克 3/4 交替速度用）
    shakeT      dd 0                 ; 坦克爆炸震屏剩余 tick
    testLives   dd LIVES_INIT        ; 自测时置 1（击杀即淘汰，保持旧断言）
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
    stFailN     dd 0
    stHomeX     dd 0
    stHomeY     dd 0
    stBulIdx    dd 0
    stBulX0     dd 0
    stBulY0     dd 0
    stVx0       dd 0
    stVy0       dd 0

    nbRow       dd ?
    nbCol       dd ?
    nbIdx       dd ?
    nbDir       dd ?
    ; ---- 会话 19 自测字符串：长度用 ($ - 标签) 自动计算，无需手工数字节 ----
    stT1    db "T1_FWD_DIR0_X(expect172)="
    stT1L   equ ($ - stT1)
    stT2    db "T2_ACTIVE_AFTER_FIRE(expect1)="
    stT2L   equ ($ - stT2)
    stT3    db "T3_ACTIVE_AFTER_620TICKS(expect0)="
    stT3L   equ ($ - stT3)
    stT4    db "T4_MAP_UNCHANGED(expect1)="
    stT4L   equ ($ - stT4)
    stT5    db "T5_NOT_ON_WATER(expect1)="
    stT5L   equ ($ - stT5)
    stT6    db "T6_SLIDE_6_15(expect1)="
    stT6L   equ ($ - stT6)
    stT7    db "T7_P2_WALKSTOP_X20(expect1)="
    stT7L   equ ($ - stT7)
    stT8    db "T8_15FIRE_QUOTA(expect10)="
    stT8L   equ ($ - stT8)
    stT9a   db "T9_KILLED_LT300(expect1)="
    stT9aL  equ ($ - stT9a)
    stT9b   db "T9_P2_ALIVE(expect0)="
    stT9bL  equ ($ - stT9b)
    stT9c   db "T9_P2_HP(expect0)="
    stT9cL  equ ($ - stT9c)
    stT10   db "T10_P1_SCORE(expect1)="
    stT10L  equ ($ - stT10)
    stT11   db "T11_DIRT_2T_DISP(expect2)="
    stT11L  equ ($ - stT11)
    stT12a  db "T12_SELFKILL_HP(expect0)="
    stT12aL equ ($ - stT12a)
    stT12b  db "T12_SELFKILL_DEAD(expect0)="
    stT12bL equ ($ - stT12b)
    stT13a  db "T13_SPAWN_1_8(expect1)="
    stT13aL equ ($ - stT13a)
    stT13b  db "T13_PICKUP_SKILL(expect3)="
    stT13bL equ ($ - stT13b)
    stT13c  db "T13_SHIELD_ON(expect1)="
    stT13cL equ ($ - stT13c)
    stT14a  db "T14_SHIELD_BLOCK(expect1)="
    stT14aL equ ($ - stT14a)
    stT14b  db "T14_2ND_LETHAL(expect0)="
    stT14bL equ ($ - stT14b)
    stT14c  db "T14_ICE_CELLS(expect2)="
    stT14cL equ ($ - stT14c)
    stT15a  db "T15_LASER_KILL(expect0)="
    stT15aL equ ($ - stT15a)
    stT15b  db "T15_LASER_PTS(expect2)="
    stT15bL equ ($ - stT15b)
    stT15c  db "T15_SHOOTER_ALIVE(expect1)="
    stT15cL equ ($ - stT15c)
    stT16a  db "T16_REFL_KILL(expect0)="
    stT16aL equ ($ - stT16a)
    stT16b  db "T16_REFL_PTS(expect9)="
    stT16bL equ ($ - stT16b)
    stT16c  db "T16_CASTER_SUICIDE(expect0)="
    stT16cL equ ($ - stT16c)
    stT17a  db "T17_STEEL_BLOCK(expect1)="
    stT17aL equ ($ - stT17a)
    stT17b  db "T17_GHOST_PASSED(expect1)="
    stT17bL equ ($ - stT17b)
    stT17c  db "T17_USES_LEFT(expect2)="
    stT17cL equ ($ - stT17c)
    stT18a  db "T18_PREARM_HP(expect1)="
    stT18aL equ ($ - stT18a)
    stT18b  db "T18_BOOM_DEAD(expect0)="
    stT18bL equ ($ - stT18b)
    stT18c  db "T18_MINE_GONE(expect1)="
    stT18cL equ ($ - stT18c)
    stT19a  db "T19_NORM_DX(expect4or5)="
    stT19aL equ ($ - stT19a)
    stT19b  db "T19_BOOST_DX(expect+2)="
    stT19bL equ ($ - stT19b)
    stT19c  db "T19_MUD_BOOST(expect3)="
    stT19cL equ ($ - stT19c)
    stT20a  db "T20_SWAPPED(expect1)="
    stT20aL equ ($ - stT20a)
    stT20b  db "T20_BUL_BACK(expect1)="
    stT20bL equ ($ - stT20b)
    stT20c  db "T20_DIR_INHERIT(expect1)="
    stT20cL equ ($ - stT20c)
    stT20d  db "T20_UNBOUND(expect1)="
    stT20dL equ ($ - stT20d)
    stT21a  db "T21_WATER_BLOCK(expect1)="
    stT21aL equ ($ - stT21a)
    stT21b  db "T21_IN_WATER(expect1)="
    stT21bL equ ($ - stT21b)
    stT21c  db "T21_WATER_HOLD(expect1)="
    stT21cL equ ($ - stT21c)
    stT21d  db "T21_WATER_OFF(expect0)="
    stT21dL equ ($ - stT21d)
    stT22a  db "T22_PHANTOM_SET(expect1)="
    stT22aL equ ($ - stT22a)
    stT22b  db "T22_SPLIT(expect1)="
    stT22bL equ ($ - stT22b)
    stT22c  db "T22_REAL_IMMUNE(expect1)="
    stT22cL equ ($ - stT22c)
    stT22d  db "T22_PH_HIT_LETHAL(expect1)="
    stT22dL equ ($ - stT22d)
    stT22e  db "T22_REINIT_2T1USE(expect1)="
    stT22eL equ ($ - stT22e)
    stT22f  db "T22_RECALL_CLEAR(expect1)="
    stT22fL equ ($ - stT22f)
    stT23a  db "T23_LIVES_AFTER(expect2)="
    stT23aL equ ($ - stT23a)
    stT23b  db "T23_RESPAWN_ALIVE(expect1)="
    stT23bL equ ($ - stT23b)
    stT23c  db "T23_RESPAWN_HP(expect1)="
    stT23cL equ ($ - stT23c)
    stT23d  db "T23_PROT_LEFT(expect120)="
    stT23dL equ ($ - stT23d)
    stT24   db "T24_ANGLE_WRAP(expect1)="
    stT24L  equ ($ - stT24)
    stT25   db "T25_DIR_PURE45(expect1)="
    stT25L  equ ($ - stT25)
    stT26   db "T26_MUZZLE_GEOM(expect5)="
    stT26L  equ ($ - stT26)
    stT27   db "T27_45DEG_BALLISTIC(expect1)="
    stT27L  equ ($ - stT27)
    stT28   db "T28_TDIR_QUANT(expect13)="
    stT28L  equ ($ - stT28)
    stT29   db "T29_45DEG_BOUNCE(expect1)="
    stT29L  equ ($ - stT29)
    stT30   db "T30_SLIDE_TURN(expect1)="
    stT30L  equ ($ - stT30)
    stT31   db "T31_TRIG_TABLE(expect4)="
    stT31L  equ ($ - stT31)
    stT32   db "T32_TURN_DRIVE(expect3)="
    stT32L  equ ($ - stT32)
    stT33   db "T33_TERR_EDGE(expect2)="
    stT33L  equ ($ - stT33)
    stT34   db "T34_SHIELD_EXPIRE(expect2)="
    stT34L  equ ($ - stT34)
    stT35   db "T35_PROT_NOBURN(expect2)="
    stT35L  equ ($ - stT35)
    stT36   db "T36_GHOST_ESCAPE(expect1)="
    stT36L  equ ($ - stT36)
    stWntS  db " want "
    stWntSL equ ($ - stWntS)
    stOKS   db " OK", 13, 10
    stOKSL  equ ($ - stOKS)
    stBadS  db " ***FAIL***", 13, 10
    stBadSL equ ($ - stBadS)
    stMarkS db "MARK="
    stMarkSL equ ($ - stMarkS)
    stFails db "ST_FAILS="
    stFailsL equ ($ - stFails)
    stDone  db 13, 10, "SELFTEST_DONE", 13, 10
    stDoneL equ ($ - stDone)
    ; T28 量化采样角（含临界 0/1/355/359 与四轴/45 度系）
    stAngTbl dd 0,1,44,45,89,90,135,180,225,270,313,355,359

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
    mov (TANK ptr [esi]).subpxX, 0      ; 会话 19：定点余量必须清零
    mov (TANK ptr [esi]).subpxY, 0      ; （否则换局/自测传送后首步被旧余量偏置）
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
; SetDirInput -- 按动作码设置 P1 输入（99 = 全部清零）
; 会话 19 语义：0=前进(槽0) 1=右转(槽3) 2=后退(槽1) 3=左转(槽2)
; （码值沿用旧方向码顺序，测试代码只改语义不改调用位）
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
; 动作顺序（会话 19）：0前进 1后退 2左转 3右转 4开火 5技能
; 物理键位不变：W/S=前进/后退，A/D=逆时针/顺时针旋转
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
; Chk -- 自测断言输出：NAME=got want X OK/FAIL；FAIL 计数 stFailN++
;   必须保持 ebx/esi/edi（LogNum 会踩 edi）
; ------------------------------------------------------------
Chk proc uses esi edi pName: dword, pLen: dword, got: dword, want: dword
    invoke LogStr, pName, pLen
    mov eax, got
    invoke LogNum, eax
    invoke LogStr, offset stWntS, stWntSL
    mov eax, want
    invoke LogNum, eax
    mov eax, got
    cmp eax, want
    je ChkOK
    inc stFailN
    invoke LogStr, offset stBadS, stBadSL
    ret
ChkOK:
    invoke LogStr, offset stOKS, stOKSL
    ret
Chk endp

; ------------------------------------------------------------
; Mark -- 自测阶段标记 "MARK=n"：崩溃时 log 末行即最后到达阶段
; ------------------------------------------------------------
Mark proc uses edi n: dword
    invoke LogStr, offset stMarkS, stMarkSL
    invoke LogNum, n
    invoke LogStr, offset nlStr, 2
    ret
Mark endp

; ------------------------------------------------------------
; ToAngle -- FindOpenNeighbor 方向码(0上/1右/2下/3左) -> 角度(度)
; ------------------------------------------------------------
ToAngle proc dc: dword
    mov eax, dc
    .if eax == 0
        mov eax, DIR_UP
    .elseif eax == 1
        mov eax, DIR_RIGHT
    .elseif eax == 2
        mov eax, DIR_DOWN
    .else
        mov eax, DIR_LEFT
    .endif
    ret
ToAngle endp


; ------------------------------------------------------------
; SelfTestRun -- 会话19 新语义自测：31 组方泑论断言（含 4 个回滚故障回归锁 + 6 项 360° 新增）
; Deterministic: fixed ARENA1, simulated inputs, results -> selftest.log
; ------------------------------------------------------------
SelfTestRun proc uses ebx esi edi
    local lX0:dword, lY0:dword, lGot:dword, lWant:dword, lIdx:dword
    local lPass:dword, lTmp:dword
    call InitKeyDefaults             ; 无头路径不经过 UiInit，补默认键位
    mov testLives, 1                 ; 自测固定单命：击杀即淘汰（确定性）
    mov testNoShuffle, 1             ; 固定 ARENA1 + 原出生点
    mov rngState, 1
    mov spawnCount, 0
    mov stFailN, 0
    mov numPlayers, 2                ; 双人激活（槽循环/ResetTanks 依赖）
    invoke ParseArena, offset ARENA1
    ; 自测专用：清空第 13 行做水平测试走廊
    mov ecx, 13*COLS+1
STClear13:
    mov mapData[ecx], TILE_EMPTY
    inc ecx
    .if ecx < 13*COLS+COLS-1
        jmp STClear13
    .endif
    call ResetTanks
    ; 记录 P1 出生位：T2~T4 期间把 P1 停回出生位。1HP 规则下走廊
    ; 乒乓弹若打到停靠坦克会提前死亡并污染后续滑行/水域测试
    mov eax, tanks[0*SIZEOF TANK].x
    mov stHomeX, eax
    mov eax, tanks[0*SIZEOF TANK].y
    mov stHomeY, eax
    ; 地图快照（验证墙体不可摧毁）
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    rep movsb
    call OpenLog

    ; ==== T1 dir=0 前进 40 tick：32+140=172（会话 21 降速：3/4 交替 40 tick 恰 140px） ====
    invoke Mark, 10
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    invoke SetDirInput, 0
    invoke AdvanceTicks, 40
    invoke SetDirInput, 99
    invoke Chk, offset stT1, stT1L, tanks[0*SIZEOF TANK].x, 172

    ; ==== T2 开火 -> 一颗弹在飞 ====
    invoke Mark, 20
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputTable[16], 1
    invoke GameUpdate
    mov inputTable[16], 0
    invoke CountOwnBullets, 0
    mov lGot, eax
    invoke Chk, offset stT2, stT2L, lGot, 1
    ; P1 停回出生位（乒乓弹带 y=424 触不到上下半场出生点）
    mov eax, stHomeX
    mov tanks[0*SIZEOF TANK].x, eax
    mov eax, stHomeY
    mov tanks[0*SIZEOF TANK].y, eax

    ; ==== T3 620 tick 后弹全部消亡（BULLET_LIFE=600 先到） ====
    invoke Mark, 30
    invoke AdvanceTicks, 620
    invoke CountOwnBullets, 0
    mov lGot, eax
    invoke Chk, offset stT3, stT3L, lGot, 0

    ; ==== T4 注入乒乓弹轰 900 tick：地图逐字节不变（墙体不可摧毁） ====
    ; 注入 owner=2（非在场玩家）：1HP 下不殃及停放坦克，纯轰墙
    invoke Mark, 40
    lea edi, bullets
    add edi, SIZEOF BULLET
    mov (BULLET ptr [edi]).x, 500
    mov (BULLET ptr [edi]).y, 424
    mov (BULLET ptr [edi]).vx, BULLET_SPEED*FIX_ONE
    mov (BULLET ptr [edi]).vy, 0
    mov (BULLET ptr [edi]).owner, 2
    mov (BULLET ptr [edi]).active, 1
    mov (BULLET ptr [edi]).bounces, 0
    mov (BULLET ptr [edi]).age, 0
    mov (BULLET ptr [edi]).subpxX, 0
    mov (BULLET ptr [edi]).subpxY, 0
    mov (BULLET ptr [edi]).fireAng, 0
    invoke AdvanceTicks, 900
    cld
    mov esi, offset mapData
    mov edi, offset saveMap
    mov ecx, COLS*ROWS
    repe cmpsb
    mov lGot, 0
    .if ZERO?
        mov lGot, 1
    .endif
    invoke Chk, offset stT4, stT4L, lGot, 1

    ; ==== T5 水域挡坦克：从开放邻居朝水推进 30 tick，中心格必须非水 ====
    invoke Mark, 50
    xor esi, esi
T5Find:
    cmp mapData[esi], TILE_WATER
    je T5Found
    inc esi
    .if esi < COLS*ROWS
        jmp T5Find
    .endif
    mov lGot, 1                      ; 无水格：视为通过（真实地图必不会出现）
    jmp T5Log
T5Found:
    invoke FindOpenNeighbor, esi
    .if eax == 99
        mov lGot, 1
        jmp T5Log
    .endif
    add eax, 2                       ; 邻居方向取反 = 从邻居格瞄准水格
    cmp eax, 4
    jb T5Opp
    sub eax, 4
T5Opp:
    invoke ToAngle, eax
    mov tanks[0*SIZEOF TANK].dir, eax
    mov eax, nbIdx
    xor edx, edx
    mov ecx, COLS
    div ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    imul edx, edx, CELL
    mov tanks[0*SIZEOF TANK].x, edx
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    invoke SetDirInput, 0
    invoke AdvanceTicks, 30
    invoke SetDirInput, 99
    mov eax, tanks[0*SIZEOF TANK].x
    add eax, TANK_SIZE/2
    mov ecx, tanks[0*SIZEOF TANK].y
    add ecx, TANK_SIZE/2
    invoke TileAtPx, eax, ecx
    mov lGot, 1
    .if eax == TILE_WATER
        mov lGot, 0                  ; 中心入水 = 挡水失效
    .endif
T5Log:
    invoke Chk, offset stT5, stT5L, lGot, 1

    ; ==== T6 冰面滑行：站上冰格向开放邻居驱动 1 tick，slide 应落在 6..15 ====
    invoke Mark, 60
    xor esi, esi
T6Find:
    cmp mapData[esi], TILE_ICE
    je T6Found
    inc esi
    .if esi < COLS*ROWS
        jmp T6Find
    .endif
    mov lGot, 0
    jmp T6Log
T6Found:
    invoke FindOpenNeighbor, esi
    .if eax == 99
        mov lGot, 0
        jmp T6Log
    .endif
    invoke ToAngle, eax              ; 冰格 -> 开放邻居方向
    mov tanks[0*SIZEOF TANK].dir, eax
    mov eax, esi
    xor edx, edx
    mov ecx, COLS
    div ecx
    imul eax, eax, CELL
    mov tanks[0*SIZEOF TANK].y, eax
    imul edx, edx, CELL
    mov tanks[0*SIZEOF TANK].x, edx
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    invoke SetDirInput, 0
    invoke GameUpdate
    invoke SetDirInput, 99
    mov eax, tanks[0*SIZEOF TANK].slide
    mov lGot, 0
    cmp eax, 6
    jb T6Bad
    cmp eax, 15
    ja T6Bad
    mov lGot, 1
T6Bad:
T6Log:
    invoke Chk, offset stT6, stT6L, lGot, 1

    ; ==== T7 P2 驾驶：dir=180 + 前进键（槽24），40 tick 后停于细边界墙 x=20 ====
    invoke Mark, 70
    call ResetTanks
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].dir, 180
    mov tanks[1*SIZEOF TANK].subpxX, 0
    mov tanks[1*SIZEOF TANK].subpxY, 0
    mov inputTable[24], 1
    invoke AdvanceTicks, 40
    mov inputTable[24], 0
    mov eax, tanks[1*SIZEOF TANK].x
    mov lGot, 0
    ; 会话 18 全部细墙后：左边界钢条几何 x∈[12,20)，车头恰停在 x=20
    cmp eax, 20
    jne T7Bad
    mov lGot, 1
T7Bad:
    invoke Chk, offset stT7, stT7L, lGot, 1

    ; ==== T8 同屏配额：连开 15 枪 -> 恰好 10 颗（MAX_PER_TANK） ====
    invoke Mark, 80
    call ResetTanks
    mov tanks[0*SIZEOF TANK].dir, 0
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
    mov lGot, eax
    invoke Chk, offset stT8, stT8L, lGot, 10

    ; ==== T9/T10 走廊射杀：1HP 下 P2 中弹即淘汰，P1 记 1 分 ====
    invoke Mark, 90
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
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
    mov lGot, 0
    .if esi < 300
        mov lGot, 1
    .endif
    invoke Chk, offset stT9a, stT9aL, lGot, 1
    invoke Chk, offset stT9b, stT9bL, tanks[1*SIZEOF TANK].alive, 0
    invoke Chk, offset stT9c, stT9cL, tanks[1*SIZEOF TANK].hp, 0
    ; 清空弹池：残余弹会在走廊乒乓，350 tick 判定期内可能流弹击毙 P1
    mov edi, offset bullets
    xor ecx, ecx
T9ClrB:
    mov (BULLET ptr [edi]).active, 0
    add edi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp T9ClrB
    .endif
    invoke AdvanceTicks, 350         ; 判分定格（ROUND_JUDGE_TICKS=300）
    invoke Chk, offset stT10, stT10L, tanks[0*SIZEOF TANK].score, 1

    ; ==== T11 泥土减速：泥格向开放邻居推 2 tick，位移 |dx|+|dy|=2（会话 21：泥速 1）====
    invoke Mark, 110
    xor esi, esi
T11Find:
    cmp mapData[esi], TILE_DIRT
    je T11Found
    inc esi
    .if esi < COLS*ROWS
        jmp T11Find
    .endif
    mov lGot, 2                      ; 无泥格：跳过（视为通过）
    jmp T11Log
T11Found:
    invoke FindOpenNeighbor, esi
    .if eax == 99
        mov lGot, 2
        jmp T11Log
    .endif
    invoke ToAngle, eax
    mov tanks[0*SIZEOF TANK].dir, eax
    mov eax, esi
    xor edx, edx
    mov ecx, COLS
    div ecx
    imul eax, eax, CELL
    mov t11y0, eax
    mov tanks[0*SIZEOF TANK].y, eax
    imul edx, edx, CELL
    mov t11x0, edx
    mov tanks[0*SIZEOF TANK].x, edx
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    invoke SetDirInput, 0
    invoke AdvanceTicks, 2
    invoke SetDirInput, 99
    ; 位移 = |dx|+|dy|（手写取绝对值，规避 .if 符号语义）
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
    mov lGot, eax
T11Log:
    invoke Chk, offset stT11, stT11L, lGot, 2

    ; ==== T12 反弹自伤：贴右钢界朝右出炮，出膛即撞墙反弹自击。
    ;      会话 19 修正语义：1HP 下自伤 = 直接淘汰（旧标签 expect2 作废） ====
    invoke Mark, 120
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 947
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputTable[16], 1
    invoke GameUpdate                ; 发射
    mov inputTable[16], 0
    invoke AdvanceTicks, 30          ; 出膛->撞墙->回退出墙->反弹->自中
    invoke Chk, offset stT12a, stT12aL, tanks[0*SIZEOF TANK].hp, 0
    invoke Chk, offset stT12b, stT12bL, tanks[0*SIZEOF TANK].alive, 0

    ; ==== T13 技能框架：补给生成 / 中心格拾取 / 使用键边沿发动 ====
    invoke Mark, 130
    call ResetTanks
    mov pickupType, 0
    mov pickupTimer, 2
    invoke AdvanceTicks, 3
    mov eax, pickupType
    mov lGot, 0
    cmp eax, 1
    jb T13Bad
    cmp eax, 8
    ja T13Bad
    mov lGot, 1
T13Bad:
    invoke Chk, offset stT13a, stT13aL, lGot, 1
    ; b) 拾取：补给移到 P1 中心格 -> 1 tick 覆盖持有
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov pickupX, 32+(CELL-PICKUP_SIZE)/2
    mov pickupY, 416+(CELL-PICKUP_SIZE)/2
    mov pickupType, 3                ; 反射激光
    invoke AdvanceTicks, 1
    invoke Chk, offset stT13b, stT13bL, tanks[0*SIZEOF TANK].skill, 3
    ; c) 使用键边沿 0->1：冰盾发动（EFF_SHIELD=1）
    mov prevUse[0], 0
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    invoke GameUpdate
    invoke Chk, offset stT13c, stT13cL, tanks[0*SIZEOF TANK].effOn, 1

    ; ==== T14 冰盾：挡一次伤害 + 周围 2x2 冰面；会话 19 修正：盾碎后
    ;      第二发即致命（1HP），正好锁死"盾只挡一次"语义 ====
    invoke Mark, 140
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                ; 发动冰盾（同 tick 生成 2x2 冰）
    mov inputTable[20], 0
    ; 首发压在 P1 身上（owner=P2，vx=vy=0）-> 应被盾挡
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
    mov bullets[0].subpxX, 0
    mov bullets[0].subpxY, 0
    invoke GameUpdate
    invoke Chk, offset stT14a, stT14aL, tanks[0*SIZEOF TANK].alive, 1
    ; 盾已碎：同位再压一发 -> 直接击杀
    mov bullets[0].active, 1
    mov eax, tanks[0*SIZEOF TANK].x
    mov bullets[0].x, eax
    mov eax, tanks[0*SIZEOF TANK].y
    mov bullets[0].y, eax
    invoke GameUpdate
    invoke Chk, offset stT14b, stT14bL, tanks[0*SIZEOF TANK].alive, 0
    ; 冰面：走廊行 (13,1)(13,2) 空地应已变冰
    xor eax, eax
    .if mapData[13*COLS+1] == TILE_ICE
        inc eax
    .endif
    .if mapData[13*COLS+2] == TILE_ICE
        inc eax
    .endif
    mov lGot, eax
    invoke Chk, offset stT14c, stT14cL, lGot, 2

    ; ==== T15 激光炮：任意角射线穿墙直线伤害（会话 19 修正：1HP 即杀） ====
    invoke Mark, 151
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov mapData[13*COLS+10], TILE_STEEL   ; 墙后目标：col10 钢墙，P2 在 x=400
    mov tanks[1*SIZEOF TANK].x, 400
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_LASER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                ; 进入瞄准（aimT=42，本 tick 已减到 41）
    mov inputTable[20], 0
    invoke Mark, 152
    invoke AdvanceTicks, 41          ; 41 后 aimT=0 -> 发射
    invoke Mark, 153
    invoke Chk, offset stT15a, stT15aL, tanks[1*SIZEOF TANK].hp, 0
    invoke Chk, offset stT15b, stT15bL, laserN, 2
    invoke Chk, offset stT15c, stT15cL, tanks[0*SIZEOF TANK].alive, 1
    mov mapData[13*COLS+10], TILE_EMPTY  ; 还原走廊

    ; ==== T16 反射激光：预览/实弹同构的 16.16 进位反射路径（7 次反弹=9 点） ====
    invoke Mark, 161
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].x, 200
    mov tanks[1*SIZEOF TANK].y, 416
    mov tanks[1*SIZEOF TANK].alive, 1
    mov tanks[1*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_REFLASER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                ; 进入瞄准：本 tick 起每 tick 跑 SimReflectPath
    mov inputTable[20], 0
    invoke Mark, 162
    invoke AdvanceTicks, 41          ; 到时发射
    invoke Mark, 163
    invoke Chk, offset stT16a, stT16aL, tanks[1*SIZEOF TANK].hp, 0
    invoke Chk, offset stT16b, stT16bL, laserN, 9
    invoke Chk, offset stT16c, stT16cL, tanks[0*SIZEOF TANK].alive, 0
    invoke Mark, 164

    ; ==== T17 穿墙术：无技能被钢墙挡死；发动后穿墙并计数 3->2 ====
    invoke Mark, 171
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov mapData[13*COLS+6], TILE_STEEL     ; col6 挡路（x192..223）
    ; a) 无技能：前进被挡（应停在 167 附近：191-24）
    mov inputTable[0], 1
    invoke AdvanceTicks, 40
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov lGot, 0
    cmp eax, 96
    jbe T17BadA
    cmp eax, 180
    ja T17BadA
    mov lGot, 1
T17BadA:
    invoke Chk, offset stT17a, stT17aL, lGot, 1
    ; b) 穿墙术发动后 30 tick：穿过钢墙
    mov tanks[0*SIZEOF TANK].skill, SK_GHOST
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov inputTable[0], 1
    invoke AdvanceTicks, 30
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov lGot, 0
    cmp eax, 200
    jbe T17BadB
    mov lGot, 1
T17BadB:
    invoke Chk, offset stT17b, stT17bL, lGot, 1
    ; c) 穿墙计数：中心进入墙格一次 -> 3-1=2
    invoke Chk, offset stT17c, stT17cL, tanks[0*SIZEOF TANK].wallPass, 2
    mov mapData[13*COLS+6], TILE_EMPTY     ; 还原走廊

    ; ==== T18 地雷：120 tick 生效；生效时踩雷者（含布雷人自己）爆炸阵亡 ====
    invoke Mark, 181
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_MINE
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 布雷（埋在自己脚下 (13,1)）
    mov inputTable[20], 0
    invoke AdvanceTicks, 60                ; 未到 2s
    invoke Chk, offset stT18a, stT18aL, tanks[0*SIZEOF TANK].hp, 1
    invoke AdvanceTicks, 61                ; 到时 -> 仍踩雷上 -> 自爆（1HP 即死）
    invoke Chk, offset stT18b, stT18bL, tanks[0*SIZEOF TANK].alive, 0
    mov eax, mineCell[0]
    mov lGot, 0
    cmp eax, -1
    jne T18Bad
    mov lGot, 1
T18Bad:
    invoke Chk, offset stT18c, stT18cL, lGot, 1

    ; ==== T19 燃油加速 + 奇偶步长：常速 3/4 交替；加速 +2；泥地叠加=3 ====
    invoke Mark, 191
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    ; a) 常速一步 = TANK_SPEED + (gTick&1)（GameUpdate 先 inc 后移动，同值）
    mov inputTable[0], 1
    invoke GameUpdate
    mov inputTable[0], 0
    mov eax, TANK_SPEED
    mov ecx, gTick
    and ecx, 1
    add eax, ecx
    mov lWant, eax
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 96
    mov lGot, eax
    invoke Chk, offset stT19a, stT19aL, lGot, lWant
    ; b) 加速一步 = 常速 + 2
    mov tanks[0*SIZEOF TANK].skill, SK_NITRO
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 发动加速（此 tick 无驾驶输入，不动）
    mov inputTable[20], 0
    mov ebx, tanks[0*SIZEOF TANK].x        ; 步前位置（ebx 跨 invoke 保存）
    mov inputTable[0], 1
    invoke GameUpdate
    mov inputTable[0], 0
    mov eax, TANK_SPEED
    mov ecx, gTick
    and ecx, 1
    add eax, ecx
    add eax, 2
    mov lWant, eax
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, ebx
    mov lGot, eax
    invoke Chk, offset stT19b, stT19bL, lGot, lWant
    ; c) 泥地叠加：DIRT_SPEED(1) + 加速(2) = 3 恒定（与奇偶无关）
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov mapData[13*COLS+3], TILE_DIRT
    mov inputTable[0], 1
    invoke GameUpdate
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 96
    mov lGot, eax
    invoke Chk, offset stT19c, stT19cL, lGot, 3
    mov mapData[13*COLS+3], TILE_EMPTY

    ; ==== T20 换位术：UP 发射换位弹 -> 再按与弹互换；朝向继承 fireAng ====
    invoke Mark, 201
    call ResetTanks
    mov ebx, 2                             ; 清 col3 rows 2..16 做向上弹道
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
    mov tanks[0*SIZEOF TANK].dir, DIR_UP   ; 270：off=(0,-18)，弹 x 恒 104
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov tanks[0*SIZEOF TANK].skill, SK_SWAP
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 发射换位弹（绑定 swapBul）
    mov inputTable[20], 0
    invoke AdvanceTicks, 20                ; 弹上飞约 120px
    mov inputTable[20], 1
    invoke GameUpdate                      ; 再按 -> DoSwap
    mov inputTable[20], 0
    ; a) 坦克已瞬移到子弹处（子弹中心对齐：x=104-8=96）
    mov eax, tanks[0*SIZEOF TANK].y
    mov lGot, 0
    cmp eax, 350
    jae T20BadA
    mov eax, tanks[0*SIZEOF TANK].x
    cmp eax, 96
    jne T20BadA
    mov lGot, 1
T20BadA:
    invoke Chk, offset stT20a, stT20aL, lGot, 1
    ; b) 子弹回到坦克原位（96+8=104；旧网格语义 expect 不变）
    mov eax, bullets[0].x
    mov lGot, 0
    cmp eax, 100
    jb T20BadB
    cmp eax, 140
    ja T20BadB
    mov lGot, 1
T20BadB:
    invoke Chk, offset stT20b, stT20bL, lGot, 1
    ; c) 坦克朝向 = 子弹发射角（270，会话 19：fireAng 直接继承）
    mov eax, tanks[0*SIZEOF TANK].dir
    mov lGot, 0
    cmp eax, DIR_UP
    jne T20BadC
    mov lGot, 1
T20BadC:
    invoke Chk, offset stT20c, stT20cL, lGot, 1
    ; d) 换位后绑定解除（swapBul=-1）
    mov eax, tanks[0*SIZEOF TANK].swapBul
    mov lGot, 0
    cmp eax, -1
    jne T20BadD
    mov lGot, 1
T20BadD:
    invoke Chk, offset stT20d, stT20dL, lGot, 1

    ; ==== T21 驭水术：无技能被水挡；发动后可水上行走；到期保护；离水失效 ====
    invoke Mark, 211
    call ResetTanks
    mov mapData[13*COLS+5], TILE_WATER     ; row13 走廊 col5/col6 设水
    mov mapData[13*COLS+6], TILE_WATER
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    ; a) 无技能：前进被水挡（col5 起水 160..191，25px 车身最深 x=135）
    mov inputTable[0], 1
    invoke AdvanceTicks, 25
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov lGot, 0
    cmp eax, 120
    jb T21BadA
    cmp eax, 140
    ja T21BadA
    mov ecx, eax
    add ecx, TANK_SIZE/2
    mov eax, tanks[0*SIZEOF TANK].y
    add eax, TANK_SIZE/2
    invoke TileAtPx, ecx, eax
    cmp eax, TILE_WATER
    je T21BadA                             ; 中心在水里 = 没挡住
    mov lGot, 1
T21BadA:
    invoke Chk, offset stT21a, stT21aL, lGot, 1
    ; b) 发动驭水 -> 穿进水域（8 tick 约 36px，中心必须落在水格上）
    mov tanks[0*SIZEOF TANK].skill, SK_WATER
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov inputTable[0], 1
    invoke AdvanceTicks, 8
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    add eax, TANK_SIZE/2
    mov ecx, tanks[0*SIZEOF TANK].y
    add ecx, TANK_SIZE/2
    invoke TileAtPx, eax, ecx
    mov lGot, 0
    cmp eax, TILE_WATER
    jne T21BadB
    mov lGot, 1
T21BadB:
    invoke Chk, offset stT21b, stT21bL, lGot, 1
    ; c) 到期保护：中心仍在水上 -> effT 归零时延寿 1 tick，不掉驭水
    mov tanks[0*SIZEOF TANK].effT, 1
    invoke AdvanceTicks, 1
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_WATER
    mov lGot, 0
    .if eax != 0
        mov lGot, 1
    .endif
    invoke Chk, offset stT21c, stT21cL, lGot, 1
    ; d) 离开水（传回走廊）+ 到期 -> 驭水位清除
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].effT, 1
    invoke AdvanceTicks, 1
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_WATER
    mov lGot, eax
    invoke Chk, offset stT21d, stT21dL, lGot, 0
    mov mapData[13*COLS+5], TILE_EMPTY     ; 还原走廊
    mov mapData[13*COLS+6], TILE_EMPTY

    ; ==== T22 定格术：虚影免伤 / 打虚影=真实伤害（1HP 即死）/ 二次放影 / 收回 ====
    invoke Mark, 221
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_PHANTOM
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 放虚影 #1（uses 初始化 2 -> 1）
    mov inputTable[20], 0
    ; a) 虚影就位在原地且效果激活
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    mov lGot, 0
    .if eax == 0
        jmp T22BadA
    .endif
    mov eax, tanks[0*SIZEOF TANK].phantomX
    cmp eax, 96
    jne T22BadA
    mov lGot, 1
T22BadA:
    invoke Chk, offset stT22a, stT22aL, lGot, 1
    ; b) 实像自由移动 -> 与虚影分离
    mov inputTable[0], 1
    invoke AdvanceTicks, 15
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov lGot, 0
    cmp eax, 110
    jbe T22BadB
    mov lGot, 1
T22BadB:
    invoke Chk, offset stT22b, stT22bL, lGot, 1
    ; c) 敌弹压在实像位置 -> 判定矩形=虚影，实像免伤
    mov bullets[0].active, 1
    mov bullets[0].owner, 1
    mov eax, tanks[0*SIZEOF TANK].x
    mov bullets[0].x, eax
    mov bullets[0].y, 420
    mov bullets[0].vx, 0
    mov bullets[0].vy, 0
    mov bullets[0].bounces, 0
    mov bullets[0].age, 0
    mov bullets[0].subpxX, 0
    mov bullets[0].subpxY, 0
    invoke AdvanceTicks, 2
    invoke Chk, offset stT22c, stT22cL, tanks[0*SIZEOF TANK].hp, 1
    ; d) 弹移到虚影框 -> 命中虚影 = 真实扣血（1HP 即死）+ 虚影消失
    mov bullets[0].x, 104
    invoke AdvanceTicks, 2
    mov eax, tanks[0*SIZEOF TANK].hp
    mov lGot, 0
    .if eax != 0
        jmp T22BadD
    .endif
    mov eax, tanks[0*SIZEOF TANK].alive
    .if eax != 0
        jmp T22BadD
    .endif
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    .if eax != 0
        jmp T22BadD
    .endif
    mov lGot, 1
T22BadD:
    invoke Chk, offset stT22d, stT22dL, lGot, 1
    ; e) 死亡清零 uses 后再拾取语义：发动 = 重新初始化 2 -> 1（新 2 次虚影）
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].skill, SK_PHANTOM
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    mov lGot, 0
    .if eax == 0
        jmp T22BadE
    .endif
    mov eax, tanks[0*SIZEOF TANK].phantomUses
    cmp eax, 1
    jne T22BadE
    mov eax, tanks[0*SIZEOF TANK].skill
    cmp eax, SK_PHANTOM
    jne T22BadE
    mov lGot, 1
T22BadE:
    invoke Chk, offset stT22e, stT22eL, lGot, 1
    ; f) 收回(uses=1 保 skill) -> 再发动(1->0) -> 再收回(uses==0 清 skill)
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 收回 #1
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].phantomUses
    cmp eax, 1
    jne T22BadF
    mov eax, tanks[0*SIZEOF TANK].skill
    cmp eax, SK_PHANTOM
    jne T22BadF
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 发动第二只：uses 1 -> 0
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    .if eax == 0
        jmp T22BadF
    .endif
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                      ; 再收回：uses==0 -> skill 清空
    mov inputTable[20], 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_PHANTOM
    mov lGot, 0
    .if eax != 0
        jmp T22BadF
    .endif
    mov eax, tanks[0*SIZEOF TANK].skill
    cmp eax, SKILL_NONE
    jne T22BadF
    mov lGot, 1
T22BadF:
    invoke Chk, offset stT22f, stT22fL, lGot, 1

    ; ==== T23 多命制：3 命击杀 -> 扣 1 命，1.5s 重生满血 + 保护剩余 120 ====
    invoke Mark, 231
    mov testLives, 3
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 32
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[1*SIZEOF TANK].x, 160
    mov tanks[1*SIZEOF TANK].y, 416
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
    invoke Chk, offset stT23a, stT23aL, tanks[1*SIZEOF TANK].lives, 2
    invoke AdvanceTicks, 120               ; 90 tick 重生 + 30 tick 已减保护
    invoke Chk, offset stT23b, stT23bL, tanks[1*SIZEOF TANK].alive, 1
    invoke Chk, offset stT23c, stT23cL, tanks[1*SIZEOF TANK].hp, TANK_HP
    invoke Chk, offset stT23d, stT23dL, tanks[1*SIZEOF TANK].protT, 120
    mov testLives, 1                       ; 恢复单命（保险）

    ; ==== T24 角度回绕（2026 回滚版致命 bug2 回归锁）：0-4=356 / 359+4=3 ====
    invoke Mark, 241
    call ResetTanks
    mov tanks[0*SIZEOF TANK].dir, 0
    mov inputTable[8], 1                   ; 左键（逆时针）
    invoke GameUpdate
    mov inputTable[8], 0
    mov eax, tanks[0*SIZEOF TANK].dir
    mov lGot, 0
    cmp eax, 356
    jne T24Bad
    mov tanks[0*SIZEOF TANK].dir, 359
    mov inputTable[12], 1                  ; 右键（顺时针）
    invoke GameUpdate
    mov inputTable[12], 0
    mov eax, tanks[0*SIZEOF TANK].dir
    cmp eax, 3
    jne T24Bad
    mov lGot, 1
T24Bad:
    invoke Chk, offset stT24, stT24L, lGot, 1

    ; ==== 清空大 box（cols2..13 x rows2..12）+ col14 竖钢墙（rows2..13），
    ;      供 T25/T26/T27/T29 的斜向弹道使用（收尾统一从 saveMap 还原） ====
    mov ebx, 2
STBoxR:
    mov ecx, 2
STBoxC:
    mov eax, ebx
    imul eax, eax, COLS
    add eax, ecx
    mov mapData[eax], TILE_EMPTY
    inc ecx
    cmp ecx, 14
    jb STBoxC
    inc ebx
    cmp ebx, 13
    jb STBoxR
    mov ebx, 2
STWallR:
    mov eax, ebx
    imul eax, eax, COLS
    add eax, 14
    mov mapData[eax], TILE_STEEL
    inc ebx
    cmp ebx, 14
    jb STWallR

    ; ==== T25 dir 纯度（回滚版致命 bug1 回归锁）：45 度前进 10 tick，
    ;      dir 仍 =45 且两轴位移均落在 21..27（会话 21 降速：35px 路程
    ;      x 0.707 分量 ~ 24.7） ====
    invoke Mark, 251
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 104
    mov tanks[0*SIZEOF TANK].y, 104
    mov tanks[0*SIZEOF TANK].dir, 45
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov lX0, 104
    mov lY0, 104
    invoke SetDirInput, 0
    invoke AdvanceTicks, 10
    invoke SetDirInput, 99
    mov lGot, 0
    mov eax, tanks[0*SIZEOF TANK].dir
    cmp eax, 45
    jne T25Bad
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, lX0
    cmp eax, 21
    jb T25Bad
    cmp eax, 27
    ja T25Bad
    mov eax, tanks[0*SIZEOF TANK].y
    sub eax, lY0
    cmp eax, 21
    jb T25Bad
    cmp eax, 27
    ja T25Bad
    mov lGot, 1
T25Bad:
    invoke Chk, offset stT25, stT25L, lGot, 1

    ; ==== T26 MuzzlePoint 炮口几何（Chebyshev 恒距 18px）：
    ;      0/90/180/270/45 五采样；用槽 3 尸体坦克（alive=0，逻辑不触碰） ====
    invoke Mark, 261
    mov edi, offset tanks
    add edi, 3*SIZEOF TANK
    mov (TANK ptr [edi]).alive, 0
    mov (TANK ptr [edi]).x, 100
    mov (TANK ptr [edi]).y, 100
    mov lPass, 0
    mov (TANK ptr [edi]).dir, 0
    invoke MuzzlePoint, edi
    cmp eax, 18
    jne ST26A
    cmp edx, 0
    jne ST26A
    inc lPass
ST26A:
    mov (TANK ptr [edi]).dir, 90
    invoke MuzzlePoint, edi
    cmp eax, 0
    jne ST26B
    cmp edx, 18
    jne ST26B
    inc lPass
ST26B:
    mov (TANK ptr [edi]).dir, 180
    invoke MuzzlePoint, edi
    cmp eax, -18
    jne ST26C
    cmp edx, 0
    jne ST26C
    inc lPass
ST26C:
    mov (TANK ptr [edi]).dir, 270
    invoke MuzzlePoint, edi
    cmp eax, 0
    jne ST26D
    cmp edx, -18
    jne ST26D
    inc lPass
ST26D:
    mov (TANK ptr [edi]).dir, 45
    invoke MuzzlePoint, edi
    cmp eax, 18
    jne ST26E
    cmp edx, 18
    jne ST26E
    inc lPass
ST26E:
    invoke Chk, offset stT26, stT26L, lPass, 5

    ; ==== T27 45 度弹道积分（回滚版 45 度提速失效回归锁）：
    ;      16.16 定点 -> 60 tick 精确 254px/轴（|v| 任意角恒 6） ====
    invoke Mark, 271
    call ResetTanks
    mov tanks[0*SIZEOF TANK].x, 64
    mov tanks[0*SIZEOF TANK].y, 64
    mov tanks[0*SIZEOF TANK].dir, 45
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].fireCd, 0
    mov inputTable[16], 1
    invoke GameUpdate                      ; 发射 45 度弹（弹起点 90,90）
    mov inputTable[16], 0
    ; 找到这颗弹并记录初始位置/速度
    mov esi, offset bullets
    xor ecx, ecx
ST27Find:
    cmp ecx, MAX_BULLETS
    jae ST27NotFound
    cmp (BULLET ptr [esi]).active, 0
    je ST27Next
    cmp (BULLET ptr [esi]).owner, 0
    jne ST27Next
    mov stBulIdx, ecx
    mov eax, (BULLET ptr [esi]).x
    mov stBulX0, eax
    mov eax, (BULLET ptr [esi]).y
    mov stBulY0, eax
    mov eax, (BULLET ptr [esi]).vx
    mov stVx0, eax
    mov eax, (BULLET ptr [esi]).vy
    mov stVy0, eax
    jmp ST27Found
ST27Next:
    add esi, SIZEOF BULLET
    inc ecx
    jmp ST27Find
ST27NotFound:
    mov lGot, 0
    jmp ST27Log
ST27Found:
    invoke AdvanceTicks, 60
    mov eax, stBulIdx
    imul eax, eax, SIZEOF BULLET
    add eax, offset bullets
    mov esi, eax
    mov lGot, 0
    mov eax, (BULLET ptr [esi]).x
    sub eax, stBulX0
    mov lTmp, eax
    cmp eax, 250
    jb ST27Bad
    cmp eax, 257
    ja ST27Bad
    mov eax, (BULLET ptr [esi]).y
    sub eax, stBulY0
    cmp eax, 250
    jb ST27Bad
    cmp eax, 257
    ja ST27Bad
    mov lGot, 1
ST27Bad:
ST27Log:
    invoke Chk, offset stT27, stT27L, lGot, 1

    ; ==== T28 网络 tdir 量化往返：13 个采样角 q=(a*256)/360 -> 还原误差 <2 ====
    invoke Mark, 281
    mov lPass, 0
    mov lIdx, 0
ST28Loop:
    mov eax, lIdx
    cmp eax, 13
    jge ST28Done
    mov esi, offset stAngTbl
    mov eax, [esi+eax*4]
    mov lTmp, eax                          ; a
    imul eax, eax, 256
    mov ecx, 360
    xor edx, edx
    div ecx                                ; q = a*256/360
    imul eax, eax, 360
    add eax, 128
    shr eax, 8                               ; 还原角
    sub eax, lTmp
    cmp eax, 0
    jge ST28Abs
    neg eax
ST28Abs:
    cmp eax, 2
    jae ST28Next
    inc lPass
ST28Next:
    mov eax, lIdx
    inc eax
    mov lIdx, eax
    jmp ST28Loop
ST28Done:
    invoke Chk, offset stT28, stT28L, lPass, 13

    ; ==== T29 斜弹撞墙反弹：|vx|/|vy| 取反保模（16.16 定点反弹回归锁） ====
    invoke Mark, 291
    mov tanks[0*SIZEOF TANK].alive, 0      ; 阵亡坦克不参与命中，防回流弹干扰
    invoke AdvanceTicks, 120
    mov eax, stBulIdx
    imul eax, eax, SIZEOF BULLET
    add eax, offset bullets
    mov esi, eax
    mov lGot, 0
    cmp (BULLET ptr [esi]).active, 0
    je ST29Log
    mov eax, (BULLET ptr [esi]).bounces
    cmp eax, 1
    jb ST29Log
    mov eax, (BULLET ptr [esi]).vx
    cmp eax, 0
    jge ST29AX
    neg eax
ST29AX:
    mov ecx, stVx0
    cmp ecx, 0
    jge ST29AY
    neg ecx
ST29AY:
    cmp eax, ecx
    jne ST29Log
    mov eax, (BULLET ptr [esi]).vy
    cmp eax, 0
    jge ST29BX
    neg eax
ST29BX:
    mov ecx, stVy0
    cmp ecx, 0
    jge ST29BY
    neg ecx
ST29BY:
    cmp eax, ecx
    jne ST29Log
    mov lGot, 1
ST29Log:
    invoke Chk, offset stT29, stT29L, lGot, 1

    ; ==== T30 滑行中转向：轨迹冻结在 sdir，不随 dir 改变（会话 19 新语义） ====
    invoke Mark, 301
    call ResetTanks
    mov mapData[13*COLS+20], TILE_ICE
    mov tanks[0*SIZEOF TANK].x, 640
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].alive, 1
    invoke SetDirInput, 0
    invoke GameUpdate                      ; 冰上起步 1 tick -> 触发滑行
    invoke SetDirInput, 99
    mov inputTable[12], 1                  ; 滑行中持续右转
    invoke GameUpdate
    invoke GameUpdate
    mov inputTable[12], 0
    mov lGot, 0
    mov eax, tanks[0*SIZEOF TANK].dir
    cmp eax, 8
    jne T30Bad
    mov eax, tanks[0*SIZEOF TANK].sdir
    cmp eax, 0
    jne T30Bad                             ; 滑行向量必须仍是出冰瞬间的 0
    mov eax, tanks[0*SIZEOF TANK].slide
    cmp eax, 6                             ; 仍在滑行（冰上刷新 6..15）
    jb T30Bad
    mov lGot, 1
T30Bad:
    invoke Chk, offset stT30, stT30L, lGot, 1

    ; ==== T31 三角表运行时抽查：正交角必须精确（表错全链路皆错） ====
    invoke Mark, 311
    mov lPass, 0
    mov eax, cosTBL[0]
    cmp eax, 1024
    jne ST31A
    inc lPass
ST31A:
    mov eax, sinTBL[90*4]
    cmp eax, 1024
    jne ST31B
    inc lPass
ST31B:
    mov eax, cosTBL[180*4]
    cmp eax, -1024
    jne ST31C
    inc lPass
ST31C:
    mov eax, sinTBL[0]
    test eax, eax
    jnz ST31D
    inc lPass
ST31D:
    invoke Chk, offset stT31, stT31L, lPass, 4

    ; ==== T32 边走边转（会话 20 操作手感回归）：同一 tick 内转向通道
    ;      与驾驶通道同时生效。引擎层本就并行（GameUpdate 先转向后驾驶），
    ;      "两键不同时生效"的元凶是主循环吞 tick（main.asm 已修），
    ;      此条守引擎层不回退。清出上部净空区，P1 从 (96,96) dir=45
    ;      按住 前进+右转 10 tick：dir=45+4*10=85，且车沿转过的弧线走了 ====
    invoke Mark, 312
    mov ecx, MAX_BULLETS*(SIZEOF BULLET)/4
    mov edi, offset bullets
    xor eax, eax
    rep stosd
    call ResetTanks
    ; 清空 cols2..13 x rows2..12（行车净空）
    mov ebx, 2
T32ClrRow:
    mov eax, ebx
    imul eax, eax, COLS
    add eax, 2
    mov ecx, 12
T32ClrCol:
    mov byte ptr mapData[eax], TILE_EMPTY
    inc eax
    dec ecx
    jnz T32ClrCol
    inc ebx
    cmp ebx, 12
    jbe T32ClrRow
    ; P2 输入清零（防前序用例残留）
    mov dword ptr inputTable[24], 0
    mov dword ptr inputTable[28], 0
    mov dword ptr inputTable[32], 0
    mov dword ptr inputTable[36], 0
    mov dword ptr inputTable[40], 0
    mov dword ptr inputTable[44], 0
    ; P1 摆位
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].x, 96
    mov tanks[0*SIZEOF TANK].y, 96
    mov tanks[0*SIZEOF TANK].dir, 45
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].effOn, 0
    ; 前进 + 右转 同按 10 tick
    mov inputTable[0], 1
    mov inputTable[12], 1
    invoke AdvanceTicks, 10
    mov inputTable[0], 0
    mov inputTable[12], 0
    mov lPass, 0
    ; a) 转向照常累计：dir == 85（驾驶没吞转向）
    mov eax, tanks[0*SIZEOF TANK].dir
    cmp eax, 85
    jne T32A
    inc lPass
T32A:
    ; b) 驾驶同步推进 dx 理论~13（会话 21 均速 3.5），容差 [5,19]
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 96
    cmp eax, 5
    jb T32B
    cmp eax, 19
    ja T32B
    inc lPass
T32B:
    ; c) dy 理论~32，容差 [22,40]（转向没把车钉在原地）
    mov eax, tanks[0*SIZEOF TANK].y
    sub eax, 96
    cmp eax, 22
    jb T32C
    cmp eax, 40
    ja T32C
    inc lPass
T32C:
    invoke Chk, offset stT32, stT32L, lPass, 3

    ; ==== T33 地形边缘判定（会话 20 地形残留回归）：车身一半出了地形
    ;      格就不应再有地形效果。把 P1 摆在 (3,13) 骑右缘位置（中心像素
    ;      仍在格内 —— 旧的中心单点判定会误触发效果） ====
    invoke Mark, 313
    mov byte ptr mapData[13*COLS+3], TILE_DIRT
    mov byte ptr mapData[13*COLS+4], TILE_EMPTY
    call ResetTanks
    mov dword ptr inputTable[24], 0
    mov dword ptr inputTable[28], 0
    mov dword ptr inputTable[32], 0
    mov dword ptr inputTable[36], 0
    mov dword ptr inputTable[40], 0
    mov dword ptr inputTable[44], 0
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].x, 115
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].effOn, 0
    mov inputTable[0], 1
    invoke GameUpdate
    mov inputTable[0], 0
    mov lPass, 0
    ; a) 半个车身在泥上：dx>=3（正常速下限）；旧判定中心在泥 -> dx=1
    mov eax, tanks[0*SIZEOF TANK].x
    sub eax, 115
    cmp eax, 3
    jb T33A
    inc lPass
T33A:
    ; b) 泥格换冰格，起点 (109,416)：走 1 tick 后中心仍在冰格、车身已
    ;    半出冰面 -> 不得触发滑行（旧判定会得到 slide>=6）
    mov byte ptr mapData[13*COLS+3], TILE_ICE
    mov tanks[0*SIZEOF TANK].x, 109
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov inputTable[0], 1
    invoke GameUpdate
    mov inputTable[0], 0
    mov eax, tanks[0*SIZEOF TANK].x
    cmp eax, 109                     ; 意外被挡则本条作废（不误加 lPass）
    jbe T33B
    mov eax, tanks[0*SIZEOF TANK].slide
    test eax, eax
    jnz T33B
    inc lPass
T33B:
    mov byte ptr mapData[13*COLS+3], TILE_EMPTY
    invoke Chk, offset stT33, stT33L, lPass, 2

    ; ==== T34 冰盾 7s 限时（会话 21 回归锁）：修复前 shieldT 从未初始化，
    ;      EffTick 到期分支永不执行 -> 冰盾成了永久盾 ====
    invoke Mark, 314
    call ResetTanks
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].protT, 0
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 发动冰盾
    mov inputTable[20], 0
    ; 清弹池：防前序测试残弹在长推进中击穿盾/击杀致回合重开（假通过）
    mov edi, offset bullets
    xor ecx, ecx
T34ClrB:
    mov (BULLET ptr [edi]).active, 0
    add edi, SIZEOF BULLET
    inc ecx
    .if ecx < MAX_BULLETS
        jmp T34ClrB
    .endif
    mov lPass, 0
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_SHIELD
    .if eax != 0
        inc lPass                        ; a) 发动后盾在
    .endif
    invoke AdvanceTicks, SHIELD_TICKS + 2
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_SHIELD
    .if eax == 0
        inc lPass                        ; b) 7s 到时自动消失（修复前此条 FAIL）
    .endif
    invoke Chk, offset stT34, stT34L, lPass, 2

    ; ==== T35 重生保护期不吃盾（会话 21 回归锁）：修复前 DamageTank 先走
    ;      冰盾分支，保护期被命中会白白烧掉一面盾还凭空铺冰 ====
    invoke Mark, 315
    call ResetTanks
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].protT, 150
    mov tanks[0*SIZEOF TANK].skill, SK_ICE_SHIELD
    mov prevUse[0], 0
    mov inputTable[20], 1
    invoke GameUpdate                    ; 保护期内发动冰盾
    mov inputTable[20], 0
    ; 贴一发弹（T14 同款压位手法，owner=P2 非自伤）
    mov bullets[0].active, 1
    mov bullets[0].owner, 1
    mov bullets[0].age, 0
    mov bullets[0].bounces, 0
    mov bullets[0].vx, 0
    mov bullets[0].vy, 0
    mov eax, tanks[0*SIZEOF TANK].x
    mov bullets[0].x, eax
    mov eax, tanks[0*SIZEOF TANK].y
    mov bullets[0].y, eax
    mov bullets[0].subpxX, 0
    mov bullets[0].subpxY, 0
    invoke GameUpdate
    mov lPass, 0
    mov eax, tanks[0*SIZEOF TANK].hp
    .if eax != 0
        inc lPass                        ; a) 保护期免伤
    .endif
    mov eax, tanks[0*SIZEOF TANK].effOn
    and eax, EFF_SHIELD
    .if eax != 0
        inc lPass                        ; b) 盾未被浪费（修复前此条 FAIL）
    .endif
    invoke Chk, offset stT35, stT35L, lPass, 2

    ; ==== T36 穿墙次数耗尽可脱离（会话 21 回归锁）：修复前 wallPass 用完
    ;      且中心仍在墙格时四面目标皆挡 -> 封死墙里直到死亡 ====
    invoke Mark, 316
    call ResetTanks
    mov byte ptr mapData[13*COLS+3], TILE_STEEL
    mov byte ptr mapData[13*COLS+4], TILE_EMPTY
    mov tanks[0*SIZEOF TANK].alive, 1
    mov tanks[0*SIZEOF TANK].hp, TANK_HP
    mov tanks[0*SIZEOF TANK].x, 100
    mov tanks[0*SIZEOF TANK].y, 416
    mov tanks[0*SIZEOF TANK].dir, 0
    mov tanks[0*SIZEOF TANK].subpxX, 0
    mov tanks[0*SIZEOF TANK].subpxY, 0
    mov tanks[0*SIZEOF TANK].slide, 0
    mov tanks[0*SIZEOF TANK].effOn, EFF_GHOST
    mov tanks[0*SIZEOF TANK].wallPass, 0
    mov tanks[0*SIZEOF TANK].effT, 360
    mov tanks[0*SIZEOF TANK].lastCell, 13*COLS+3
    invoke SetDirInput, 0                ; 朝右（同墙格内挪动 + 脱离方向皆右）
    invoke GameUpdate
    invoke SetDirInput, 99
    mov lGot, 0
    mov eax, tanks[0*SIZEOF TANK].x
    cmp eax, 100
    jbe T36Bad                           ; 修复前：一步都动不了（FAIL）
    mov eax, tanks[0*SIZEOF TANK].wallPass
    .if eax == 0                         ; 脱离不消耗/不新增次数
        mov lGot, 1
    .endif
T36Bad:
    invoke Chk, offset stT36, stT36L, lGot, 1

    ; ==== 收尾：还原地图 + 清空弹池 + FAIL 汇总 ====
    invoke Mark, 320
    cld
    mov esi, offset saveMap
    mov edi, offset mapData
    mov ecx, COLS*ROWS
    rep movsb
    mov ecx, MAX_BULLETS*(SIZEOF BULLET)/4
    mov edi, offset bullets
    xor eax, eax
    rep stosd
    invoke LogStr, offset stFails, stFailsL
    invoke LogNum, stFailN
    invoke LogStr, offset stDone, stDoneL
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
; TankTerrMajority —— 地形"四象限全点"判定（会话 20）
; 旧版用坦克中心单像素判泥土减速/冰面滑行：25px 车身骑在 32px 格上时，
; 车身早已视觉离开该格而中心点还留在格内，效果"赖着不走"（用户点名：
; 不在地形内效果依然会保留）。
; 新规则：在车身四个象限中心 (x+6/x+18, y+6/y+18) 各放一个采样点，
; 4 点全部落在指定地形类型（多格同类型地形按"区域"合并计）才算
; "站在该地形上"。阈值取 4 而非 2：若只要求 >=2，坦克中心仍跨在
; 格内时旧病依旧（半辆车身在格外仍减速/滑行）。四格全中意味着车身
; 核心 12x12 区域完整位于地形内（单格地形时车身重叠 >=76%），
; 与肉眼"踩在上面"一致。坦克摆正单格内时 4 点同格，与旧中心判定
; 等价（自测摆位全部在格原点，语义不变）。
; 水域保持"覆盖任一格即阻挡"——车身边缘碰到水就应停下，不放行。
; ------------------------------------------------------------
TankTerrMajority proc uses ebx esi edi tankP: dword, tileType: dword
    local px0:dword, px1:dword, py0:dword, py1:dword, cnt:dword
    mov esi, tankP
    mov eax, (TANK ptr [esi]).x
    add eax, TANK_SIZE/4
    mov px0, eax
    mov eax, (TANK ptr [esi]).x
    add eax, TANK_SIZE*3/4
    mov px1, eax
    mov eax, (TANK ptr [esi]).y
    add eax, TANK_SIZE/4
    mov py0, eax
    mov eax, (TANK ptr [esi]).y
    add eax, TANK_SIZE*3/4
    mov py1, eax
    mov cnt, 0
    invoke TileAtPx, px0, py0
    .if eax == tileType
        inc cnt
    .endif
    invoke TileAtPx, px0, py1
    .if eax == tileType
        inc cnt
    .endif
    invoke TileAtPx, px1, py0
    .if eax == tileType
        inc cnt
    .endif
    invoke TileAtPx, px1, py1
    .if eax == tileType
        inc cnt
    .endif
    mov eax, cnt
    cmp eax, 4
    jb TTM_No
    mov eax, 1
    ret
TTM_No:
    xor eax, eax
    ret
TankTerrMajority endp

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
    ; 会话 21 修复：重生保护期最先判定并直接免疫 —— 旧版先走虚影/冰盾
    ; 分支，保护期被命中会白白烧掉一面盾（并凭空铺开 2x2 冰面）
    mov eax, (TANK ptr [ebx]).protT
    .if eax > 0
        mov eax, 2                   ; 保护期免伤（不消耗护盾/虚影）
        ret
    .endif
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
; SegmentDamage —— 折线段上所有存活坦克受击（每辆至多一次）
; 会话 19：旧版只认轴对齐段（x0==x1 判垂直、否则当水平），斜段静默错位。
; 现改主轴逐像素采样（n=max(|dx|,|dy|)，16.16 步进，含两端点）+ 点入
; 坦克 AABB 判定；轴对齐段同样正确（端点全覆盖）。
; ------------------------------------------------------------
SegmentDamage proc uses ebx esi edi pXs: dword, pYs: dword, nPts: dword
    local x0:dword, y0:dword, segDx:dword, segDy:dword, sampN:dword
    local stepX:dword, stepY:dword, accX:dword, accY:dword
    local sampI:dword, px:dword, py:dword, hitmask:dword
    .if nPts < 2
        ret
    .endif
    mov hitmask, 0
    xor ebx, ebx                     ; 折线段起点下标
SD_Seg:
    mov eax, nPts
    dec eax
    .if ebx >= eax
        jmp SD_Done
    .endif
    mov ecx, pXs
    mov eax, [ecx+ebx*4]
    mov edx, [ecx+ebx*4+4]
    sub edx, eax                     ; segDx = x[i+1]-x[i]（有符号）
    mov x0, eax
    mov segDx, edx
    mov ecx, pYs
    mov eax, [ecx+ebx*4]
    mov edx, [ecx+ebx*4+4]
    sub edx, eax
    mov y0, eax
    mov segDy, edx
    ; sampN = max(|dx|,|dy|)，0 段取 1（防除零）
    mov eax, segDx
    test eax, eax
    jns SD_AbsDX
    neg eax
SD_AbsDX:
    mov ecx, segDy
    test ecx, ecx
    jns SD_AbsDY
    neg ecx
SD_AbsDY:
    cmp eax, ecx
    jae SD_NOK
    mov eax, ecx
SD_NOK:
    .if eax == 0
        mov eax, 1
    .endif
    mov sampN, eax
    ; stepX/Y = (d << 16) / n（idiv 有符号截零，两端点 i=0/n 精确命中）
    mov eax, segDx
    shl eax, 16
    cdq
    idiv sampN
    mov stepX, eax
    mov eax, segDy
    shl eax, 16
    cdq
    idiv sampN
    mov stepY, eax
    mov accX, 0
    mov accY, 0
    mov sampI, 0
SD_Sample:
    ; 当前采样点：floor(acc/65536) = (acc - 低16位) 后 sar16（负值借位正确）
    mov eax, accX
    mov edx, eax
    and edx, 0FFFFh
    sub eax, edx
    sar eax, 16
    add eax, x0
    mov px, eax
    mov eax, accY
    mov edx, eax
    and edx, 0FFFFh
    sub eax, edx
    sar eax, 16
    add eax, y0
    mov py, eax
    ; 4 坦克点入盒判定 [tx,tx+25) x [ty,ty+25)
    xor esi, esi
SD_Tank:
    .if esi >= MAX_PLAYERS
        jmp SD_NextSample
    .endif
    mov eax, hitmask
    mov ecx, esi                     ; sil 在 .386 不存在：1<<slot 用 cl 变移位
    mov eax, 1
    shl eax, cl
    test eax, hitmask
    jnz SD_ThNext                    ; 本段调用内已伤过，不重复
    mov eax, esi
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edi, eax
    cmp (TANK ptr [edi]).alive, 0
    je SD_ThNext
    mov eax, px
    cmp eax, (TANK ptr [edi]).x
    jl SD_ThNext
    mov ecx, (TANK ptr [edi]).x
    add ecx, TANK_SIZE
    cmp eax, ecx
    jge SD_ThNext
    mov eax, py
    cmp eax, (TANK ptr [edi]).y
    jl SD_ThNext
    mov ecx, (TANK ptr [edi]).y
    add ecx, TANK_SIZE
    cmp eax, ecx
    jge SD_ThNext
    ; 命中：置掩码 + 统一伤害入口（冰盾可挡）
    mov eax, 1
    mov ecx, esi
    shl eax, cl
    or eax, hitmask
    mov hitmask, eax
    push esi
    push edi
    invoke DamageTank, esi
    pop edi
    pop esi
SD_ThNext:
    inc esi
    jmp SD_Tank
SD_NextSample:
    mov eax, accX
    add eax, stepX
    mov accX, eax
    mov eax, accY
    add eax, stepY
    mov accY, eax
    mov eax, sampI
    inc eax
    mov sampI, eax
    cmp eax, sampN
    jle SD_Sample
    inc ebx
    jmp SD_Seg
SD_Done:
    ret
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
    local subpxX:dword, subpxY:dword
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
    ; 起点 = 炮口（与 SpawnBullet 同式 MuzzlePoint；旧 4 分支种子轴锁，
    ; 斜角预览会错位。速度 = 16.16 定点，与实弹同步进同进位）
    invoke MuzzlePoint, ptank        ; eax=offx edx=offy（ebx/ecx 受保护）
    mov ebx, eax
    mov ecx, edx
    mov esi, ptank                   ; 必须经寄存器解引用：局部槽 [ptank] 里装的是指针值，
    mov eax, (TANK ptr [esi]).x      ; 直接 (TANK ptr [ptank]).x 只会算出成员地址而不读值
    add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
    add eax, ebx
    mov x, eax
    mov eax, (TANK ptr [esi]).y
    add eax, (TANK_SIZE - BULLET_SIZE_PX)/2
    add eax, ecx
    mov y, eax
    mov eax, (TANK ptr [esi]).dir
    mov ebx, cosTBL[eax*4]
    imul ebx, ebx, BULLET_SPEED*FIX_TBL64
    mov vx, ebx
    mov ebx, sinTBL[eax*4]
    imul ebx, ebx, BULLET_SPEED*FIX_TBL64
    mov vy, ebx
    mov ebx, 0
    mov subpxX, ebx
    mov subpxY, ebx
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
        ; 进位步进（与 BulletTick 完全同构 -> 预览与实弹逐 tick 一致）
        mov eax, subpxX
        add eax, vx
        mov edx, eax
        sar edx, 16
        and eax, 0FFFFh
        mov subpxX, eax
        mov ecx, x
        add ecx, edx
        mov x, ecx
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
        ; 进位步进（同 X 轴）
        mov eax, subpxY
        add eax, vy
        mov edx, eax
        sar edx, 16
        and eax, 0FFFFh
        mov subpxY, eax
        mov ecx, y
        add ecx, edx
        mov y, ecx
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
; MuzzleEdge —— 直线激光终点（炮口中心沿航向角到地图边界）
; 会话 19：旧 4 分支轴锁版作废，改参数化射线求交（2 次除法，无步进）。
; 写入 laserX/Y[0..1]（[0]=炮口中心，[4]=边界交点），laserN=2
; ------------------------------------------------------------
MuzzleEdge proc uses ebx ecx edx slotIdx: dword
    local mx:dword, my:dword, cV:dword, sV:dword, tXv:dword, tYv:dword
    local tM:dword, eX:dword, eY:dword
    mov eax, slotIdx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov ebx, eax
    invoke MuzzlePoint, ebx          ; eax=offx edx=offy（ebx/ecx 受保护）
    mov ecx, (TANK ptr [ebx]).x
    add ecx, eax
    add ecx, TANK_SIZE/2             ; 弹左上 +4 = 中心：x+8+off+4
    mov mx, ecx
    mov ecx, (TANK ptr [ebx]).y
    add ecx, edx
    add ecx, TANK_SIZE/2
    mov my, ecx
    ; 起点钳进地图矩形（坦克贴界时炮口中心会出界几 px，参数会负）
    mov eax, mx
    test eax, eax
    jns ME_MxOK
    xor eax, eax
ME_MxOK:
    cmp eax, MAP_W
    jbe ME_MxOK2
    mov eax, MAP_W
ME_MxOK2:
    mov mx, eax
    mov eax, my
    test eax, eax
    jns ME_MyOK
    xor eax, eax
ME_MyOK:
    cmp eax, MAP_H
    jbe ME_MyOK2
    mov eax, MAP_H
ME_MyOK2:
    mov my, eax
    ; 单位向量（x1024）
    mov eax, (TANK ptr [ebx]).dir
    mov ecx, cosTBL[eax*4]
    mov cV, ecx
    mov edx, sinTBL[eax*4]
    mov sV, edx
    ; tXv = 到左右边界参数（1024 单位/px）；轴平行取大值不会被 min 选中
    mov tXv, 0FFFFFFFEh
    test ecx, ecx
    jz ME_NoX
    jns ME_XPos
    neg ecx                          ; c<0：撞左界，分母取 |c|
    mov eax, mx
    imul eax, eax, 1024
    xor edx, edx
    div ecx
    mov tXv, eax
    jmp ME_NoX
ME_XPos:
    mov eax, MAP_W
    sub eax, mx
    imul eax, eax, 1024
    xor edx, edx
    div ecx
    mov tXv, eax
ME_NoX:
    ; tYv（ecx 已被破坏，从 sV 重载）
    mov tYv, 0FFFFFFFEh
    mov ecx, sV
    test ecx, ecx
    jz ME_NoY
    jns ME_YPos
    neg ecx
    mov eax, my
    imul eax, eax, 1024
    xor edx, edx
    div ecx
    mov tYv, eax
    jmp ME_NoY
ME_YPos:
    mov eax, MAP_H
    sub eax, my
    imul eax, eax, 1024
    xor edx, edx
    div ecx
    mov tYv, eax
ME_NoY:
    ; tM = min(tXv, tYv)：至少一轴不平行 -> 有限（<=~3000），乘积不溢出
    mov eax, tXv
    cmp eax, tYv
    jbe ME_MinOK
    mov eax, tYv
ME_MinOK:
    mov tM, eax
    ; 终点 = 起点 + 单位向量 x t >> 10（cV/sV 有符号 -> imul + sar 下取整）
    imul eax, cV
    sar eax, 10
    add eax, mx
    mov eX, eax
    mov eax, tM
    imul eax, sV
    sar eax, 10
    add eax, my
    mov eY, eax
    mov eax, mx
    mov laserX[0], eax
    mov eax, my
    mov laserY[0], eax
    mov eax, eX
    mov laserX[4], eax
    mov eax, eY
    mov laserY[4], eax
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
    imul eax, eax, SIZEOF BULLET     ; 会话 19：BULLET 32->44B，shl 5 步长作废
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
    imul eax, eax, SIZEOF BULLET
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
    ; 坦克朝向 = 子弹发射角（会话 19：直接继承 fireAng；旧版从 vx/vy 符号
    ; 反推 4 方向，斜弹换位会静默把车拧成朝右）
    mov eax, (BULLET ptr [esi]).fireAng
    mov (TANK ptr [ecx]).dir, eax
    mov edx, 0
    mov (TANK ptr [ecx]).subpxX, edx
    mov (TANK ptr [ecx]).subpxY, edx
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
        ; 会话 21 修复：启动 7s 限时（旧版漏初始化 shieldT，
        ; EffTick 的到期分支永远不执行 -> 冰盾变成永久盾）
        mov (TANK ptr [ecx]).shieldT, SHIELD_TICKS
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
    mov bulIdx, eax                 ; 先存槽索引
    ; 会话 19：速度向量 = 航向角单位向量 x BULLET_SPEED，16.16 定点
    ; （任意角 |v|=6 精确；旧整数表 45 度弹只能飞出 5.66 且轴向阶梯）
    mov ecx, (TANK ptr [ebx]).dir
    mov (BULLET ptr [esi]).fireAng, ecx
    mov eax, cosTBL[ecx*4]
    imul eax, eax, BULLET_SPEED*FIX_TBL64
    mov (BULLET ptr [esi]).vx, eax
    mov eax, sinTBL[ecx*4]
    imul eax, eax, BULLET_SPEED*FIX_TBL64
    mov (BULLET ptr [esi]).vy, eax
    mov eax, 0
    mov (BULLET ptr [esi]).subpxX, eax
    mov (BULLET ptr [esi]).subpxY, eax
    ; 位置：炮口（MuzzlePoint 切比雪夫分离，弹盒与己方 AABB 主轴出界，
    ; 任意角保持 T12 自伤保护；旧 4 分支表把出弹点锁死在轴向）
    invoke MuzzlePoint, ebx              ; eax=offx edx=offy（ebx/esi 受保护）
    mov ecx, (TANK ptr [ebx]).x
    add ecx, eax
    add ecx, (TANK_SIZE - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).x, ecx
    mov ecx, (TANK ptr [ebx]).y
    add ecx, edx
    add ecx, (TANK_SIZE - BULLET_SIZE_PX)/2
    mov (BULLET ptr [esi]).y, ecx
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
; MuzzlePoint —— 全角度炮口分离偏移（切比雪夫分离式）
; 保证 8x8 弹盒与 25px 坦克 AABB 沿主轴分离 >=17px（T12 自伤保护的
; 任意角推广）。SpawnBullet / MuzzleEdge / SimReflectPath 三处共用，
; 杜绝公式漂移。入参：坦克指针；出参 eax=offx, edx=offy。
; 弹左上 = tank.x+8+offx, tank.y+8+offy（弹中心再 +4）。
; 数学：m=max(|c|,|s|)>=724（恒不为 0），D=17408/m+1（17px x1024 +1
; 防向下取整），off=(tbl*D+512) sar 10（主轴 |off|>=17）。
; ------------------------------------------------------------
MuzzlePoint proc uses ebx ecx tankPtr: dword
    local c1:dword, s1:dword, m: dword
    mov ecx, tankPtr
    mov eax, (TANK ptr [ecx]).dir
    mov ebx, cosTBL[eax*4]
    mov c1, ebx
    mov ebx, sinTBL[eax*4]
    mov s1, ebx
    ; m = max(|c|, |s|)
    mov eax, c1
    test eax, eax
    jns MP_CAbs
    neg eax
MP_CAbs:
    mov m, eax
    mov eax, s1
    test eax, eax
    jns MP_SAbs
    neg eax
MP_SAbs:
    cmp eax, m
    jbe MP_MDone
    mov m, eax
MP_MDone:
    ; D = 17408/m + 1（m>0 恒成立；div 无符号两侧均正）
    mov eax, 17408
    xor edx, edx
    div m
    inc eax
    mov m, eax
    ; offx = (c1*D + 512) >> 10；offy 同（c1/s1 有符号 -> imul+sar）
    mov ecx, m
    imul eax, c1
    add eax, 512
    sar eax, 10
    imul ecx, s1
    add ecx, 512
    sar ecx, 10
    mov edx, ecx
    ret
MuzzlePoint endp

; ------------------------------------------------------------
; MoveTank —— 坦克移动（水/钢/砖实心，冰/泥/空地可通行）
; 会话 19：沿航向角 moveF 前进(1)/后退(-1)，16.16 定点进位位移；
; 冰面：位移成功且四象限全在冰格 -> 刷新滑行 tick 并冻结当前航向角
; 泥土：四象限全在泥格 -> 本 tick 速度 DIRT_SPEED，否则 3/4 交替
; （会话 20：中心单点判定改为 TankTerrMajority 全点判定）
; 本函数绝不写 dir（旧 360 版致命 bug1：把动作码 mov 进 dir 清零航向）
; ------------------------------------------------------------
MoveTank proc uses esi edi ownerIdx: dword, moveF: dword, ang: dword
    local nx:dword, ny:dword, solid:dword, ptank:dword
    local spd:dword, dx16:dword, dy16:dword, accX:dword, accY:dword
    local lCRow:dword
    ; ptank = &tanks[ownerIdx]（跨 invoke 保存，用局部变量存指针）
    mov eax, ownerIdx
    mov ecx, SIZEOF TANK
    imul ecx, eax
    add ecx, offset tanks
    mov ptank, ecx

    ; 泥土减速：四象限全点判定（会话 20：中心单点会"车已离泥仍减速"）
    invoke TankTerrMajority, ptank, TILE_DIRT
    .if eax != 0
        mov eax, DIRT_SPEED
    .else
        ; 3/4 交替（平均 3.5 = 子弹 6 的 ~58%）：奇数 tick 用 HI
        mov eax, TANK_SPEED
        mov edx, gTick
        test edx, 1
        jz MT_SpdEven
        mov eax, TANK_SPEED_HI
MT_SpdEven:
    .endif
    ; 燃油加速：+2（3->5, 4->6 平均 5.5 ≈ +57%），与泥地减速叠加
    mov ecx, ptank
    mov edx, (TANK ptr [ecx]).effOn
    .if edx & EFF_NITRO
        add eax, 2
    .endif
    mov spd, eax

    ; 计算新坐标（16.16 定点：单位向量 x 速度，任意角度模长精确；
    ; 正交角 carry 恰为 +-spd、余数恒 0 -> 与旧网格版逐像素一致）
    mov ecx, ang
    mov eax, cosTBL[ecx*4]
    imul eax, spd
    imul eax, eax, FIX_TBL64
    mov dx16, eax
    mov eax, sinTBL[ecx*4]
    imul eax, spd
    imul eax, eax, FIX_TBL64
    mov dy16, eax
    mov eax, moveF
    test eax, eax
    js MT_Rev                       ; 后退：位移向量取反（手写 js，.if==-1 之外勿用比较符）
    jmp MT_RevDone
MT_Rev:
    neg dx16
    neg dy16
MT_RevDone:
    ; 进位累加（先试探，位移成功才提交 subpx；被挡时在 else 分支清零）
    mov ecx, ptank
    mov eax, (TANK ptr [ecx]).subpxX
    add eax, dx16
    mov edx, eax
    sar edx, 16                     ; 本 tick x 位移（floor，含借位）
    and eax, 0FFFFh
    mov accX, eax
    add edx, (TANK ptr [ecx]).x
    mov nx, edx
    mov eax, (TANK ptr [ecx]).subpxY
    add eax, dy16
    mov edx, eax
    sar edx, 16
    and eax, 0FFFFh
    mov accY, eax
    add edx, (TANK ptr [ecx]).y
    mov ny, edx

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
            .else
                ; 会话 21 修复：次数耗尽但身体仍在墙格内 -> 旧版四面皆挡
                ; 彻底卡死在墙里直到死亡。现允许"脱离移动"：当前中心格
                ; 是墙时放行 目标中心=本格（格内挪动）或 目标中心非墙
                ; （走出）的位移，不消耗穿墙次数（薄墙本就贴边可出，
                ; 此分支救的是厚砖/钢群里用完 3 次的情况）
                ; 注：esi/edi 的保存靠 proc uses（GameUpdate 循环把 esi
                ; 当槽位偏移跨 MoveTank 复用，裸破坏会越界崩溃）
                mov esi, ptank
                mov edi, (TANK ptr [esi]).x
                add edi, TANK_SIZE/2
                shr edi, 5                  ; 当前中心列
                mov eax, (TANK ptr [esi]).y
                add eax, TANK_SIZE/2
                shr eax, 5
                mov lCRow, eax              ; 当前中心行（IsWallCell 毁 eax，先存）
                invoke IsWallCell, edi, eax
                .if eax != 0                ; 嵌在墙里才有脱离豁免
                    mov ecx, nx
                    add ecx, TANK_SIZE/2
                    shr ecx, 5
                    mov edx, ny
                    add edx, TANK_SIZE/2
                    shr edx, 5
                    .if ecx == edi && edx == lCRow
                        mov solid, 0        ; 同墙格内挪动
                    .else
                        invoke IsWallCell, ecx, edx
                        .if eax == 0
                            mov solid, 0    ; 目标中心已出墙 = 脱离
                        .endif
                    .endif
                .endif
            .endif
        .endif
    .endif

    mov ecx, ptank
    .if solid == 0
        mov edx, nx
        mov (TANK ptr [ecx]).x, edx
        mov edx, ny
        mov (TANK ptr [ecx]).y, edx
        mov edx, accX
        mov (TANK ptr [ecx]).subpxX, edx
        mov edx, accY
        mov (TANK ptr [ecx]).subpxY, edx
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
        ; 冰面判定：四象限全点（会话 20：与泥土同因，车已离冰不应再滑行）
        invoke TankTerrMajority, ptank, TILE_ICE
        .if eax != 0
            invoke RngBelow, ICE_SLIDE_RNG   ; 0..4
            add eax, ICE_SLIDE_MIN           ; 6..15 tick
            mov ecx, ptank
            mov edx, ang                     ; 冻结本 tick 实际使用角：滑行中转向不改轨迹
            mov (TANK ptr [ecx]).sdir, edx
            mov (TANK ptr [ecx]).slide, eax
        .else
            mov ecx, ptank
            mov (TANK ptr [ecx]).slide, 0
        .endif
    .else
        mov (TANK ptr [ecx]).slide, 0        ; 撞墙立即停滑
        mov edx, 0                           ; 被挡清分数余量（防旧余量偏置新方向）
        mov (TANK ptr [ecx]).subpxX, edx
        mov (TANK ptr [ecx]).subpxY, edx
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
    ; ---- 转向通道（会话 19：独立于驾驶通道，可边走边转）----
    ; 左键槽2=逆时针（角减小），右键槽3=顺时针（角增大，屏幕 y 向下 CW+）
    mov eax, ebx
    imul eax, eax, SIZEOF TANK
    add eax, offset tanks
    mov edx, eax                       ; edx = &tanks[slot]
    mov eax, (TANK ptr [edx]).alive
    .if eax == 0
        jmp GU_NoMove                  ; 死亡坦克不转向/不驾驶/不滑行（旧版按住键尸体会移动）
    .endif
    mov ecx, inputTable[esi+8]
    .if ecx != 0
        mov eax, (TANK ptr [edx]).dir
        sub eax, TURN_SPEED
        test eax, eax                  ; 回绕手写 js：.if eax<0 按无符号编译恒假
        jns GU_TurnLOk                 ; （2026 回滚版致命 bug2 就死在这里 -> 表越界）
        add eax, ANGLE_SPAN
GU_TurnLOk:
        mov (TANK ptr [edx]).dir, eax
    .endif
    mov ecx, inputTable[esi+12]
    .if ecx != 0
        mov eax, (TANK ptr [edx]).dir
        add eax, TURN_SPEED
        cmp eax, ANGLE_SPAN
        jb GU_TurnROk
        sub eax, ANGLE_SPAN
GU_TurnROk:
        mov (TANK ptr [edx]).dir, eax
    .endif
    ; ---- 驾驶通道：槽0=前进、槽1=后退（双键同按=前进优先，与旧行为一致）----
    mov dirWanted, 0
    mov eax, inputTable[esi]
    .if eax != 0
        mov dirWanted, 1
    .else
        mov eax, inputTable[esi+4]
        .if eax != 0
            mov dirWanted, -1
        .endif
    .endif
    mov eax, dirWanted
    .if eax != 0
        mov ecx, (TANK ptr [edx]).dir
        invoke MoveTank, ebx, eax, ecx
    .else
        ; 不驾驶 -> 冰面滑行（沿冻结角 sdir 前进；滑行中 dir 可转但轨迹不变）
        mov eax, (TANK ptr [edx]).slide
        .if eax > 0
            dec (TANK ptr [edx]).slide
            mov ecx, (TANK ptr [edx]).sdir
            mov eax, 1
            invoke MoveTank, ebx, eax, ecx
        .endif
    .endif
GU_NoMove:
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
        imul ecx, ecx, SIZEOF BULLET
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
        ; 1) X 轴（16.16 进位累加：任意角度轴向步长 0..8px，模长恒 6）
        mov eax, (BULLET ptr [edi]).vx
        .if eax != 0
            mov edx, (BULLET ptr [edi]).subpxX
            add edx, eax
            mov eax, edx
            sar eax, 16                    ; 位移 = 累加和 floor 除 65536（含借位）
            and edx, 0FFFFh                ; 余数归一化 0..65535
            mov (BULLET ptr [edi]).subpxX, edx
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
        ; 2) Y 轴（同 X：进位累加）
        mov eax, (BULLET ptr [edi]).vy
        .if eax != 0
            mov edx, (BULLET ptr [edi]).subpxY
            add edx, eax
            mov eax, edx
            sar eax, 16
            and edx, 0FFFFh
            mov (BULLET ptr [edi]).subpxY, edx
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
