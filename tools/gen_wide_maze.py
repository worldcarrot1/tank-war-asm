# -*- coding: utf-8 -*-
# Maze generator v3 (2026-10-16 user feedback):
#   1) NO dot walls: every wall cell must belong to a straight run >= 3
#   2) water pools are 3x3 blocks (>= 9 cells)
#   3) ice strips are corridor-wide (2 cells) and long (>= 4 cells)
#   4) dirt strips (tan, slows tanks), also corridor-wide
#   5) symmetric, spawns reachable, nothing sealed off
# ASCII only in output .inc (map chars are ASCII).
import random
from collections import deque

MW, MH = 31, 20
CW, CH = 10, 6
SPAWNS = [(1,1),(1,29),(17,1),(17,29)]   # (r,c)

def base_maze(seed, braid=0.15):
    rng = random.Random(seed)
    grid = [['#']*MW for _ in range(MH)]
    def cellblock(cx, cy):
        for dy in range(2):
            for dx in range(2):
                grid[3*cy+1+dy][3*cx+1+dx] = '.'
                grid[3*cy+1+dy][30-(3*cx+1+dx)] = '.'
    for cx in range(CW):
        for cy in range(CH):
            cellblock(cx, cy)
    visited = [[False]*CH for _ in range(CW)]
    passages = set()
    stack = [(0,0)]
    visited[0][0] = True
    while stack:
        x, y = stack[-1]
        nbrs = [(x+dx, y+dy) for dx, dy in ((1,0),(-1,0),(0,1),(0,-1))
                if 0 <= x+dx < CW and 0 <= y+dy < CH and not visited[x+dx][y+dy]]
        if not nbrs:
            stack.pop(); continue
        nx, ny = rng.choice(nbrs)
        visited[nx][ny] = True
        passages.add(tuple(sorted(((x,y),(nx,ny)))))
        stack.append((nx,ny))
    for x in range(CW):
        for y in range(CH):
            if x+1 < CW:
                a,b=(x,y),(x+1,y)
                if tuple(sorted((a,b))) not in passages and rng.random() < braid:
                    passages.add(tuple(sorted((a,b))))
            if y+1 < CH:
                a,b=(x,y),(x,y+1)
                if tuple(sorted((a,b))) not in passages and rng.random() < braid:
                    passages.add(tuple(sorted((a,b))))
    for (a, b) in passages:
        (x1,y1),(x2,y2) = a, b
        if x1 == x2:
            r = 3*y1+3; c = 3*x1+1
        else:
            r = 3*y1+1; c = 3*max(x1,x2)
        for rr in (r, r+1):
            grid[rr][c] = '.'; grid[rr][30-c] = '.'
    for r, c in SPAWNS:
        grid[r][c] = 'S'
    return grid, rng

def runs_ok(grid, r, c, min_run):
    """cell (r,c) is '#' and belongs to a straight wall run >= min_run?"""
    L = 1
    x = c-1
    while x >= 0 and grid[r][x] == '#': L += 1; x -= 1
    x = c+1
    while x < MW and grid[r][x] == '#': L += 1; x += 1
    if L >= min_run: return True
    L = 1
    y = r-1
    while y >= 0 and grid[y][c] == '#': L += 1; y -= 1
    y = r+1
    while y < MH and grid[y][c] == '#': L += 1; y += 1
    return L >= min_run

def thin_walls(grid, min_run=3):
    """Iteratively remove wall cells not part of a straight run >= min_run.
    Kills isolated dots and short stubs; remaining walls are long lines."""
    changed = True
    while changed:
        changed = False
        kill = []
        for r in range(1, MH-1):
            for c in range(1, MW-1):
                if grid[r][c] == '#' and not runs_ok(grid, r, c, min_run):
                    kill.append((r,c))
        for (r,c) in kill:
            grid[r][c] = '.'
            grid[r][30-c] = '.'
            changed = True
    return grid

def passable(grid, r, c):
    v = grid[r][c]
    return v not in '#b~'

def connected(grid):
    seen = {SPAWNS[0]}
    dq = deque([SPAWNS[0]])
    while dq:
        y,x = dq.popleft()
        for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)):
            ny,nx = y+dy, x+dx
            if 0<=ny<MH and 0<=nx<MW and (ny,nx) not in seen and passable(grid,ny,nx):
                seen.add((ny,nx)); dq.append((ny,nx))
    total = sum(1 for y in range(MH) for x in range(MW) if passable(grid,y,x))
    ok = len(seen) == total
    for s in SPAWNS[1:]:
        ok = ok and s in seen
    return ok

def near_spawn(r, c, margin=2):
    for (sr,sc) in SPAWNS:
        if abs(r-sr) <= margin and abs(c-sc) <= margin:
            return True
    return False

def place_water(grid, rng, pools=1):
    """3x3 water pools, symmetric, keep connectivity."""
    placed = 0
    cand = []
    for r in range(1, MH-4):
        for c in range(1, 13):        # window c..c+2 disjoint from mirror
            if all(grid[r+dy][c+dx] == '.' for dy in range(3) for dx in range(3)):
                if near_spawn(r, c, 3) or near_spawn(r, c+2, 3):
                    continue
                cand.append((r,c))
    rng.shuffle(cand)
    for (r,c) in cand:
        if placed >= pools: break
        cells = [(r+dy, c+dx) for dy in range(3) for dx in range(3)]
        for (rr,cc) in cells:
            grid[rr][cc] = '~'; grid[rr][30-cc] = '~'
        if connected(grid):
            placed += 1
        else:
            for (rr,cc) in cells:
                grid[rr][cc] = '.'; grid[rr][30-cc] = '.'
    return placed

def h_runs(grid):
    """horizontal 2-tall corridor runs: (r, c0, length), left half only."""
    out = []
    for r in range(1, MH-2):
        run = []
        for c in range(1, 16):
            if grid[r][c] == '.' and grid[r+1][c] == '.':
                run.append(c)
            else:
                if len(run) >= 4: out.append((r, run[0], len(run)))
                run = []
        if len(run) >= 4: out.append((r, run[0], len(run)))
    return out

def v_runs(grid):
    """vertical 2-wide corridor runs: (c, r0, length), left half only."""
    out = []
    for c in range(1, 15):
        run = []
        for r in range(1, MH-1):
            if grid[r][c] == '.' and grid[r][c+1] == '.':
                run.append(r)
            else:
                if len(run) >= 4: out.append((c, run[0], len(run)))
                run = []
        if len(run) >= 4: out.append((c, run[0], len(run)))
    return out

def place_strip(grid, rng, ch, cand, max_strips):
    """Mark corridor-wide strips (2 cells wide = road width, len>=4) as ch.
    cand items: ('h', r, c0, L) horizontal 2-tall corridor at rows r,r+1
                ('v', c, r0, L) vertical 2-wide corridor at cols c,c+1"""
    placed = 0
    cand = cand[:]
    rng.shuffle(cand)
    for (orient, a, b, L) in cand:
        if placed >= max_strips: break
        if orient == 'h':
            cells = [(a, b+k) for k in range(L)] + [(a+1, b+k) for k in range(L)]
        else:
            cells = [(b+k, a) for k in range(L)] + [(b+k, a+1) for k in range(L)]
        # skip if touches spawn cells (left-half check; map is mirrored)
        if any(grid[rr][cc] == 'S' or near_spawn(rr, cc, 1)
               for (rr,cc) in cells if cc <= 15):
            continue
        if any(grid[rr][cc] != '.' for (rr,cc) in cells):
            continue
        for (rr,cc) in cells:
            grid[rr][cc] = ch; grid[rr][30-cc] = ch
        if not connected(grid):
            for (rr,cc) in cells:
                grid[rr][cc] = '.'; grid[rr][30-cc] = '.'
            continue
        placed += 1
    return placed

def place_strips(grid, rng, ch, max_strips):
    cand = ([('h', r, c0, L) for (r, c0, L) in h_runs(grid)] +
            [('v', c, r0, L) for (c, r0, L) in v_runs(grid)])
    return place_strip(grid, rng, ch, cand, max_strips)

def gen(seed):
    grid, rng = base_maze(seed)
    thin_walls(grid, min_run=3)
    if place_water(grid, rng, pools=1) < 1: return None
    place_strips(grid, rng, '-', 2)       # ice strips
    place_strips(grid, rng, 'd', 2)       # dirt strips
    # bricks: recolor some wall cells adjacent to open cells (visual variety)
    walls = [(r,c) for r in range(1,MH-1) for c in range(1,16) if grid[r][c]=='#'
             and any(0<=r+dy<MH and 0<=c+dx<MW and grid[r+dy][c+dx]=='.' for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)))]
    rng.shuffle(walls)
    for (r,c) in walls[:10]:
        grid[r][c] = 'b'; grid[r][30-c] = 'b'
    rows = [''.join(r) for r in grid]
    # final checks
    for r in rows:
        if len(r) != 31 or r != r[::-1]: return None
    for r in range(1, MH-1):
        for c in range(1, MW-1):
            if rows[r][c] in '#b':
                nb = sum(1 for dy,dx in ((1,0),(-1,0),(0,1),(0,-1))
                         if 0<=r+dy<MH and 0<=c+dx<MW and rows[r+dy][c+dx] in '#b')
                if nb == 0: return None        # dot wall!
    if not connected(grid): return None
    n_i = sum(r.count('-') for r in rows)
    n_d = sum(r.count('d') for r in rows)
    n_w = sum(r.count('~') for r in rows)
    if n_i < 8 or n_d < 8 or n_w < 9: return None
    return rows

maps = []
seed = 1
while len(maps) < 5 and seed < 3000:
    rows = gen(seed)
    if rows:
        maps.append((seed, rows))
        print(f"ARENA{len(maps)} seed={seed} OK "
              f"ice={sum(r.count('-') for r in rows)} "
              f"dirt={sum(r.count('d') for r in rows)} "
              f"water={sum(r.count('~') for r in rows)} "
              f"wall={sum(r.count('#')+r.count('b') for r in rows)}")
    seed += 1

assert len(maps) == 5, f"only {len(maps)} maps generated"

out = []
for i,(seed,rows) in enumerate(maps, 1):
    out.append(f"ARENA{i} db \"{rows[0]}\"")
    for r in rows[1:]:
        out.append(f'       db "{r}"')
    out.append("")
open('tools/maze_maps.inc', 'w', encoding='utf-8').write("\n".join(out))
print("written", len(maps))
