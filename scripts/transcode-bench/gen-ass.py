#!/usr/bin/env python3
import random
import sys

HEAD = """[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Dialogue,DejaVu Sans,64,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,4,2,2,120,120,60,1
Style: Karaoke,DejaVu Serif,56,&H00FFFFFF,&H00FF8000,&H00402000,&H00000000,-1,0,0,0,100,100,2,0,1,3,0,8,60,60,40,1
Style: Sign,DejaVu Sans,72,&H00E0F0FF,&H000000FF,&H00203040,&H00000000,-1,0,0,0,100,100,0,0,1,3,0,5,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
WORDS = "the castle walks across the wasteland while sophie keeps the fire burning and howl flies into the storm".split()


def ts(s):
    return f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:05.2f}"


def words(n):
    return " ".join(random.choice(WORDS) for _ in range(n))


def typical():
    random.seed(11)
    lines = [f"Dialogue: 0,{ts(i)},{ts(i + 2.8)},Dialogue,,0,0,0,,{{\\blur0.6}}{words(8).capitalize()}" for i in range(0, 120, 3)]
    for i in range(0, 90, 4):
        syl = "".join(f"{{\\k{random.randint(15, 35)}\\t(0,200,\\fscx110\\fscy110)\\t(200,400,\\fscx100\\fscy100)}}{w} " for w in random.sample(WORDS, 7))
        lines.append(f"Dialogue: 1,{ts(i)},{ts(i + 4)},Karaoke,,0,0,0,,{{\\bord3\\blur1}}{syl}")
    for i in range(0, 120, 5):
        for j in range(3):
            s = i + random.random()
            x, y = random.randint(200, 1700), random.randint(100, 600)
            at = f"\\move({x},{y},{x + random.randint(-80, 80)},{y + random.randint(-40, 40)})" if j == 0 else f"\\pos({x},{y})"
            lines.append(f"Dialogue: 2,{ts(s)},{ts(s + 4)},Sign,,0,0,0,,{{{at}\\frz{random.randint(-15, 15)}\\blur1\\bord3\\fad(200,200)\\1c&H{random.randint(0, 0xFFFFFF):06X}&}}{words(2).upper()}")
    return lines


def extreme():
    random.seed(7)
    lines = [f"Dialogue: 0,{ts(i)},{ts(i + 3)},Dialogue,,0,0,0,,{{\\blur1.5\\fad(150,150)}}{words(9).capitalize()}\\N{{\\i1}}{words(7)}" for i in range(0, 120, 3)]
    for i in range(0, 120, 4):
        syl = "".join(f"{{\\k{random.randint(12, 30)}\\t(0,300,\\fscx120\\fscy120\\blur3)\\t(300,600,\\fscx100\\fscy100\\blur0.6)}}{w} " for w in random.sample(WORDS, 8))
        lines.append(f"Dialogue: 1,{ts(i)},{ts(i + 4)},Karaoke,,0,0,0,,{{\\bord3\\blur2\\3c&H00A05000&}}{syl}")
    for i in range(0, 120, 2):
        for _ in range(15):
            s = i + random.random()
            x1, y1 = random.randint(100, 1820), random.randint(80, 700)
            rot = random.randint(-40, 40)
            lines.append(
                f"Dialogue: 2,{ts(s)},{ts(s + 2.5 + random.random() * 2)},Sign,,0,0,0,,"
                f"{{\\move({x1},{y1},{x1 + random.randint(-300, 300)},{y1 + random.randint(-120, 120)})\\frz{rot}"
                f"\\t(\\frz{rot + random.randint(-30, 30)}\\fscx{random.randint(80, 140)})\\blur{random.uniform(0.8, 4):.1f}"
                f"\\bord{random.randint(2, 6)}\\shad2\\1c&H{random.randint(0, 0xFFFFFF):06X}&\\alpha&H20&}}{words(2).upper()}")
    return lines


out = sys.argv[1] if len(sys.argv) > 1 else "."
for name, gen in (("typical", typical), ("extreme", extreme)):
    with open(f"{out}/{name}.ass", "w") as f:
        f.write(HEAD + "\n".join(gen()) + "\n")
