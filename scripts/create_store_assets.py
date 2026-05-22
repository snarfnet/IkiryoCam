from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "IkiryoCam" / "Assets.xcassets"
STORE_ROOT = ROOT / "StoreAssets"

APP_ICON = ASSET_ROOT / "AppIcon.appiconset" / "icon_1024.png"
HALLWAY = ASSET_ROOT / "IkiryoHallway.imageset" / "ikiryo_hallway.png"
GHOST_FACE = ASSET_ROOT / "GhostFace.imageset" / "ghost_face.png"
GHOST_HAND = ASSET_ROOT / "GhostHand.imageset" / "ghost_hand.png"
GHOST_MALE = ASSET_ROOT / "GhostMale.imageset" / "ghost_male.png"

FONT_SERIF = Path("C:/Windows/Fonts/yumin.ttf")
FONT_SERIF_BOLD = Path("C:/Windows/Fonts/yumindb.ttf")
FONT_SANS = Path("C:/Windows/Fonts/YuGothM.ttc")
FONT_SANS_BOLD = Path("C:/Windows/Fonts/YuGothB.ttc")

SIZES = {
    "iphone_67": (1290, 2796),
    "iphone_65": (1242, 2688),
    "iphone_55": (1242, 2208),
    "ipad_129": (2048, 2732),
}


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    image = image.convert("RGB")
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = max(dst_w / src_w, dst_h / src_h)
    new_size = (math.ceil(src_w * scale), math.ceil(src_h * scale))
    resized = image.resize(new_size, Image.Resampling.LANCZOS)
    left = (new_size[0] - dst_w) // 2
    top = (new_size[1] - dst_h) // 2
    return resized.crop((left, top, left + dst_w, top + dst_h))


def contain(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    image = image.convert("RGBA")
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = min(dst_w / src_w, dst_h / src_h)
    new_size = (max(1, int(src_w * scale)), max(1, int(src_h * scale)))
    return image.resize(new_size, Image.Resampling.LANCZOS)


def fit_text(draw: ImageDraw.ImageDraw, text: str, path: Path, max_width: int, start: int, min_size: int) -> ImageFont.FreeTypeFont:
    size = start
    while size >= min_size:
        candidate = font(path, size)
        if draw.textbbox((0, 0), text, font=candidate)[2] <= max_width:
            return candidate
        size -= 2
    return font(path, min_size)


def draw_center(draw: ImageDraw.ImageDraw, y: int, text: str, fnt: ImageFont.FreeTypeFont, fill: tuple[int, int, int, int], width: int) -> None:
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((width - (box[2] - box[0])) // 2, y), text, font=fnt, fill=fill)


def red_glow(size: tuple[int, int], center: tuple[int, int], radius: int) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for i in range(7, 0, -1):
        alpha = int(48 / i)
        r = int(radius * i / 3)
        draw.ellipse((center[0] - r, center[1] - r, center[0] + r, center[1] + r), fill=(150, 8, 6, alpha))
    return layer.filter(ImageFilter.GaussianBlur(radius // 4))


def haunted_background(size: tuple[int, int]) -> Image.Image:
    base = cover(Image.open(HALLWAY), size).convert("RGBA")
    base = ImageEnhance.Brightness(base).enhance(0.34)
    base = ImageEnhance.Contrast(base).enhance(1.45)
    mist = Image.new("RGBA", size, (0, 0, 0, 80))
    base.alpha_composite(mist)
    w, h = size
    base.alpha_composite(red_glow(size, (w // 2, int(h * 0.9)), int(min(w, h) * 0.13)))
    vignette = Image.new("L", size, 0)
    d = ImageDraw.Draw(vignette)
    d.ellipse((-w * 0.12, -h * 0.02, w * 1.12, h * 1.04), fill=210)
    vignette = ImageEnhance.Contrast(vignette.filter(ImageFilter.GaussianBlur(int(w * 0.08)))).enhance(1.8)
    shade = Image.new("RGBA", size, (0, 0, 0, 210))
    base = Image.composite(base, shade, vignette)
    noise = Image.effect_noise(size, 16).convert("L")
    noise = ImageEnhance.Contrast(noise).enhance(1.8)
    base.alpha_composite(Image.merge("RGBA", (noise, noise, noise, noise.point(lambda p: 18 if p > 145 else 0))))
    return base


def draw_phone(canvas: Image.Image, rect: tuple[int, int, int, int], mode: str) -> None:
    x, y, w, h = rect
    phone = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pd = ImageDraw.Draw(phone)
    radius = max(44, w // 12)
    pd.rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=(5, 6, 8, 255), outline=(78, 82, 88, 255), width=max(4, w // 90))
    inset = max(22, w // 22)
    screen = (inset, inset * 2, w - inset, h - inset * 2)
    pd.rounded_rectangle(screen, radius=radius // 2, fill=(3, 5, 7, 255), outline=(55, 58, 60, 255), width=2)
    notch_w, notch_h = w // 4, max(24, h // 48)
    pd.rounded_rectangle(((w - notch_w) // 2, inset, (w + notch_w) // 2, inset + notch_h), radius=notch_h // 2, fill=(0, 0, 0, 255))

    sx, sy, ex, ey = screen
    sw, sh = ex - sx, ey - sy
    content = cover(Image.open(HALLWAY), (sw, sh)).convert("RGBA")
    content = ImageEnhance.Brightness(content).enhance(0.28)
    content = ImageEnhance.Contrast(content).enhance(1.3)
    cd = ImageDraw.Draw(content)

    title = font(FONT_SERIF_BOLD, max(26, sw // 12))
    small = font(FONT_SANS, max(14, sw // 34))
    label = font(FONT_SANS_BOLD, max(18, sw // 25))
    cd.text((sw * 0.08, sh * 0.055), "生霊カメラ", font=title, fill=(226, 226, 222, 245))

    preview = (int(sw * 0.07), int(sh * 0.17), int(sw * 0.93), int(sh * 0.56))
    cd.rectangle(preview, outline=(190, 190, 184, 170), width=2)
    scene = cover(Image.open(HALLWAY), (preview[2] - preview[0], preview[3] - preview[1])).convert("RGBA")
    scene = ImageEnhance.Brightness(scene).enhance(0.45)

    if mode in {"female", "result"}:
        face = contain(Image.open(GHOST_FACE), (int(sw * 0.48), int(sh * 0.28)))
        face.putalpha(face.getchannel("A").point(lambda p: min(210, int(p * 0.62))))
        scene.alpha_composite(face, (int(scene.width * 0.06), int(scene.height * 0.06)))
    if mode in {"male", "result"}:
        male = contain(Image.open(GHOST_MALE), (int(sw * 0.52), int(sh * 0.34)))
        male.putalpha(male.getchannel("A").point(lambda p: min(190, int(p * 0.56))))
        scene.alpha_composite(male, (int(scene.width * 0.44), int(scene.height * 0.1)))
    if mode == "hand":
        hand = contain(Image.open(GHOST_HAND), (int(sw * 0.72), int(sh * 0.42)))
        hand.putalpha(hand.getchannel("A").point(lambda p: min(230, int(p * 0.78))))
        scene.alpha_composite(hand, (int(scene.width * 0.16), int(scene.height * 0.03)))
    if mode == "edit":
        for i in range(5):
            face = contain(Image.open(GHOST_FACE), (int(sw * (0.28 + i * 0.035)), int(sh * 0.21)))
            face.putalpha(face.getchannel("A").point(lambda p, i=i: min(115 - i * 10, int(p * 0.42))))
            scene.alpha_composite(face, (int(scene.width * (0.06 + i * 0.12)), int(scene.height * (0.1 + i * 0.01))))

    content.alpha_composite(scene, (preview[0], preview[1]))

    if mode == "home":
        cd.rounded_rectangle((sw * 0.10, sh * 0.64, sw * 0.90, sh * 0.73), radius=12, fill=(88, 0, 0, 185), outline=(216, 20, 14, 210), width=2)
        cd.text((sw * 0.20, sh * 0.665), "動画をインポート", font=label, fill=(246, 238, 232, 255))
        cd.text((sw * 0.26, sh * 0.76), "動画に潜む気配を映し出す", font=small, fill=(202, 202, 198, 205))
    elif mode in {"female", "male", "hand", "edit"}:
        labels = ["女の気配", "男の気配", "手の気配", "透明感"]
        for i, text in enumerate(labels):
            yy = int(sh * (0.62 + i * 0.075))
            cd.text((sw * 0.11, yy), text, font=small, fill=(225, 225, 220, 235))
            cd.line((sw * 0.39, yy + 11, sw * 0.82, yy + 11), fill=(118, 20, 18, 230), width=3)
            knob_x = int(sw * (0.72 - i * 0.035))
            cd.ellipse((knob_x - 8, yy + 3, knob_x + 8, yy + 19), fill=(224, 222, 216, 255))
        cd.text((sw * 0.12, sh * 0.91), "エフェクト", font=small, fill=(238, 74, 60, 245))
    else:
        cd.rounded_rectangle((sw * 0.11, sh * 0.64, sw * 0.89, sh * 0.72), radius=10, fill=(80, 0, 0, 185), outline=(210, 18, 12, 220), width=2)
        cd.text((sw * 0.35, sh * 0.662), "保存する", font=label, fill=(248, 244, 238, 255))
        cd.rounded_rectangle((sw * 0.11, sh * 0.76, sw * 0.89, sh * 0.83), radius=8, fill=(12, 13, 16, 205), outline=(112, 114, 116, 145), width=2)
        cd.text((sw * 0.35, sh * 0.778), "シェアする", font=label, fill=(230, 230, 226, 235))

    phone.alpha_composite(content, (sx, sy))
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((0, 0, w - 1, h - 1), radius=radius, fill=(0, 0, 0, 180))
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(14, w // 30)))
    canvas.alpha_composite(shadow, (x, y + max(12, h // 60)))
    canvas.alpha_composite(phone, (x, y))


def make_screenshot(size: tuple[int, int], index: int, title: str, subtitle: str, mode: str) -> Image.Image:
    w, h = size
    canvas = haunted_background(size)
    draw = ImageDraw.Draw(canvas)
    title_font = fit_text(draw, title, FONT_SERIF_BOLD, int(w * 0.86), int(w * 0.09), int(w * 0.048))
    sub_font = fit_text(draw, subtitle, FONT_SANS, int(w * 0.82), int(w * 0.034), int(w * 0.023))
    draw_center(draw, int(h * 0.055), title, title_font, (242, 240, 235, 246), w)
    draw_center(draw, int(h * 0.055) + title_font.size + int(h * 0.015), subtitle, sub_font, (213, 213, 208, 220), w)
    red = "気配"
    if red in subtitle:
        box = draw.textbbox((0, 0), subtitle, font=sub_font)
        prefix = subtitle.split(red)[0]
        px = draw.textbbox((0, 0), prefix, font=sub_font)[2]
        rx = (w - (box[2] - box[0])) // 2 + px
        ry = int(h * 0.055) + title_font.size + int(h * 0.015)
        draw.text((rx, ry), red, font=sub_font, fill=(220, 22, 14, 245))

    phone_h = int(h * (0.71 if h > 2400 else 0.76))
    phone_w = int(phone_h * 0.49)
    if phone_w > int(w * 0.64):
        phone_w = int(w * 0.64)
        phone_h = int(phone_w / 0.49)
    phone_x = (w - phone_w) // 2
    phone_y = int(h * 0.22 if h > 2400 else h * 0.18)
    draw_phone(canvas, (phone_x, phone_y, phone_w, phone_h), mode)

    caption = ["読み込む", "分ける", "呼び出す", "揺らす", "残す"][index - 1]
    cap_font = font(FONT_SERIF_BOLD, int(w * 0.047))
    draw_center(draw, int(h * 0.925), caption, cap_font, (194, 18, 13, 230), w)
    return canvas.convert("RGB")


def prepare_icon(source: Path) -> None:
    STORE_ROOT.mkdir(exist_ok=True)
    (STORE_ROOT / "app-icon").mkdir(parents=True, exist_ok=True)
    icon = cover(Image.open(source), (1024, 1024)).convert("RGB")
    icon.save(APP_ICON, "PNG", optimize=True)
    icon.save(STORE_ROOT / "app-icon" / "icon_1024.png", "PNG", optimize=True)


def prepare_screenshots() -> None:
    shots = [
        ("生霊カメラ", "動画に潜む気配を映し出す", "home"),
        ("女の気配・男の気配", "顔と身体の気配を分けて調整", "female"),
        ("手の気配", "大きく人間ぽい手を呼び出す", "hand"),
        ("ゆらめく残像", "透明感と揺れで固定感を消す", "edit"),
        ("保存とシェア", "完成した恐怖をすぐに残す", "result"),
    ]
    for folder, size in SIZES.items():
        out_dir = STORE_ROOT / "screenshots" / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        for index, (title, subtitle, mode) in enumerate(shots, start=1):
            image = make_screenshot(size, index, title, subtitle, mode)
            image.save(out_dir / f"{index:02d}_{mode}.png", "PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icon-source", type=Path, required=True)
    args = parser.parse_args()
    prepare_icon(args.icon_source)
    prepare_screenshots()
    print(f"App icon: {APP_ICON}")
    print(f"Store assets: {STORE_ROOT}")


if __name__ == "__main__":
    main()
