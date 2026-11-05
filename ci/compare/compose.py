#!/usr/bin/env python3
"""Side-by-side screenshots of Clippy 2.2.0, 2.4.0 and the current build.

Used by the "Version comparison" job in .github/workflows/ci.yml. For every
screen and appearance it writes compare-<screen>-<light|dark>.png with three
columns labelled "2.2.0", "2.4.0" and "New", top-aligned, at actual size: one
screenshot pixel is one image pixel, nothing is scaled, so a larger window looks
larger and a padded layout looks padded. All three versions are captured by the
same harness on the same runner, so they share one capture scale (2x on a
Retina runner); the caption on every image says which, and each column label
gives its pixel size. A version that has no such screen gets a "not in this
version" placeholder. It also writes compare-overview.png, the default-size
panel and Settings General rows stacked, also unscaled.

Each version names its files differently, so SCREENS below maps every shared
screen key to the file name each version uses ({a} is "light" or "dark").
A new screen needs one row there and nothing else.

    compose.py --v220 DIR --v240 DIR --new DIR --out DIR
"""

import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

APPEARANCES = ("light", "dark")
COLUMNS = (("2.2.0", "v220"), ("2.4.0", "v240"), ("New", "new"))

# Default panel width in points (AppSettings.defaultPanelWidth); used only to name the capture scale in captions.
DEFAULT_PANEL_WIDTH_PT = 760

# Settings panes: SettingsPaneID.allCases (Sources/Clippy/UI/Settings/SettingsPaneRegistry.swift),
# identical at b8aa9a0, v2.4.0 (f1c1035) and the current branch.
PANES = (
    "general",
    "appearance",
    "capture",
    "preview",
    "pasteStack",
    "snippets",
    "ai",
    "intelligence",
    "semantic",
    "security",
    "data",
    "integrations",
    "automation",
    "scripts",
    "ocr",
    "editor",
    "about",
)


def both(name):
    """2.4.0 and the current harness (PanelHarnessTests) name their files alike."""
    return {"v240": name, "new": name}


# key -> {version: file name stem, or {appearance: stem}}. A missing version means the screen
# does not exist there. 2.2.0 has no UI harness; its stems come from ci/before-2.2.0.
SCREENS = {
    # Each version's panel at its own default size: 2.2.0 640x480, 2.4.0 920x560, New 760x480.
    "panel-default-size": {
        "v220": "before-panel-history-{a}",
        "v240": "50-panel-default-{a}",
        "new": "50-panel-default-{a}",
    },
    # The same 1000x620 window in every version (the harness's standard panel shot), for like-for-like detail.
    "panel-history": {
        "v220": "before-panel-history-{a}",
        "v240": {"light": "01-panel-light", "dark": "04-panel-dark"},
        "new": {"light": "01-panel-light", "dark": "04-panel-dark"},
    },
    "panel-search": {
        "v220": "before-panel-search-{a}",
        "v240": {"light": "02-search-results-light", "dark": "05-search-results-dark"},
        "new": {"light": "02-search-results-light", "dark": "05-search-results-dark"},
    },
    "panel-no-results": {
        "v240": {"light": "03-no-results-light", "dark": "06-no-results-dark"},
        "new": {"light": "03-no-results-light", "dark": "06-no-results-dark"},
    },
    "onboarding": {"v220": "before-onboarding-{a}", **both("08-onboarding-{a}")},
    "editor-clip": {"v220": "before-editor-clip-{a}", **both("30-editor-clip-{a}")},
    "palette": {"v220": "before-palette-{a}", **both("35-palette-{a}")},
    "sheet-category": both("31-sheet-category-{a}"),
    "sheet-smartcollection": both("32-sheet-smartcollection-{a}"),
    "sheet-snippet": both("33-sheet-snippet-{a}"),
    "sheet-aiaction": both("34-sheet-aiaction-{a}"),
    "aiactions-manager": both("36-aiactions-manager-{a}"),
    "pane-scripts": both("20-pane-scripts-{a}"),
    "pane-suggestions": both("20-pane-suggestions-{a}"),
    "pane-snippets": both("20-pane-snippets-{a}"),
    "pane-pastestack": both("20-pane-pastestack-{a}"),
    "pane-assistant": both("20-pane-assistant-{a}"),
    "pane-aiactions": both("20-pane-aiactions-{a}"),
    "pane-onepassword": both("20-pane-onepassword-{a}"),
    "empty-history": both("40-empty-history-{a}"),
    "search-error": both("41-search-error-{a}"),
    "snippets-empty": both("42-snippets-empty-{a}"),
}
for _pane in PANES:
    SCREENS[f"settings-{_pane}"] = {
        "v220": f"before-settings-{_pane}-{{a}}",
        **both(f"10-settings-{_pane}-{{a}}"),
    }

OVERVIEW_ROWS = ("panel-default-size", "settings-general")
BACKGROUND = (128, 128, 128, 255)
INK = (255, 255, 255, 255)
PLACEHOLDER = (96, 96, 96, 255)


def font(size):
    for path in (
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def stem_for(spec, version, appearance):
    entry = spec.get(version)
    if entry is None:
        return None
    stem = entry[appearance] if isinstance(entry, dict) else entry
    return stem.format(a=appearance)


def find(directory, stem):
    """<stem>.png, else the composited <stem>-window.png."""
    for name in (f"{stem}.png", f"{stem}-window.png"):
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            try:
                with Image.open(path) as image:
                    return image.convert("RGBA")
            except OSError as error:
                print(f"unreadable {path}: {error}", file=sys.stderr)
    return None


def centered(draw, box, text, fnt, fill):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=fnt)
    draw.text(
        (
            box[0] + (box[2] - box[0] - (right - left)) / 2 - left,
            box[1] + (box[3] - box[1] - (bottom - top)) / 2 - top,
        ),
        text,
        font=fnt,
        fill=fill,
    )


def compose(images, title, scale_note):
    """images: three PIL images or None, in COLUMNS order. Returns the composed image, unscaled."""
    present = [i for i in images if i is not None]
    cell_w = max(i.width for i in present)
    cell_h = max(i.height for i in present)
    pad, label_h, title_h = 24, 56, 48
    width = len(images) * cell_w + (len(images) + 1) * pad
    height = title_h + label_h + cell_h + 2 * pad
    canvas = Image.new("RGBA", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    draw.text(
        (pad, pad // 2),
        f"{title}  |  actual size, 1 screenshot pixel = 1 image pixel, no scaling{scale_note}",
        font=font(24),
        fill=INK,
    )
    label_font, note_font = font(34), font(26)
    for index, ((label, _), shot) in enumerate(zip(COLUMNS, images)):
        x = pad + index * (cell_w + pad)
        size = "" if shot is None else f"   {shot.width}x{shot.height} px"
        draw.text((x, title_h + 4), label + size, font=label_font, fill=INK)
        top = title_h + label_h
        if shot is None:
            box = (x, top, x + cell_w, top + cell_h)
            draw.rectangle(box, fill=PLACEHOLDER, outline=INK, width=2)
            centered(draw, box, "not in this version", note_font, INK)
        else:
            canvas.alpha_composite(shot, (x, top))
    return canvas


def overview(rows, path):
    """Stacks composed rows, unscaled, left-aligned."""
    sheet = Image.new(
        "RGBA",
        (max(r.width for r in rows), sum(r.height for r in rows)),
        BACKGROUND,
    )
    y = 0
    for row in rows:
        sheet.alpha_composite(row, (0, y))
        y += row.height
    sheet.save(path)
    print(
        f"wrote {os.path.basename(path)} ({sheet.width}x{sheet.height}) from {len(rows)} rows"
    )


def capture_scale(directory):
    """Pixels per point of the captures, from the default-size panel shot of the current build."""
    stem = SCREENS["panel-default-size"]["new"].format(a="light")
    image = find(directory, stem)
    if image is None:
        return None
    return image.width / DEFAULT_PANEL_WIDTH_PT


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    for _, version in COLUMNS:
        parser.add_argument(
            f"--{version}",
            required=True,
            help=f"directory holding the {version} screenshots",
        )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    directories = {version: getattr(args, version) for _, version in COLUMNS}

    scale = capture_scale(directories["new"])
    scale_note = (
        ""
        if scale is None
        else f"  |  captures are {scale:g}x ({'Retina' if scale > 1.5 else 'standard'}), all three columns alike"
    )
    print(f"capture scale: {scale_note.strip(' |') or 'unknown'}")
    composed, report, overview_rows = 0, [], {}
    for key, spec in SCREENS.items():
        for appearance in APPEARANCES:
            images = [
                None
                if stem_for(spec, version, appearance) is None
                else find(directories[version], stem_for(spec, version, appearance))
                for _, version in COLUMNS
            ]
            report.append(
                f"{''.join('x' if i is not None else '-' for i in images)}  {key}-{appearance}"
            )
            if all(i is None for i in images):
                continue
            row = compose(images, f"{key} ({appearance})", scale_note)
            row.save(os.path.join(args.out, f"compare-{key}-{appearance}.png"))
            composed += 1
            if key in OVERVIEW_ROWS:
                overview_rows[(key, appearance)] = row
    print("found in 2.2.0 / 2.4.0 / New (x = found, - = missing)")
    print("\n".join(report))
    print(f"composed {composed} comparison images")

    ordered = [
        overview_rows[(key, appearance)]
        for appearance in APPEARANCES
        for key in OVERVIEW_ROWS
        if (key, appearance) in overview_rows
    ]
    if ordered:
        overview(ordered, os.path.join(args.out, "compare-overview.png"))
    if composed == 0:
        print("no screenshots found in any input directory", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
