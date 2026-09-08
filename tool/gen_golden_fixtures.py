#!/usr/bin/env python3
"""Generate the golden OCR fixture corpus for `--headless ocr-golden`.

Why this exists: the acceptance criteria in
`VeneraX_AI_Translation_Phase2_Plan.md` (Phase 6, §3.7) require a reproducible
corpus whose expected text is known. Screenshotting licensed manga would make
the repository unshippable, so every page here is **synthesised from scratch**
with system fonts and is released as CC0. The corpus is deterministic: same
input, same bytes.

Usage:  python tool/gen_golden_fixtures.py [--out test/fixtures/golden_ocr]

Coverage matrix (plan §3.7):
  01  Japanese, multi-column vertical text inside bubbles   (>= 6 columns)
  02  Chinese, horizontal, >= 5 lines, punctuation-dense
  03  Korean webtoon, wide panels, horizontal
  04  English SFX: huge display text + small caption lines
  05  Mixed: halftone background + outlined small text
"""

import argparse
import json
import os
import random
from PIL import Image, ImageDraw, ImageFont

FONTS = {
    "ja": ["C:/Windows/Fonts/YuGothB.ttc", "C:/Windows/Fonts/msgothic.ttc"],
    "zh": ["C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"],
    "ko": ["C:/Windows/Fonts/malgun.ttf"],
    "en": ["C:/Windows/Fonts/arialbd.ttf", "C:/Windows/Fonts/arial.ttf"],
}


def font(lang: str, size: int) -> ImageFont.FreeTypeFont:
    for path in FONTS[lang]:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    raise SystemExit(f"no usable font for {lang}; install a CJK font or edit FONTS")


def bubble(draw, x, y, w, h, outline=6):
    """A speech bubble: white fill, thick black rim (what the eraser must keep)."""
    draw.ellipse([x, y, x + w, y + h], fill="white", outline="black", width=outline)


def vertical_columns(draw, lang, lines, right, top, col_w, font_size):
    """Right-to-left vertical writing, the shape manga OCR is judged on."""
    f = font(lang, font_size)
    x = right
    for line in lines:
        y = top
        for ch in line:
            draw.text((x, y), ch, fill="black", font=f)
            y += int(font_size * 1.25)
        x -= col_w
    return x


def halftone(img, density=7, alpha=90):
    d = ImageDraw.Draw(img, "RGBA")
    for y in range(0, img.height, density):
        for x in range(0, img.width, density):
            r = 1 + ((x // density + y // density) % 3)
            d.ellipse([x, y, x + r, y + r], fill=(0, 0, 0, alpha))


def outlined_text(draw, xy, text, f, fill="white", stroke="black", width=3):
    draw.text(xy, text, font=f, fill=fill, stroke_width=width, stroke_fill=stroke)


def page_01_ja_vertical(w=900, h=1250):
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)
    lines = [
        "おまえには何が見えている?",
        "この街はもう終わっているんだ",
        "それでも尚、進むしかない",
        "嘘だと言ってくれればいい",
        "誰かの声が届かない場所へ",
        "俺はここにいると叫べ",
        "風が止んだ瞬間、世界は",
        "確かに動きはじめたのだ",
    ]
    bubble(d, 60, 40, w - 120, 420)
    vertical_columns(d, "ja", lines, w - 110, 90, 88, 40)
    bubble(d, 120, 560, 620, 300)
    f = font("ja", 34)
    d.text((200, 640), "ここから先は無い", fill="black", font=f)
    d.text((200, 700), "ただ風が吹くだけだ", fill="black", font=f)
    return img, {
        "file": "01_ja_vertical.png",
        "lang": "ja",
        "blocks": 6,
        "notes": "8 vertical columns right-to-left inside one bubble + 2 horizontal lines",
    }


def page_02_zh_horizontal(w=900, h=1150):
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)
    bubble(d, 70, 60, w - 140, 460)
    f = font("zh", 38)
    lines = [
        "你真的决定要这么做吗?!",
        "是的——我没有别的选择了。",
        "可是, 万一失败了呢? 那可就全完了!",
        "那就再来一次, 直到成功为止。",
        "……你总是这样, 让人拿你没办法。",
        "走吧, 天亮之前必须赶到城门。",
    ]
    y = 120
    for line in lines:
        d.text((130, y), line, fill="black", font=f)
        y += 62
    bubble(d, 200, 620, 560, 260)
    d.text((260, 700), "喂——等等我啊!", fill="black", font=font("zh", 34))
    d.text((260, 760), "别跑那么快!!", fill="black", font=font("zh", 34))
    return img, {
        "file": "02_zh_horizontal.png",
        "lang": "zh",
        "blocks": 5,
        "notes": "6 punctuation-dense horizontal lines + 2-line bubble",
    }


def page_03_ko_webtoon(w=820, h=1500):
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)
    # Webtoon: stacked panels with a caption bar each.
    panels = [
        ("오늘도 어김없이 출근길이다.", 60),
        ("사람들은 각자 할 말이 많은 듯했다.", 420),
        ("하지만 정작 입은 다물려 있었다.", 780),
        ("나는 이어폰을 다시 꽂았다.", 1140),
    ]
    for text, y in panels:
        d.rectangle([40, y, w - 40, y + 260], outline="black", width=5)
        d.text((90, y + 90), text, fill="black", font=font("ko", 36))
    d.rectangle([40, 350, w - 40, 380], fill="black")
    d.rectangle([40, 710, w - 40, 740], fill="black")
    return img, {
        "file": "03_ko_webtoon.png",
        "lang": "ko",
        "blocks": 4,
        "notes": "4 stacked webtoon panels, horizontal Korean captions",
    }


def page_04_en_sfx(w=900, h=1100):
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)
    outlined_text(d, (110, 150), "BOOM!!!", font("en", 130), fill="yellow", stroke="black", width=6)
    outlined_text(d, (250, 330), "CRASH", font("en", 96), fill="white", stroke="black", width=5)
    bubble(d, 90, 520, w - 180, 300)
    f = font("en", 30)
    for i, line in enumerate(
        [
            "I told you not to touch that lever.",
            "It was clearly labelled. In red.",
            "Well. That is one way to open it.",
        ]
    ):
        d.text((140, 570 + i * 46), line, fill="black", font=f)
    d.text((150, 900), "next chapter: tomorrow", fill="black", font=font("en", 22))
    return img, {
        "file": "04_en_sfx.png",
        "lang": "en",
        "blocks": 4,
        "notes": "large outlined SFX words + 3-line bubble + small footer",
    }


def page_05_mixed_halftone(w=900, h=1150):
    img = Image.new("RGB", (w, h), "white")
    halftone(img, density=8, alpha=70)
    d = ImageDraw.Draw(img)
    bubble(d, 80, 80, w - 160, 380, outline=8)
    f = font("ja", 30)
    for i, line in enumerate(["この網目の向こうに", "何かが立っているような", "気がしたのだ。"]):
        d.text((150, 140 + i * 52), line, fill="black", font=f)
    outlined_text(d, (170, 560), "危険!!", font("ja", 84), fill="white", stroke="black", width=5)
    d.rectangle([120, 760, w - 120, 1000], fill="white", outline="black", width=6)
    d.text((150, 800), "小さな注釈: これは網点の上にある", fill="black", font=font("zh", 26))
    d.text((150, 850), "細い縁取りの中の文字も読めるか?", fill="black", font=font("zh", 26))
    d.text((150, 900), "ここが最も壊れやすい領域である。", fill="black", font=font("ja", 26))
    return img, {
        "file": "05_mixed_halftone.png",
        "lang": "auto",
        "blocks": 4,
        "notes": "halftone background, outlined display text, small mixed ja/zh lines",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="test/fixtures/golden_ocr")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    builders = [
        page_01_ja_vertical,
        page_02_zh_horizontal,
        page_03_ko_webtoon,
        page_04_en_sfx,
        page_05_mixed_halftone,
    ]
    pages = []
    for b in builders:
        img, meta = b()
        path = os.path.join(args.out, meta["file"])
        img.save(path, optimize=True)
        meta["size"] = [img.width, img.height]
        meta["bytes"] = os.path.getsize(path)
        meta["source"] = "self-generated by tool/gen_golden_fixtures.py"
        meta["license"] = "CC0-1.0"
        pages.append(meta)
        print(f"  {meta['file']:26s} {img.width}x{img.height}  {meta['bytes']/1024:7.1f} KB")

    manifest = {
        "generator": "tool/gen_golden_fixtures.py",
        "seed": 0,
        "license": "CC0-1.0",
        "note": (
            "Expected text is recorded from a real batch=1 run and reviewed by a "
            "human; see doc/ocr-baseline.md. Do not edit .expected.txt to make a "
            "test pass (plan §3.10)."
        ),
        "pages": pages,
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    total = sum(p["bytes"] for p in pages)
    print(f"total {total/1024/1024:.2f} MB (budget 8 MB) -> {args.out}")


if __name__ == "__main__":
    random.seed(0)
    main()
