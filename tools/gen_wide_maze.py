# -*- coding: utf-8 -*-
# Maze generator v4 (2026-10-16 user feedback round 2):
#   "道路" = open space BETWEEN walls. So:
#   1) maze is now FINE-grained: 1-cell corridors (32px vs 21px tank =
#      Tank Trouble ratio) on the full 31x20 grid -> much more complex
#   2) walls form long continuous lines (perfect-maze grid lines),
#      iteratively drop any isolated wall cell
#   3) carve a few open PLAZAS inside the maze; ice / dirt fill a whole
#      plaza (plaza width == road width), water pool 3x3 sits in the
#      middle of a bigger plaza with a walkway around it
#   4) mirrored L/R, spawns at 4 corners with 2x2 clear start area,
#      full connectivity validation
# ASCII only in output .inc (map chars are ASCII).
import random
from collections import deque

MW, MH = 31, 20
CW, CH = 8, 10            # left-half maze cells (incl. axis col ci=7)
SPAWNS = [(1,1),(1,29),(17,1),(17,29)]   # (r,c)

def mirror(grid):
    for r in range(MH):
        for c in range(MW//2):
            grid[r][MW-1-c] = grid[r][c]

def gen(seed, braid=0.15):
    rng = random.Random(seed)
    grid = [['#']*MW for _ in range(MH)]

    # ---- DFS maze on left-half cells (ci 0..7 -> col 2ci+1, cj 0..9) ----
    # x = cell column (0..7), y = cell row (0..9)
    visited = [[False]*CW for _ in range(CH)]
    passages = set()
    stack = [(0,0)]
    visited[0][0] = True
    while stack:
        x, y = stack[-1]
        nbrs = [(x+dx, y+dy) for dx, dy in ((1,0),(-1,0),(0,1),(0,-1))
                if 0 <= x+dx < CW and 0 <= y+dy < CH and not visited[y+dy][x+dx]]
        if not nbrs:
            stack.pop(); continue
        nx, ny = rng.choice(nbrs)
        visited[ny][nx] = True
        passages.add((min((x,y),(nx,ny)), max((x,y),(nx,ny))))
        stack.append((nx,ny))
    # braid: open some extra walls for loops (fewer dead ends -> better flow)
    for x in range(CW):
        for y in range(CH):
            if x+1 < CW and ((x,y),(x+1,y)) not in passages and rng.random() < braid:
                passages.add(((x,y),(x+1,y)))
            if y+1 < CH and ((x,y),(x,y+1)) not in passages and rng.random() < braid:
                passages.add(((x,y),(x,y+1)))
    # carve cells and passages
    for x in range(CW):
        for y in range(CH):
            grid[2*y+1][2*x+1] = '.'
    for (a, b) in passages:
        (x1,y1),(x2,y2) = a, b
        if x2 == x1+1:
            r, c = 2*y1+1, 2*x1+2      # wall col between side-by-side cells
        else:
            r, c = 2*y1+2, 2*x1+1      # wall row between stacked cells
        grid[r][c] = '.'

    # ---- spawn start areas: 2x2 clear at top-left / bottom-left ----
    for (sr, sc) in ((1,1),(17,1)):
        for dr in (0,1):
            for dc in (0,1):
                grid[sr+dr][sc+dc] = '.'
        grid[sr][sc] = 'S'
    mirror(grid)

    # ---- plazas: open rooms inside the maze ("roads") ----
    def room_cells(r0, c0, w, h):
        return set((r,c) for r in range(r0, r0+h) for c in range(c0, c0+w))
    def near_spawn(cells, margin=2):
        for (r,c) in cells:
            for (sr,sc) in SPAWNS:
                if abs(r-sr) <= margin and abs(c-sc) <= margin:
                    return True
        return False
    picked = []
    cand = []
    for (w,h) in ((5,4),(4,4),(6,3),(5,3),(4,3),(6,4)):
        for r0 in range(2, MH-1-h):
            for c0 in range(2, 16-w+1):
                cand.append((r0,c0,w,h))
    rng.shuffle(cand)
    for (r0,c0,w,h) in cand:
        if len(picked) >= 3: break
        cells = room_cells(r0,c0,w,h)
        mcells = set((r, 30-c) for (r,c) in cells)
        if near_spawn(cells) or near_spawn(mcells):
            continue
        ok = True
        for (pr0,pc0,pw,ph) in picked:
            if cells & room_cells(pr0,pc0,pw,ph): ok = False; break
            pm = set((r, 30-c) for (r,c) in room_cells(pr0,pc0,pw,ph))
            if cells & pm: ok = False; break
        if ok:
            picked.append((r0,c0,w,h))
    if len(picked) < 3:
        return None
    # carve plazas
    for (r0,c0,w,h) in picked:
        for r in range(r0, r0+h):
            for c in range(c0, c0+w):
                grid[r][c] = '.'
    # terrain: plaza 0 = ice, plaza 1 = dirt, plaza 2 = water 3x3 in middle
    (r0,c0,w,h) = picked[0]
    for r in range(r0, r0+h):
        for c in range(c0, c0+w):
            grid[r][c] = '-'
    (r0,c0,w,h) = picked[1]
    for r in range(r0, r0+h):
        for c in range(c0, c0+w):
            grid[r][c] = 'd'
    (r0,c0,w,h) = picked[2]
    if w >= 5 and h >= 4:
        for r in range(r0+1, r0+4):
            for c in range(c0+1, c0+4):
                grid[r][c] = '~'
    mirror(grid)

    # ---- bricks: recolor some wall cells (visual variety, no new dots) ----
    walls = [(r,c) for r in range(1,MH-1) for c in range(1,16) if grid[r][c]=='#']
    rng.shuffle(walls)
    for (r,c) in walls[:12]:
        grid[r][c] = 'b'
    mirror(grid)

    # ---- drop isolated wall cells (no wall 4-neighbour) ----
    changed = True
    while changed:
        changed = False
        for r in range(1, MH-1):
            for c in range(1, MW-1):
                if grid[r][c] in '#b':
                    nb = sum(1 for dy,dx in ((1,0),(-1,0),(0,1),(0,-1))
                             if grid[r+dy][c+dx] in '#b')
                    if nb == 0:
                        grid[r][c] = '.'
                        changed = True
        mirror(grid)

    rows = [''.join(r) for r in grid]

    # ---- validation ----
    for r in rows:
        if len(r) != 31 or r != r[::-1]: return None
    for r in range(1, MH-1):
        for c in range(1, MW-1):
            if rows[r][c] in '#b':
                nb = sum(1 for dy,dx in ((1,0),(-1,0),(0,1),(0,-1))
                         if rows[r+dy][c+dx] in '#b')
                if nb == 0: return None            # dot wall!
    # connectivity over non-blocking cells
    seen = {SPAWNS[0]}; dq = deque([SPAWNS[0]])
    while dq:
        y,x = dq.popleft()
        for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)):
            ny,nx = y+dy, x+dx
            if 0<=ny<MH and 0<=nx<MW and (ny,nx) not in seen and rows[ny][nx] not in '#b~':
                seen.add((ny,nx)); dq.append((ny,nx))
    total = sum(1 for y in range(MH) for x in range(MW) if rows[y][x] not in '#b~')
    if len(seen) != total: return None
    for s in SPAWNS[1:]:
        if s not in seen: return None
    n_i = sum(r.count('-') for r in rows)
    n_d = sum(r.count('d') for r in rows)
    n_w = sum(r.count('~') for r in rows)
    n_wall = sum(r.count('#') + r.count('b') for r in rows)
    if n_i < 12 or n_d < 12 or n_w < 9: return None
    if n_wall < 260: return None          # maze must stay complex/dense
    return rows

maps = []
seed = 1
while len(maps) < 5 and seed < 5000:
    rows = gen(seed)
    if rows:
        maps.append((seed, rows))
        print(f"ARENA{len(maps)} seed={seed} "
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
