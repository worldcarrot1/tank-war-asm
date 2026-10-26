# -*- coding: utf-8 -*-
"""会话45：从 dl/achv45/icons_x（game-icons/icons 官方仓库 zipball，CC-BY 3.0）
挑 28 个图标（24 成就 + 4 品阶徽章）拷入 dl/achv45/picked/，输出 作者->文件 归属表。"""
import os, shutil, sys

SRC = r"D:\tank-war-asm\dl\achv45\icons_x\icons-master"
DST = r"D:\tank-war-asm\dl\achv45\picked"

# (序号, 成就/用途, 文件名不含.svg) —— 序号 = achvDefs 表行序（即图鉴显示序，
# 稀有末位插着 A24 追风者），前缀重排为 01..24 保证 sorted() 后与表序一致。
PICK = [
    ("01", "首炮 Opening Shot",        "gunshot"),
    ("02", "首杀 First Blood",         "skull"),
    ("03", "冰晶护体 Frost Shell",      "snowflake-1"),
    ("04", "疾风起步 Cold Start",       "fire-dash"),
    ("05", "踏水过桥 Water Walker",     "droplet-splash"),
    ("06", "拾荒新手 Collector",        "open-treasure-chest"),
    ("07", "赏金猎人 Bounty Hunter",    "crosshair"),
    ("08", "碎冰守卫 Ice Guard",        "shield-impact"),
    ("09", "布雷能手 Mine Layer",       "land-mine"),
    ("10", "幽影舞者 Ghost Dancer",     "ghost"),
    ("11", "以牙还牙 Payback",          "crossed-swords"),
    ("12", "激光初试 Beam Rookie",      "laser-blast"),
    ("13", "追风者 Wind Chaser",        "whirlwind"),        # A24，表行13
    ("14", "五连绝世 Penta Strike",     "pentacle"),         # A13
    ("15", "完美夺冠 Flawless",         "laurel-crown"),
    ("16", "百战老兵 Veteran",          "sport-medal"),
    ("17", "换位大师 Swap Master",      "body-swapping"),
    ("18", "雷界领主 Mine Lord",        "mine-explosion"),
    ("19", "网友首胜 Net Rookie",       "globe"),
    ("20", "黑色勋章 Black Medal",      "vintage-robot"),
    ("21", "八方屠杀 Eightfold",        "compass"),
    ("22", "屠夫 The Butcher",          "meat-cleaver"),
    ("23", "碾压零封 Blowout",          "circle"),
    ("24", "弹幕大海 Bullet Sea",       "minigun"),
    ("e1", "徽章·普通",                "star"),
    ("e2", "徽章·稀有",                "cut-diamond"),
    ("e3", "徽章·史诗",                "templar-shield"),
    ("e4", "徽章·传奇",                "imperial-crown"),
]

def main():
    if os.path.isdir(DST):
        shutil.rmtree(DST)             # 旧前缀文件必须清空，防 sorted 混入
    os.makedirs(DST, exist_ok=True)
    idx = {}
    for author in os.listdir(SRC):
        d = os.path.join(SRC, author)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            idx.setdefault(f[:-4], author)   # 重名先到先得（记录任一作者）
    authors = set()
    for num, tag, name in PICK:
        a = idx.get(name)
        if not a:
            print("MISSING:", name); sys.exit(1)
        src = os.path.join(SRC, a, name + ".svg")
        dst = os.path.join(DST, "%s_%s.svg" % (num, name))
        shutil.copyfile(src, dst)
        authors.add(a)
        print("%-4s %-24s %-22s author=%s" % (num, name, tag, a))
    print("authors:", ", ".join(sorted(authors)))

main()
