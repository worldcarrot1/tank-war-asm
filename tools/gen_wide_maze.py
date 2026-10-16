# -*- coding: utf-8 -*-
# Maze generator v5 (2026-10-16 user feedback round 3):
#   1) maze is NOT mirrored anymore (user request)
#   2) terrain patches: MORE of them, SMALLER and SCATTERED across the map
#   3) terrain NEVER touches walls: each plaza = open rect with the
#      terrain block inset by a 1-cell walkway ring, so there is always
#      a grey corridor between terrain and wall lines
#   4) still: fine 1-cell corridors, long wall lines, no dot walls,
#      spawns with 2x2 clear start area, full connectivity validation
# Terrain types: ice plaza / dirt plaza / water 3x3 centered in 5x5.
# ASCII only in output .inc.
import random
from collections import deque

MW, MH = 31, 19    # odd height: single wall row at the bottom (row 18)
SCW, SCH = 15, 9   # maze cells: cols 1..29, rows 1..17; row 18 = bottom wall
SPAWNS = [(1,1),(1,29),(17,1),(17,29)]

def rect(r0, c0, w, h):
    return set((r,c) for r in range(r0, r0+h) for c in range(c0, c0+w))

def gen(seed, braid=0.15, n_plazas=8):
    rng = random.Random(seed)
    grid = [['#']*MW for _ in range(MH)]

    # ---- DFS maze over the WHOLE grid (asymmetric) ----
    visited = [[False]*SCW for _ in range(SCH)]
    passages = set()
    stack = [(0,0)]
    visited[0][0] = True
    while stack:
        x, y = stack[-1]
        nbrs = [(x+dx, y+dy) for dx, dy in ((1,0),(-1,0),(0,1),(0,-1))
                if 0 <= x+dx < SCW and 0 <= y+dy < SCH and not visited[y+dy][x+dx]]
        if not nbrs:
            stack.pop(); continue
        nx, ny = rng.choice(nbrs)
        visited[ny][nx] = True
        passages.add((min((x,y),(nx,ny)), max((x,y),(nx,ny))))
        stack.append((nx,ny))
    for x in range(SCW):
        for y in range(SCH):
            if x+1 < SCW and ((x,y),(x+1,y)) not in passages and rng.random() < braid:
                passages.add(((x,y),(x+1,y)))
            if y+1 < SCH and ((x,y),(x,y+1)) not in passages and rng.random() < braid:
                passages.add(((x,y),(x,y+1)))
    for x in range(SCW):
        for y in range(SCH):
            grid[2*y+1][2*x+1] = '.'
    for (a, b) in passages:
        (x1,y1),(x2,y2) = a, b
        if x2 == x1+1:
            r, c = 2*y1+1, 2*x1+2
        else:
            r, c = 2*y1+2, 2*x1+1
        grid[r][c] = '.'

    # ---- spawn 2x2 clear start areas (inward, never breaking the border) ----
    for (sr, sc) in SPAWNS:
        dr = 1 if sr == 1 else -1          # grow into the map
        dc = 1 if sc == 1 else -1
        for ddr in (0, dr):
            for ddc in (0, dc):
                grid[sr+ddr][sc+ddc] = '.'
        grid[sr][sc] = 'S'

    # ---- terrain patches: one per region of a 4x3 grid -> scattered ----
    # each patch = open plaza rect with the terrain block inset by a
    # 1-cell walkway ring (terrain never touches walls)
    REG_C, REG_R = 4, 3
    rw = (MW - 2) // REG_C          # ~7
    rh = (MH - 3) // REG_R          # ~5 usable rows (rows 1..17)
    regions = [(rj, ri) for rj in range(REG_R) for ri in range(REG_C)]
    rng.shuffle(regions)
    targets = ['w', 'i', 'd'] * 4   # 12 patches: 4 water, 4 ice, 4 dirt
    placed = []
    used_t = {'w': 0, 'i': 0, 'd': 0}
    for (rj, ri) in regions:
        if len(placed) >= 10:
            break
        t = targets[len(placed)]
        done = False
        for attempt in range(120):
            if t == 'w':
                w, h = 5, 5
            else:
                w, h = rng.choice([(4,4),(5,4),(4,5)])
            reg_r0 = 1 + rj*rh
            reg_c0 = 1 + ri*rw
            reg_h = min(rh, 17 - reg_r0 + 1)
            if reg_h < h or rw < w:
                # region too small for this size: shrink to 4x4 if possible
                if reg_h >= 4 and rw >= 4 and t != 'w':
                    w, h = 4, 4
                else:
                    break
            r0 = reg_r0 + rng.randrange(0, reg_h - h + 1)
            c0 = reg_c0 + rng.randrange(0, rw - w + 1)
            cells = rect(r0, c0, w, h)
            if any(grid[r][c] == 'S' for (r,c) in cells):
                continue
            if any(abs(r-sr) <= 2 and abs(c-sc) <= 2
                   for (r,c) in cells for (sr,sc) in SPAWNS):
                continue
            exp = rect(r0-1, c0-1, w+2, h+2)
            bad = False
            for (pr0,pc0,pw,ph,pt) in placed:
                if exp & rect(pr0,pc0,pw,ph):
                    bad = True; break
            if bad:
                continue
            for (r,c) in cells:
                grid[r][c] = '.'
            placed.append((r0,c0,w,h,t))
            done = True
            break
        used_t[t] = used_t[t] + (1 if done else 0)
    if used_t['w'] < 2 or used_t['i'] < 2 or used_t['d'] < 2:
        return None

    # ---- terrain: inset by 1-cell walkway ring (never touches walls) ----
    for (r0,c0,w,h,t) in placed:
        if t == 'w':
            cc, rr = (w-3)//2, (h-3)//2
            for r in range(r0+rr, r0+rr+3):
                for c in range(c0+cc, c0+cc+3):
                    grid[r][c] = '~'
        else:
            ch = '-' if t == 'i' else 'd'
            for r in range(r0+1, r0+h-1):
                for c in range(c0+1, c0+w-1):
                    grid[r][c] = ch

    # ---- bricks: recolor some wall cells (visual variety) ----
    walls = [(r,c) for r in range(1,MH-1) for c in range(1,MW-1) if grid[r][c]=='#']
    rng.shuffle(walls)
    for (r,c) in walls[:12]:
        grid[r][c] = 'b'

    # ---- drop isolated wall cells ----
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

    rows = [''.join(r) for r in grid]

    # ---- validation ----
    for r in rows:
        if len(r) != 31: return None
    for r in range(1, MH-1):
        for c in range(1, MW-1):
            if rows[r][c] in '#b':
                nb = sum(1 for dy,dx in ((1,0),(-1,0),(0,1),(0,-1))
                         if rows[r+dy][c+dx] in '#b')
                if nb == 0: return None            # dot wall!
    # terrain must not touch wall cells (aesthetics guarantee)
    for r in range(1, MH-1):
        for c in range(1, MW-1):
            if rows[r][c] in '-d~':
                for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)):
                    if rows[r+dy][c+dx] in '#b':
                        return None
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
    if n_i < 4 or n_d < 4 or n_w < 9: return None
    if n_wall < 160: return None
    return rows

maps = []
seen_maps = set()
seed = 1
N_MAPS = 20   # random map pool: a different validated map every game
while len(maps) < N_MAPS and seed < 60000:
    rows = gen(seed)
    if rows:
        key = tuple(rows)
        if key not in seen_maps:          # no duplicates in the pool
            seen_maps.add(key)
            maps.append((seed, rows))
            print(f"ARENA{len(maps)} seed={seed} "
                  f"ice={sum(r.count('-') for r in rows)} "
                  f"dirt={sum(r.count('d') for r in rows)} "
                  f"water={sum(r.count('~') for r in rows)} "
                  f"wall={sum(r.count('#')+r.count('b') for r in rows)}")
    seed += 1

assert len(maps) == N_MAPS, f"only {len(maps)} maps generated"

out = []
for i,(seed,rows) in enumerate(maps, 1):
    out.append(f"ARENA{i} db \"{rows[0]}\"")
    for r in rows[1:]:
        out.append(f'       db "{r}"')
    out.append("")
open('tools/maze_maps.inc', 'w', encoding='utf-8').write("\n".join(out))
print("written", len(maps))
