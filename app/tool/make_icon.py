"""Erzeugt das App-Icon «T mit Punkt» (Variante 6 der Mockups).

Ausgabe:
- windows/runner/resources/app_icon.ico  (16 … 256 Bildpunkte)
- assets/branding/textly_icon_256.png    (für Dokumentation und Installer)

Aufruf (aus dem Ordner app):  python tool/make_icon.py
Vorlage als Vektor: assets/branding/textly_icon.svg (gleiche Masse, 256er-Raster).
"""
from pathlib import Path

from PIL import Image, ImageDraw

TOP = (0x3E, 0x78, 0xF5)
BOTTOM = (0x1F, 0x4C, 0xC4)
DOT = (0xFF, 0xB5, 0x47)
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


def render(size: int) -> Image.Image:
    """Zeichnet das Icon 8-fach vergrössert und verkleinert sauber auf [size]."""
    s = size * 8
    k = s / 256  # Massstab des 256er-Rasters
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))

    # Grund: abgerundetes Quadrat mit senkrechtem Verlauf
    grad = Image.new('RGBA', (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        t = y / (s - 1)
        gd.line([(0, y), (s, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,))
    # Bei sehr kleinen Grössen weniger Rand, damit das Zeichen gross genug bleibt
    inset = 16 if size >= 32 else 8
    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [inset * k, inset * k, (256 - inset) * k, (256 - inset) * k], radius=52 * k, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # T: Querbalken 66…190 × 64…98, Stamm 110…146 bis 202
    d.polygon([(66 * k, 64 * k), (190 * k, 64 * k), (190 * k, 98 * k), (146 * k, 98 * k), (146 * k, 202 * k),
               (110 * k, 202 * k), (110 * k, 98 * k), (66 * k, 98 * k)], fill=(255, 255, 255, 255))
    # Punkt
    r = 17 * k
    d.ellipse([178 * k - r, 186 * k - r, 178 * k + r, 186 * k + r], fill=DOT + (255,))
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    images = [render(n) for n in SIZES]
    ico = root / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
    images[-1].save(ico, format='ICO', sizes=[(n, n) for n in SIZES], append_images=images[:-1])
    branding = root / 'assets' / 'branding'
    branding.mkdir(parents=True, exist_ok=True)
    images[-1].save(branding / 'textly_icon_256.png')
    print(f'geschrieben: {ico} ({ico.stat().st_size} Bytes), {branding / "textly_icon_256.png"}')


if __name__ == '__main__':
    main()
