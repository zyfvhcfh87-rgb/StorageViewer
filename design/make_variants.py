#!/usr/bin/env python3
"""Build a FigCraft file with three StorageViewer window variants."""

import json
import zipfile
from pathlib import Path


def rgb(hex_color, alpha=1.0):
    h = hex_color.lstrip("#")
    return {
        "r": int(h[0:2], 16) / 255,
        "g": int(h[2:4], 16) / 255,
        "b": int(h[4:6], 16) / 255,
        "a": alpha,
    }


def solid(hex_color, alpha=1.0):
    return {"type": "solid", "color": rgb(hex_color, alpha)}


class Doc:
    def __init__(self):
        self.nodes = {
            "1": {
                "id": 1,
                "name": "Page 1",
                "type": "page",
                "background": rgb("#1c1c1f"),
                "width": 0,
                "height": 0,
                "children": [],
            }
        }
        self.next_id = 2

    def add(self, parent, node):
        node_id = self.next_id
        self.next_id += 1
        node["id"] = node_id
        node["parent"] = parent
        self.nodes[str(node_id)] = node
        self.nodes[str(parent)].setdefault("children", []).append(node_id)
        return node_id

    def frame(self, parent, name, x, y, w, h, fill, radius=0, clip=True, stroke=None):
        node = {
            "name": name,
            "type": "frame",
            "width": w,
            "height": h,
            "fills": [solid(fill)],
            "clip": clip,
        }
        if x or y:
            node["transform"] = [1, 0, 0, 1, x, y]
        if radius:
            node["corners"] = {"radii": [radius, radius, radius, radius], "smoothing": 0.55}
        if stroke:
            node["strokes"] = [solid(stroke)]
            node["stroke"] = {"weight": 1}
        return self.add(parent, node)

    def rect(self, parent, name, x, y, w, h, fill, radius=0):
        node = {
            "name": name,
            "type": "rectangle",
            "width": max(w, 0.5),
            "height": max(h, 0.5),
            "fills": [solid(fill)],
        }
        if x or y:
            node["transform"] = [1, 0, 0, 1, x, y]
        if radius:
            node["corners"] = {"radii": [radius, radius, radius, radius], "smoothing": 0.4}
        return self.add(parent, node)

    def ellipse(self, parent, x, y, d, fill):
        return self.add(
            parent,
            {
                "name": "Dot",
                "type": "ellipse",
                "width": d,
                "height": d,
                "fills": [solid(fill)],
                "transform": [1, 0, 0, 1, x, y],
            },
        )

    def text(self, parent, value, x, y, w, h, size, color, style="Regular", align="left"):
        return self.add(
            parent,
            {
                "name": value[:32] or "Text",
                "type": "text",
                "characters": value,
                "width": w,
                "height": h,
                "align_h": align,
                "align_v": "middle",
                "style": {
                    "font_family": "Inter",
                    "font_style": style,
                    "font_size": size,
                },
                "fills": [solid(color)],
                "transform": [1, 0, 0, 1, x, y],
            },
        )

    def dump(self, path: Path):
        document = {
            "format": "figcraft",
            "version": 1,
            "imageIndex": [],
            "name": "StorageViewer variants",
            "pages": [1],
            "nodes": self.nodes,
            "next_id": self.next_id,
            "styles": [],
            "variables": {"collections": [], "variables": []},
            "current_page": 1,
            "document_colors": [],
            "comments": [],
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("document.json", json.dumps(document, separators=(",", ":")))


def lights(doc, parent, x, y):
    for i, color in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        doc.ellipse(parent, x + i * 16, y, 10, color)


def treemap(doc, parent, x, y, w, h, palette, labels, ink):
    """Five blocks: Applications, Users, System, Library, Other."""
    gap = 3
    app_w = round(w * 0.46)
    rest_x = app_w + gap
    rest_w = w - rest_x
    users_h = round(h * 0.56)
    lower_y = users_h + gap
    lower_h = h - lower_y
    lib_w = round(rest_w * 0.62)
    other_x = rest_x + lib_w + gap
    other_w = w - other_x

    blocks = [
        (0, 0, app_w, h, palette[0], labels[0], "42%"),
        (rest_x, 0, rest_w, users_h, palette[1], labels[1], "28%"),
        (rest_x, lower_y, lib_w, lower_h, palette[2], labels[2], "18%"),
        (other_x, lower_y, other_w, lower_h * 0.58 - 1, palette[3], labels[3], "8%"),
        (other_x, lower_y + lower_h * 0.58 + 2, other_w, lower_h * 0.42 - 2, palette[4], labels[4], "4%"),
    ]
    for bx, by, bw, bh, fill, name, share in blocks:
        doc.rect(parent, name, x + bx, y + by, bw, bh, fill, radius=2)
        if bw > 70 and bh > 28:
            doc.text(parent, name, x + bx + 10, y + by + 8, bw - 16, 16, 12, ink, "Medium")
            doc.text(parent, share, x + bx + 10, y + by + 24, bw - 16, 14, 11, ink)


def row(doc, parent, y, name, size, folder, root, dot, text, muted, selected=False, accent=None, indent=0):
    if selected and accent:
        doc.rect(parent, "Selection", 0, y, 340, 28, accent)
        doc.rect(parent, "Selection bar", 0, y, 2, 28, "#8eb4ff" if accent.startswith("#2") or accent.startswith("#1") else accent)
    doc.ellipse(parent, 14 + indent, y + 10, 7, dot)
    doc.text(parent, name, 28 + indent, y + 4, 150 - indent, 20, 12, text, "Medium" if selected else "Regular")
    doc.text(parent, size, 170, y + 4, 70, 20, 12, text, "Regular", "right")
    doc.text(parent, folder, 244, y + 4, 44, 20, 12, muted, "Regular", "right")
    doc.text(parent, root, 290, y + 4, 40, 20, 12, muted, "Regular", "right")


def split_window(doc, origin_x, title, blurb, theme):
    t = theme
    label = doc.text(1, title, origin_x, 36, 700, 32, 22, "#f4f4f5", "Medium")
    doc.text(1, blurb, origin_x, 72, 980, 22, 13, "#a1a1aa", "Regular")
    window = doc.frame(1, title, origin_x, 112, 1080, 700, t["canvas"], radius=12, stroke=t["line"])

    bar = doc.frame(window, "Top bar", 0, 0, 1080, 52, t["bar"])
    lights(doc, bar, 16, 21)
    doc.text(bar, "StorageViewer", 78, 16, 140, 22, 13, t["text"], "Medium")
    doc.rect(bar, "Divider", 228, 18, 1, 16, t["line"])
    doc.text(bar, "Macintosh HD", 242, 16, 130, 22, 13, t["text"], "Regular")
    doc.text(bar, "/  Applications", 372, 16, 160, 22, 12, t["muted"], "Regular")
    doc.text(bar, "128,402 files   ·   486 GB", 620, 16, 250, 22, 12, t["muted"], "Regular", "right")
    scan = doc.frame(bar, "Scan", 888, 13, 72, 26, t["bar"], radius=6, stroke=t["line"])
    doc.text(scan, "Scan", 0, 3, 72, 20, 12, t["text"], "Medium", "center")
    choose = doc.frame(bar, "Choose", 968, 13, 92, 26, t["accent"], radius=6)
    doc.text(choose, "Choose", 0, 3, 92, 20, 12, t["on_accent"], "Medium", "center")

    rail = doc.frame(window, "Volumes", 0, 52, 64, 612, t["rail"])
    for i, (mark, on) in enumerate((("HD", True), ("Home", False), ("Ext", False))):
        chip = t["accent"] if on else t["chip"]
        doc.frame(rail, mark, 16, 18 + i * 48, 32, 32, chip, radius=8)
        doc.text(rail, mark[:1], 16, 24 + i * 48, 32, 18, 12, t["on_accent"] if on else t["muted"], "Medium", "center")

    body = doc.frame(window, "Map", 64, 52, 676, 612, t["map"])
    treemap(doc, body, 8, 8, 660, 596, t["blocks"], t["block_names"], t["block_ink"])

    panel = doc.frame(window, "List", 740, 52, 340, 612, t["panel"])
    doc.text(panel, "Contents", 14, 10, 120, 18, 11, t["muted"], "Medium")
    doc.text(panel, "12", 280, 10, 46, 18, 11, t["muted"], "Regular", "right")
    doc.rect(panel, "Rule", 0, 34, 340, 1, t["line"])
    doc.text(panel, "Name", 14, 40, 80, 16, 11, t["muted"], "Regular")
    doc.text(panel, "Size", 176, 40, 64, 16, 11, t["muted"], "Regular", "right")
    doc.text(panel, "Folder", 244, 40, 44, 16, 11, t["muted"], "Regular", "right")
    doc.text(panel, "Root", 292, 40, 36, 16, 11, t["muted"], "Regular", "right")
    doc.rect(panel, "Rule 2", 0, 60, 340, 1, t["line"])

    items = [
        ("Applications", "204 GB", "42%", "42%", t["blocks"][0], True, 0),
        ("Utilities", "18 GB", "9%", "4%", t["blocks"][2], False, 16),
        ("Safari.app", "1.2 GB", "0.6%", "0.2%", t["blocks"][3], False, 16),
        ("Users", "136 GB", "28%", "28%", t["blocks"][1], False, 0),
        ("System", "87 GB", "18%", "18%", t["blocks"][2], False, 0),
        ("Library", "39 GB", "8%", "8%", t["blocks"][3], False, 0),
    ]
    for i, (name, size, folder, root, dot, selected, indent) in enumerate(items):
        row(doc, panel, 68 + i * 28, name, size, folder, root, dot, t["text"], t["muted"], selected, t["select"], indent)

    foot = doc.frame(window, "Footer", 0, 664, 1080, 36, t["bar"])
    doc.rect(foot, "Rule", 0, 0, 1080, 1, t["line"])
    doc.text(foot, "Applications  ·  204 GB  ·  folder", 16, 8, 360, 20, 11, t["muted"], "Regular")
    legend = ["apps", "users", "system", "library", "other"]
    lx = 430
    for name, color in zip(legend, t["blocks"]):
        doc.rect(foot, name, lx, 14, 8, 8, color, radius=2)
        doc.text(foot, name, lx + 12, 8, 52, 20, 10, t["muted"], "Regular")
        lx += 68
    filt = doc.frame(foot, "Filter", 860, 6, 200, 24, t["canvas"], radius=5, stroke=t["accent"])
    doc.text(filt, "Filter    app", 8, 2, 180, 20, 12, t["text"], "Regular")
    return window


def atlas(doc, origin_x):
    doc.text(1, "Atlas", origin_x, 36, 400, 32, 22, "#f4f4f5", "Medium")
    doc.text(1, "The map is the window. A floating card carries the list, so the disk stays the whole picture.", origin_x, 72, 980, 22, 13, "#a1a1aa", "Regular")
    window = doc.frame(1, "Atlas", origin_x, 112, 1080, 700, "#0e1218", radius=12, stroke="#2a3142")
    treemap(
        doc,
        window,
        16,
        16,
        1048,
        668,
        ["#8faf86", "#d2b07a", "#7f9eb8", "#c49284", "#6d6a78"],
        ["Applications", "Users", "System", "Library", "Other"],
        "#14181f",
    )
    # Soft veil so the floating cards read on top of the map.
    card = doc.frame(window, "Summary", 28, 28, 300, 108, "#161c28", radius=14)
    doc.text(card, "Macintosh HD", 18, 14, 250, 18, 12, "#9aa3b5", "Medium")
    doc.text(card, "486 GB", 18, 36, 250, 36, 32, "#f3efe4", "Medium")
    doc.text(card, "128,402 files   ·   14 unreadable", 18, 76, 260, 18, 12, "#9aa3b5", "Regular")

    tray = doc.frame(window, "Largest", 28, 468, 420, 204, "#161c28", radius=14)
    doc.text(tray, "Largest", 16, 12, 200, 18, 12, "#9aa3b5", "Medium")
    entries = [
        ("Applications", "204 GB", "42%", "#8faf86"),
        ("Users", "136 GB", "28%", "#d2b07a"),
        ("System", "87 GB", "18%", "#7f9eb8"),
        ("Library", "39 GB", "8%", "#c49284"),
    ]
    for i, (name, size, share, color) in enumerate(entries):
        y = 40 + i * 38
        doc.ellipse(tray, 16, y + 8, 8, color)
        doc.text(tray, name, 32, y + 2, 180, 22, 13, "#eef1f6", "Medium")
        doc.text(tray, size, 220, y + 2, 90, 22, 13, "#eef1f6", "Regular", "right")
        doc.text(tray, share, 320, y + 2, 70, 22, 13, "#9aa3b5", "Regular", "right")
        doc.rect(tray, "meter", 32, y + 26, 360 * float(share.strip("%")) / 100, 3, color, radius=2)

    doc.text(window, "StorageViewer", 820, 32, 220, 20, 13, "#f4f4f5", "Medium", "right")
    return window


def main():
    doc = Doc()
    ink = {
        "canvas": "#101012",
        "bar": "#18181b",
        "rail": "#141416",
        "panel": "#16161a",
        "map": "#0c0c0e",
        "line": "#2c2c32",
        "text": "#f4f4f5",
        "muted": "#9a9aa3",
        "accent": "#8eb4ff",
        "on_accent": "#101218",
        "chip": "#2a2a30",
        "select": "#243049",
        "blocks": ["#8eae86", "#d4b483", "#8aa4c4", "#c49a86", "#6a6670"],
        "block_names": ["Applications", "Users", "System", "Library", "Other"],
        "block_ink": "#16140f",
    }
    day = {
        "canvas": "#f3efe8",
        "bar": "#fbf8f3",
        "rail": "#efeae2",
        "panel": "#fffdf8",
        "map": "#e7e0d4",
        "line": "#e0d8cc",
        "text": "#1e1b16",
        "muted": "#7d766c",
        "accent": "#0e6b66",
        "on_accent": "#f6f3ee",
        "chip": "#e4ddd2",
        "select": "#d9efe9",
        "blocks": ["#6e8f6a", "#c4965a", "#6d88a8", "#b5836a", "#8a8178"],
        "block_names": ["Applications", "Users", "System", "Library", "Other"],
        "block_ink": "#1c1914",
    }

    split_window(
        doc,
        80,
        "Ink",
        "The current dark tool, with a quieter type scale, a volume rail, and one cool accent.",
        ink,
    )
    split_window(
        doc,
        1280,
        "Daylight",
        "Same layout, drawn like a paper instrument. Warm ground, ink type, a deep teal accent.",
        day,
    )
    atlas(doc, 2480)

    out = Path(__file__).resolve().parent / "storageviewer-variants.figcraft"
    doc.dump(out)
    print(out, "nodes", doc.next_id - 1)


if __name__ == "__main__":
    main()
