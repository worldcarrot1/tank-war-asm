import random
from collections import deque
MW, MH = 31, 20
CW, CH = 10, 6

def gen(seed, braid=0.15, n_ice=8, n_water=6, n_brick=12, force_open_rows=None):
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
            assert 0 <= rr < MH and 0 <= c < MW and 0 <= 30-c < MW, (rr, c, a, b)
            grid[rr][c] = '.'; grid[rr][30-c] = '.'
    for r, c in ((1,1),(1,29),(17,1),(17,29)):
        assert 0 <= r < MH and 0 <= c < MW, (r, c)
        grid[r][c] = 'S'
    if force_open_rows:
        for r in force_open_rows:
            for c in range(1, MW-1):
                if grid[r][c] != 'S': grid[r][c] = '.'
    def open_cells():
        return [(r,c) for r in range(1,MH-1) for c in range(1,16)
                if grid[r][c] == '.' and (r,c) not in ((1,1),(17,1),(1,29),(1,28),(17,29),(17,28))]
    def place(ch, n):
        cand = open_cells()
        rng.shuffle(cand)
        placed = 0
        for (r,c) in cand:
            if placed >= n: break
            if grid[r][c] != '.': continue
            assert 0 <= r < MH and 0 <= c < MW and 0 <= 30-c < MW, (r, c)
            grid[r][c] = ch; grid[r][30-c] = ch
            placed += 1
    place('-', n_ice)
    place('~', n_water)
    walls = [(r,c) for r in range(1,MH-1) for c in range(1,16) if grid[r][c]=='#'
             and any(0<=r+dy<MH and 0<=c+dx<MW and grid[r+dy][c+dx]=='.' for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)))]
    rng.shuffle(walls)
    for (r,c) in walls[:n_brick]:
        assert 0 <= r < MH and 0 <= c < MW and 0 <= 30-c < MW, (r, c)
        grid[r][c] = 'b'; grid[r][30-c] = 'b'
    return [''.join(r) for r in grid]

def validate(rows):
    errs = []
    for i,r in enumerate(rows):
        if len(r)!=31: errs.append(f"w{i}")
        if r != r[::-1]: errs.append(f"sym{i}")
    sp = [(y,x) for y in range(20) for x in range(31) if rows[y][x]=='S']
    if len(sp)!=4: errs.append(f"sp{len(sp)}")
    seen={sp[0]}; dq=deque([sp[0]])
    while dq:
        y,x = dq.popleft()
        for dy,dx in ((1,0),(-1,0),(0,1),(0,-1)):
            ny,nx=y+dy,x+dx
            if 0<=ny<20 and 0<=nx<31 and (ny,nx) not in seen and rows[ny][nx] not in '#b~':
                seen.add((ny,nx)); dq.append((ny,nx))
    total = sum(1 for y in range(20) for x in range(31) if rows[y][x] not in '#b~')
    if len(seen)!=total: errs.append(f"iso{total-len(seen)}")
    for s in sp[1:]:
        if s not in seen: errs.append(f"unreach{s}")
    n_i = sum(r.count('-') for r in rows); n_w = sum(r.count('~') for r in rows)
    return errs, n_i, n_w

maps = []
seed = 1
while len(maps) < 5 and seed < 800:
    rows = gen(seed, force_open_rows=(13,14) if len(maps)==0 else None)
    errs, n_i, n_w = validate(rows)
    if not errs and n_i >= 4 and n_w >= 4:
        maps.append((seed, rows))
        print(f"ARENA{len(maps)} seed={seed} OK")
    seed += 1

out = []
for i,(seed,rows) in enumerate(maps, 1):
    out.append(f"ARENA{i} db \"{rows[0]}\"")
    for r in rows[1:]:
        out.append(f'       db "{r}"')
    out.append("")
open('tools/maze_maps.inc', 'w', encoding='utf-8').write("\n".join(out))
print("written", len(maps))
