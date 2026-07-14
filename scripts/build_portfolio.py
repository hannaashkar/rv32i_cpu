#!/usr/bin/env python3
"""Build the recruiter-facing rv32i_cpu portfolio PDF from one evidence file.

The document deliberately separates simulation, implementation, and silicon
evidence.  Edit portfolio/evidence.json, not this renderer, when measurements
change.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Iterable

try:
    from reportlab.lib.colors import Color, HexColor, white
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.pdfbase.pdfmetrics import stringWidth
    from reportlab.pdfgen import canvas
except ImportError as exc:  # pragma: no cover - environment guidance
    raise SystemExit(
        "ReportLab is required. Install it with: python -m pip install reportlab"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
PAGE_W, PAGE_H = A4
MARGIN = 15 * mm

NAVY = HexColor("#0B1220")
PANEL = HexColor("#121C2D")
PANEL_2 = HexColor("#18253A")
INK = HexColor("#172033")
MUTED = HexColor("#65728A")
LIGHT = HexColor("#F4F7FB")
LINE = HexColor("#DDE4EF")
CYAN = HexColor("#18B8C8")
BLUE = HexColor("#3178F6")
LIME = HexColor("#80C342")
ORANGE = HexColor("#F59E42")
VIOLET = HexColor("#8B6FF7")
RED = HexColor("#D9515D")
SLATE = HexColor("#7B879B")

TONES = {
    "cyan": CYAN,
    "blue": BLUE,
    "lime": LIME,
    "orange": ORANGE,
    "violet": VIOLET,
    "red": RED,
    "slate": SLATE,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--evidence",
        type=Path,
        default=ROOT / "portfolio" / "evidence.json",
        help="portfolio evidence JSON",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="output PDF (defaults to document.output_path in the evidence file)",
    )
    return parser.parse_args()


def walk_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from walk_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_strings(child)


def load_evidence(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "document",
        "identity",
        "production",
        "boundaries",
        "headline_metrics",
        "architecture",
        "cpu_performance",
        "verification",
        "npu",
        "fpga",
        "decisions",
        "evidence",
    }
    missing = sorted(required - data.keys())
    if missing:
        raise SystemExit(f"Evidence file is missing keys: {', '.join(missing)}")
    if data["document"].get("page_count") != 8:
        raise SystemExit("This renderer requires document.page_count = 8")
    if data["boundaries"].get("physical_25mhz") is not False:
        raise SystemExit("Refusing to render: 25 MHz must remain build-only until flashed")
    if data["boundaries"].get("physical_mnist") is not False:
        raise SystemExit("Refusing to render an unsupported physical MNIST claim")
    if data["boundaries"].get("linux_capable") is not False:
        raise SystemExit("Refusing to render an unsupported Linux claim")
    # The PDF skill requires safe, predictable glyphs. Keep the evidence ASCII.
    non_ascii = sorted({ch for text in walk_strings(data) for ch in text if ord(ch) > 127})
    if non_ascii:
        codes = ", ".join(f"U+{ord(ch):04X}" for ch in non_ascii)
        raise SystemExit(f"Evidence contains non-ASCII glyphs: {codes}")
    return data


def wrap(text: str, font: str, size: float, width: float) -> list[str]:
    lines: list[str] = []
    for paragraph in text.splitlines() or [""]:
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        current = words[0]
        for word in words[1:]:
            trial = f"{current} {word}"
            if stringWidth(trial, font, size) <= width:
                current = trial
            else:
                lines.append(current)
                current = word
        lines.append(current)
    return lines


def mhz_label(value: int | float) -> str:
    """Format a measured clock without duplicating evidence in the renderer."""
    return f"{value:g} MHz"


def text_block(
    c: canvas.Canvas,
    text: str,
    x: float,
    y: float,
    width: float,
    *,
    font: str = "Helvetica",
    size: float = 9,
    color: Color = INK,
    leading: float | None = None,
    max_lines: int | None = None,
) -> float:
    leading = leading or size * 1.35
    lines = wrap(text, font, size, width)
    if max_lines is not None and len(lines) > max_lines:
        lines = lines[:max_lines]
        tail = lines[-1]
        while tail and stringWidth(tail + "...", font, size) > width:
            tail = tail[:-1]
        lines[-1] = tail.rstrip() + "..."
    c.setFont(font, size)
    c.setFillColor(color)
    for line in lines:
        c.drawString(x, y, line)
        y -= leading
    return y


def page_base(c: canvas.Canvas, page: int, title: str, kicker: str = "") -> float:
    c.setFillColor(white)
    c.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
    c.setFillColor(NAVY)
    c.rect(0, PAGE_H - 32 * mm, PAGE_W, 32 * mm, fill=1, stroke=0)
    c.setFillColor(CYAN)
    c.rect(MARGIN, PAGE_H - 12 * mm, 18 * mm, 1.3 * mm, fill=1, stroke=0)
    if kicker:
        c.setFillColor(CYAN)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawString(MARGIN + 22 * mm, PAGE_H - 13 * mm, kicker.upper())
    c.setFillColor(white)
    title_size = 20.0
    title_width = PAGE_W - 2 * MARGIN
    while title_size > 14 and stringWidth(title, "Helvetica-Bold", title_size) > title_width:
        title_size -= 0.5
    c.setFont("Helvetica-Bold", title_size)
    c.drawString(MARGIN, PAGE_H - 25 * mm, title)
    return PAGE_H - 40 * mm


def footer(c: canvas.Canvas, page: int, total: int, template: str) -> None:
    c.setStrokeColor(LINE)
    c.setLineWidth(0.4)
    c.line(MARGIN, 10 * mm, PAGE_W - MARGIN, 10 * mm)
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 7)
    c.drawString(MARGIN, 6.2 * mm, template.format(page=page, total=total))


def end_page(c: canvas.Canvas, page: int, data: dict[str, Any]) -> None:
    footer(c, page, data["document"]["page_count"], data["document"]["footer_template"])
    c.showPage()


def rounded_card(
    c: canvas.Canvas,
    x: float,
    y: float,
    w: float,
    h: float,
    *,
    fill: Color = LIGHT,
    stroke: Color = LINE,
    radius: float = 3 * mm,
) -> None:
    c.setFillColor(fill)
    c.setStrokeColor(stroke)
    c.setLineWidth(0.6)
    c.roundRect(x, y, w, h, radius, fill=1, stroke=1)


def pill(c: canvas.Canvas, text: str, x: float, y: float, color: Color) -> float:
    size = 6.8
    width = stringWidth(text.upper(), "Helvetica-Bold", size) + 6 * mm
    c.setFillColor(color)
    c.roundRect(x, y - 3.2 * mm, width, 5.2 * mm, 2.6 * mm, fill=1, stroke=0)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", size)
    c.drawCentredString(x + width / 2, y - 1.45 * mm, text.upper())
    return width


def section_label(c: canvas.Canvas, text: str, x: float, y: float, color: Color = BLUE) -> None:
    c.setFillColor(color)
    c.rect(x, y - 1.2 * mm, 8 * mm, 1.1 * mm, fill=1, stroke=0)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(x + 11 * mm, y - 2.2 * mm, text)


def metric_card(c: canvas.Canvas, item: dict[str, Any], x: float, y: float, w: float, h: float) -> None:
    tone = TONES[item["tone"]]
    rounded_card(c, x, y, w, h, fill=PANEL, stroke=PANEL)
    c.setFillColor(tone)
    c.setFont("Helvetica-Bold", 18)
    c.drawString(x + 4 * mm, y + h - 9 * mm, item["value"])
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 8.5)
    c.drawString(x + 4 * mm, y + h - 15 * mm, item["label"])
    text_block(
        c,
        item["detail"],
        x + 4 * mm,
        y + h - 21 * mm,
        w - 8 * mm,
        size=7.2,
        color=HexColor("#C7D2E4"),
        leading=9,
        max_lines=3,
    )
    pill(c, item["status"], x + 4 * mm, y + 4.5 * mm, tone)


def draw_cover(c: canvas.Canvas, data: dict[str, Any]) -> None:
    doc = data["document"]
    identity = data["identity"]
    c.setFillColor(NAVY)
    c.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
    # Subtle circuit traces.
    c.setStrokeColor(HexColor("#243A59"))
    c.setLineWidth(0.8)
    for i in range(8):
        y = 38 * mm + i * 12 * mm
        c.line(0, y, 28 * mm, y)
        c.line(28 * mm, y, 36 * mm, y + (6 if i % 2 else -6) * mm)
        c.line(36 * mm, y + (6 if i % 2 else -6) * mm, 53 * mm, y + (6 if i % 2 else -6) * mm)
    c.setFillColor(CYAN)
    c.rect(MARGIN, PAGE_H - 18 * mm, 24 * mm, 1.4 * mm, fill=1, stroke=0)
    c.setFont("Helvetica-Bold", 8)
    c.drawString(MARGIN + 28 * mm, PAGE_H - 19 * mm, doc["kicker"])

    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 31)
    c.drawString(MARGIN, PAGE_H - 48 * mm, "MEASURED")
    c.drawString(MARGIN, PAGE_H - 61 * mm, "RISC-V SOC")
    c.setFillColor(CYAN)
    c.drawString(MARGIN, PAGE_H - 74 * mm, "PORTFOLIO")
    text_block(
        c,
        doc["subtitle"],
        MARGIN,
        PAGE_H - 88 * mm,
        150 * mm,
        font="Helvetica",
        size=11,
        color=HexColor("#C7D2E4"),
        leading=15,
    )

    # Stylized SoC die.
    die_x, die_y, die_w, die_h = 61 * mm, 136 * mm, 88 * mm, 55 * mm
    c.setFillColor(PANEL)
    c.setStrokeColor(BLUE)
    c.setLineWidth(1.2)
    c.roundRect(die_x, die_y, die_w, die_h, 5 * mm, fill=1, stroke=1)
    nodes = [
        ("2-WIDE OOO", VIOLET, 67, 169, 34, 14),
        ("5-STAGE", BLUE, 107, 169, 34, 14),
        ("M9K MEMORY", CYAN, 67, 150, 34, 14),
        ("4x4 NPU", ORANGE, 107, 150, 34, 14),
    ]
    for label, color, x, y, w, h in nodes:
        c.setFillColor(color)
        c.roundRect(x * mm, y * mm, w * mm, h * mm, 2 * mm, fill=1, stroke=0)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 7.2)
        c.drawCentredString((x + w / 2) * mm, (y + 5.2) * mm, label)
    c.setFillColor(HexColor("#AFC0D8"))
    c.setFont("Courier-Bold", 8)
    c.drawCentredString(PAGE_W / 2, 141 * mm, "LOCKSTEP / ASSERT / MEASURE")

    gap = 3 * mm
    card_w = (PAGE_W - 2 * MARGIN - gap) / 2
    card_h = 34 * mm
    y2 = 57 * mm
    y1 = y2 + card_h + gap
    for idx, item in enumerate(data["headline_metrics"]):
        row, col = divmod(idx, 2)
        x = MARGIN + col * (card_w + gap)
        y = y1 if row == 0 else y2
        metric_card(c, item, x, y, card_w, card_h)

    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 11)
    c.drawString(MARGIN, 38 * mm, identity["name"])
    c.setFillColor(HexColor("#AFC0D8"))
    c.setFont("Helvetica", 8.5)
    c.drawString(MARGIN, 32.5 * mm, doc["author_line"])
    c.drawString(MARGIN, 27.5 * mm, data["production"]["repo_url"])
    c.setFillColor(ORANGE)
    c.setFont("Helvetica-Bold", 7.5)
    fpga = data["fpga"]
    build_mhz = mhz_label(fpga["build_only"]["clock_mhz"])
    silicon_ooo_mhz = mhz_label(fpga["hardware_confirmed"][1]["clock_mhz"])
    c.drawRightString(
        PAGE_W - MARGIN,
        32.5 * mm,
        f"BUILD-PROVEN {build_mhz} / SILICON-PROVEN {silicon_ooo_mhz}",
    )
    footer(c, 1, doc["page_count"], doc["footer_template"])
    c.showPage()


def draw_architecture(c: canvas.Canvas, data: dict[str, Any]) -> None:
    a = data["architecture"]
    y = page_base(c, 2, a["page_title"], "SYSTEM ARCHITECTURE")
    y = text_block(c, a["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 4 * mm
    rounded_card(c, MARGIN, y - 18 * mm, PAGE_W - 2 * MARGIN, 18 * mm, fill=HexColor("#EAF4FF"), stroke=HexColor("#C9E1FF"))
    c.setFillColor(BLUE)
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(PAGE_W / 2, y - 7 * mm, a["software_label"])
    pill(c, a["same_binary_label"], PAGE_W / 2 - 17 * mm, y - 12 * mm, BLUE)

    top = y - 29 * mm
    gap = 6 * mm
    col_w = (PAGE_W - 2 * MARGIN - gap) / 2
    h = 61 * mm
    for idx, key in enumerate(("inorder", "ooo")):
        item = a[key]
        x = MARGIN + idx * (col_w + gap)
        color = BLUE if key == "inorder" else VIOLET
        rounded_card(c, x, top - h, col_w, h, fill=LIGHT, stroke=color)
        c.setFillColor(color)
        c.rect(x, top - 9 * mm, col_w, 9 * mm, fill=1, stroke=0)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 11)
        c.drawString(x + 4 * mm, top - 6.2 * mm, item["title"])
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x + 4 * mm, top - 16 * mm, item["subtitle"])
        yy = top - 24 * mm
        for detail in item["details"]:
            c.setFillColor(color)
            c.circle(x + 5 * mm, yy + 1.1 * mm, 1.1 * mm, fill=1, stroke=0)
            yy = text_block(c, detail, x + 9 * mm, yy + 3 * mm, col_w - 13 * mm, size=8, color=INK, leading=10) - 2 * mm

    y = top - h - 10 * mm
    section_label(c, "Shared SoC platform", MARGIN, y, CYAN)
    y -= 9 * mm
    gap = 4 * mm
    card_w = (PAGE_W - 2 * MARGIN - 2 * gap) / 3
    for i, item in enumerate(a["shared"]):
        x = MARGIN + i * (card_w + gap)
        rounded_card(c, x, y - 31 * mm, card_w, 31 * mm, fill=HexColor("#F1FBFC"), stroke=HexColor("#BDE9ED"))
        c.setFillColor(CYAN)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(x + 4 * mm, y - 8 * mm, item["title"])
        text_block(c, item["detail"], x + 4 * mm, y - 15 * mm, card_w - 8 * mm, size=7.6, color=MUTED, leading=9.5, max_lines=4)

    y -= 40 * mm
    rounded_card(c, MARGIN, y - 31 * mm, PAGE_W - 2 * MARGIN, 31 * mm, fill=PANEL, stroke=PANEL)
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, a["iss_label"])
    text_block(c, a["iss_detail"], MARGIN + 5 * mm, y - 15 * mm, 78 * mm, size=7.8, color=white, leading=10)
    c.setStrokeColor(CYAN)
    c.setLineWidth(2)
    c.line(MARGIN + 89 * mm, y - 15 * mm, MARGIN + 108 * mm, y - 15 * mm)
    c.setFillColor(CYAN)
    c.circle(MARGIN + 98.5 * mm, y - 15 * mm, 2.2 * mm, fill=1, stroke=0)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 8)
    c.drawString(MARGIN + 113 * mm, y - 12.5 * mm, "RTL retirement")
    c.setFont("Helvetica", 7.3)
    c.drawString(MARGIN + 113 * mm, y - 18.5 * mm, "same binary / same ISA contract")
    text_block(c, a["board_label"], MARGIN + 5 * mm, y - 27 * mm, PAGE_W - 2 * MARGIN - 10 * mm, size=7.4, color=HexColor("#AFC0D8"), leading=9)
    end_page(c, 2, data)


def draw_performance(c: canvas.Canvas, data: dict[str, Any]) -> None:
    p = data["cpu_performance"]
    y = page_base(c, 3, p["page_title"], "PERFORMANCE")
    y = text_block(c, p["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    # CoreMark bars.
    x0, chart_y, chart_w, chart_h = MARGIN, y - 62 * mm, 80 * mm, 58 * mm
    rounded_card(c, x0, chart_y, chart_w, chart_h, fill=LIGHT, stroke=LINE)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(x0 + 5 * mm, chart_y + chart_h - 8 * mm, p["coremark_chart"]["title"])
    bars = p["coremark_chart"]["bars"]
    maxv = max(b["value"] for b in bars) * 1.12
    for i, bar in enumerate(bars):
        yy = chart_y + chart_h - (23 + i * 18) * mm
        c.setFillColor(HexColor("#E3E9F2"))
        c.roundRect(x0 + 5 * mm, yy, 65 * mm, 8 * mm, 2 * mm, fill=1, stroke=0)
        color = TONES[bar["tone"]]
        c.setFillColor(color)
        c.roundRect(x0 + 5 * mm, yy, 65 * mm * bar["value"] / maxv, 8 * mm, 2 * mm, fill=1, stroke=0)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 7.5)
        c.drawString(x0 + 5 * mm, yy + 10.5 * mm, bar["label"])
        c.drawRightString(x0 + 73 * mm, yy + 2.4 * mm, bar["display"])
    pill(c, p["coremark_chart"]["improvement_label"], x0 + 5 * mm, chart_y + 7 * mm, LIME)

    # Benchmark facts.
    bx = MARGIN + 87 * mm
    bw = PAGE_W - MARGIN - bx
    rounded_card(c, bx, chart_y, bw, chart_h, fill=PANEL, stroke=PANEL)
    b = p["benchmark"]
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(bx + 5 * mm, chart_y + chart_h - 8 * mm, b["title"])
    facts = [
        ("IPC", f"{b['ipc']:.3f}"),
        ("Full-run cycles", f"{b['full_run_cycles']:,}"),
        ("Retired + checked", f"{b['retired_instructions']:,}"),
        ("Iterations", str(b["iterations"])),
    ]
    yy = chart_y + chart_h - 19 * mm
    for label, value in facts:
        c.setFillColor(HexColor("#AFC0D8"))
        c.setFont("Helvetica", 7.4)
        c.drawString(bx + 5 * mm, yy, label)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 9)
        c.drawRightString(bx + bw - 5 * mm, yy, value)
        yy -= 8 * mm
    text_block(c, b["validation"], bx + 5 * mm, chart_y + 12 * mm, bw - 10 * mm, size=7.2, color=LIME, leading=9, max_lines=3)

    # Fmax journey.
    y = chart_y - 11 * mm
    section_label(c, p["fmax_chart"]["title"], MARGIN, y, VIOLET)
    base_y = y - 47 * mm
    left = MARGIN + 8 * mm
    right = PAGE_W - MARGIN - 6 * mm
    pts = p["fmax_chart"]["points"]
    minv, maxv = 6.0, 33.0
    c.setStrokeColor(LINE)
    for tick in (10, 20, 30):
        ty = base_y + (tick - minv) / (maxv - minv) * 38 * mm
        c.line(left, ty, right, ty)
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 6.5)
        c.drawRightString(left - 2 * mm, ty - 1.5 * mm, str(tick))
    coords = []
    for i, pt in enumerate(pts):
        x = left + i * (right - left) / (len(pts) - 1)
        yy = base_y + (pt["value"] - minv) / (maxv - minv) * 38 * mm
        coords.append((x, yy))
    c.setStrokeColor(VIOLET)
    c.setLineWidth(2)
    for (x1, y1), (x2, y2) in zip(coords, coords[1:]):
        c.line(x1, y1, x2, y2)
    for (x, yy), pt in zip(coords, pts):
        c.setFillColor(VIOLET if pt["short"] != "D029" else ORANGE)
        c.circle(x, yy, 2.1 * mm, fill=1, stroke=0)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 6.8)
        c.drawCentredString(x, yy + 4 * mm, f"{pt['value']:.2f}")
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 6.4)
        c.drawCentredString(x, base_y - 5 * mm, pt["short"])

    y = base_y - 14 * mm
    rounded_card(c, MARGIN, y - 33 * mm, PAGE_W - 2 * MARGIN, 33 * mm, fill=HexColor("#FFF5E8"), stroke=HexColor("#F8D7AD"))
    c.setFillColor(ORANGE)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, p["lesson_title"])
    text_block(c, p["lesson"], MARGIN + 5 * mm, y - 15 * mm, PAGE_W - 2 * MARGIN - 10 * mm, size=8.1, color=INK, leading=10.5, max_lines=5)
    end_page(c, 3, data)


def draw_verification(c: canvas.Canvas, data: dict[str, Any]) -> None:
    v = data["verification"]
    y = page_base(c, 4, v["page_title"], "VERIFICATION")
    y = text_block(c, v["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    # Lockstep flow.
    flow_y = y - 37 * mm
    flow_h = 34 * mm
    rounded_card(c, MARGIN, flow_y, PAGE_W - 2 * MARGIN, flow_h, fill=PANEL, stroke=PANEL)
    labels = [v["lockstep"]["rtl_label"], v["lockstep"]["comparator_label"], v["lockstep"]["iss_label"]]
    colors = [BLUE, CYAN, VIOLET]
    node_w = 48 * mm
    xs = [MARGIN + 5 * mm, PAGE_W / 2 - node_w / 2, PAGE_W - MARGIN - 5 * mm - node_w]
    for i, (label, color, x) in enumerate(zip(labels, colors, xs)):
        c.setFillColor(color)
        c.roundRect(x, flow_y + 13 * mm, node_w, 12 * mm, 2 * mm, fill=1, stroke=0)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 7.2)
        c.drawCentredString(x + node_w / 2, flow_y + 17.5 * mm, label)
        if i < 2:
            c.setStrokeColor(HexColor("#8AA1C0"))
            c.setLineWidth(1.5)
            c.line(x + node_w, flow_y + 19 * mm, xs[i + 1], flow_y + 19 * mm)
    c.setFillColor(HexColor("#AFC0D8"))
    c.setFont("Helvetica", 7)
    c.drawCentredString(PAGE_W / 2, flow_y + 6 * mm, v["lockstep"]["compares"])

    y = flow_y - 9 * mm
    # Coverage + lanes.
    cov_w = 53 * mm
    rounded_card(c, MARGIN, y - 58 * mm, cov_w, 58 * mm, fill=LIGHT, stroke=LINE)
    cov = v["coverage"]
    c.setStrokeColor(HexColor("#D6DEE9"))
    c.setLineWidth(8)
    c.circle(MARGIN + cov_w / 2, y - 27 * mm, 16 * mm, fill=0, stroke=1)
    c.setStrokeColor(LIME)
    c.setLineWidth(8)
    c.setLineCap(1)
    start = 90
    extent = -360 * cov["percent"] / 100
    c.arc(MARGIN + cov_w / 2 - 16 * mm, y - 43 * mm, MARGIN + cov_w / 2 + 16 * mm, y - 11 * mm, startAng=start, extent=extent)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 18)
    c.drawCentredString(MARGIN + cov_w / 2, y - 28 * mm, f"{cov['percent']:.1f}%")
    c.setFont("Helvetica-Bold", 7.5)
    c.drawCentredString(MARGIN + cov_w / 2, y - 49 * mm, f"{cov['covered']} / {cov['total']} RTL lines")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 6.8)
    c.drawCentredString(MARGIN + cov_w / 2, y - 54 * mm, f"{cov['programs_per_core']} programs per core")

    lanes_x = MARGIN + cov_w + 6 * mm
    lanes_w = PAGE_W - MARGIN - lanes_x
    gap = 3 * mm
    lane_h = (58 * mm - 2 * gap) / 3
    for i, lane in enumerate(v["test_lanes"]):
        col = i % 2
        row = i // 2
        w = (lanes_w - gap) / 2
        x = lanes_x + col * (w + gap)
        yy = y - (row + 1) * lane_h - row * gap
        rounded_card(c, x, yy, w, lane_h, fill=HexColor("#F7F9FC"), stroke=LINE)
        c.setFillColor(BLUE if i < 3 else VIOLET)
        c.setFont("Helvetica-Bold", 12)
        c.drawString(x + 4 * mm, yy + lane_h - 7 * mm, lane["value"])
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 7)
        c.drawString(x + 4 * mm, yy + lane_h - 12 * mm, lane["label"])
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 6.4)
        c.drawString(x + 4 * mm, yy + 3.5 * mm, lane["detail"])

    y -= 68 * mm
    section_label(c, f"{v['bugs']['count']} documented RTL / SoC bugs", MARGIN, y, RED)
    y -= 10 * mm
    case_w = (PAGE_W - 2 * MARGIN - 3 * 3 * mm) / 4
    for i, case in enumerate(v["bugs"]["cases"]):
        x = MARGIN + i * (case_w + 3 * mm)
        rounded_card(c, x, y - 50 * mm, case_w, 50 * mm, fill=HexColor("#FFF3F4"), stroke=HexColor("#F4C5C9"))
        c.setFillColor(RED)
        c.setFont("Helvetica-Bold", 11)
        c.drawString(x + 4 * mm, y - 8 * mm, case["id"])
        yy = text_block(c, case["summary"], x + 4 * mm, y - 15 * mm, case_w - 8 * mm, size=7.3, color=INK, leading=9, max_lines=4)
        text_block(c, case["caught_by"], x + 4 * mm, yy - 3 * mm, case_w - 8 * mm, size=6.6, color=MUTED, leading=8, max_lines=4)
    end_page(c, 4, data)


def draw_npu(c: canvas.Canvas, data: dict[str, Any]) -> None:
    n = data["npu"]
    y = page_base(c, 5, n["page_title"], "ACCELERATOR")
    y = text_block(c, n["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    # Array visualization.
    array_x, array_y = MARGIN, y - 70 * mm
    array_w, array_h = 74 * mm, 66 * mm
    rounded_card(c, array_x, array_y, array_w, array_h, fill=PANEL, stroke=PANEL)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(array_x + 5 * mm, array_y + array_h - 8 * mm, n["array"]["label"])
    cell = 9 * mm
    gx = array_x + 18 * mm
    gy = array_y + 15 * mm
    for r in range(n["array"]["rows"]):
        for col in range(n["array"]["columns"]):
            color = Color(0.96, 0.62 - r * 0.03, 0.25 + col * 0.04)
            c.setFillColor(color)
            c.roundRect(gx + col * (cell + 2 * mm), gy + (3 - r) * (cell + 2 * mm), cell, cell, 1.5 * mm, fill=1, stroke=0)
            c.setFillColor(NAVY)
            c.setFont("Helvetica-Bold", 6.5)
            c.drawCentredString(gx + col * (cell + 2 * mm) + cell / 2, gy + (3 - r) * (cell + 2 * mm) + 3.2 * mm, "MAC")
    c.setFillColor(HexColor("#AFC0D8"))
    c.setFont("Helvetica", 6.8)
    c.drawCentredString(array_x + array_w / 2, array_y + 7 * mm, n["array"]["datatype"])

    # Network and accuracy.
    nx = MARGIN + 81 * mm
    nw = PAGE_W - MARGIN - nx
    rounded_card(c, nx, array_y, nw, array_h, fill=LIGHT, stroke=LINE)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(nx + 5 * mm, array_y + array_h - 8 * mm, n["network"]["label"])
    shapes = [(784, 13 * mm, BLUE), (32, 8 * mm, VIOLET), (10, 6 * mm, ORANGE)]
    cx = nx + 17 * mm
    cy = array_y + 35 * mm
    for i, (value, radius, color) in enumerate(shapes):
        c.setFillColor(color)
        c.circle(cx + i * 29 * mm, cy, radius, fill=1, stroke=0)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 9)
        c.drawCentredString(cx + i * 29 * mm, cy - 2.5, str(value))
        if i < 2:
            c.setStrokeColor(MUTED)
            c.line(cx + i * 29 * mm + radius, cy, cx + (i + 1) * 29 * mm - shapes[i + 1][1], cy)
    c.setFillColor(LIME)
    c.setFont("Helvetica-Bold", 15)
    c.drawString(nx + 5 * mm, array_y + 11 * mm, f"{n['network']['integer_accuracy_percent']:.2f}%")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 6.8)
    c.drawString(nx + 31 * mm, array_y + 12.2 * mm, f"integer accuracy / {n['network']['dataset_images']:,} offline images")

    y = array_y - 10 * mm
    section_label(c, "Same workload: RV32I software vs NPU", MARGIN, y, ORANGE)
    y -= 12 * mm
    max_speedup = max(s["speedup"] for s in n["speedups"])
    for i, speed in enumerate(n["speedups"]):
        yy = y - i * 27 * mm
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(MARGIN, yy, speed["label"])
        c.setFillColor(HexColor("#E5EAF2"))
        c.roundRect(MARGIN, yy - 11 * mm, 135 * mm, 8 * mm, 2 * mm, fill=1, stroke=0)
        c.setFillColor(ORANGE if i == 0 else VIOLET)
        c.roundRect(MARGIN, yy - 11 * mm, 135 * mm * speed["speedup"] / max_speedup, 8 * mm, 2 * mm, fill=1, stroke=0)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 12)
        c.drawRightString(PAGE_W - MARGIN, yy - 9 * mm, speed["display"])
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 6.6)
        c.drawString(MARGIN, yy - 16 * mm, f"{speed['software_cycles']:,} software cycles -> {speed['npu_cycles']:,} NPU cycles")

    y -= 59 * mm
    gap = 4 * mm
    w = (PAGE_W - 2 * MARGIN - gap) / 2
    rounded_card(c, MARGIN, y - 39 * mm, w, 39 * mm, fill=HexColor("#EDF9F0"), stroke=HexColor("#C5E9CE"))
    c.setFillColor(LIME)
    c.setFont("Helvetica-Bold", 12)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, "32 / 32 bit-exact")
    text_block(c, n["bit_exact"]["statement"], MARGIN + 5 * mm, y - 16 * mm, w - 10 * mm, size=7.8, color=INK, leading=10, max_lines=4)
    x = MARGIN + w + gap
    rounded_card(c, x, y - 39 * mm, w, 39 * mm, fill=HexColor("#FFF5E8"), stroke=HexColor("#F8D7AD"))
    c.setFillColor(ORANGE)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(x + 5 * mm, y - 8 * mm, "Board demo is built, not flashed")
    text_block(c, n["board_demo"]["statement"], x + 5 * mm, y - 16 * mm, w - 10 * mm, size=7.4, color=INK, leading=9.5, max_lines=5)
    end_page(c, 5, data)


def draw_fpga(c: canvas.Canvas, data: dict[str, Any]) -> None:
    f = data["fpga"]
    y = page_base(c, 6, f["page_title"], "FPGA IMPLEMENTATION")
    y = text_block(c, f["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    # Resources.
    rounded_card(c, MARGIN, y - 52 * mm, 82 * mm, 52 * mm, fill=LIGHT, stroke=LINE)
    r = f["resources"]
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, r["title"])
    c.setFillColor(HexColor("#E1E7F0"))
    c.roundRect(MARGIN + 5 * mm, y - 23 * mm, 70 * mm, 10 * mm, 2.5 * mm, fill=1, stroke=0)
    c.setFillColor(VIOLET)
    c.roundRect(MARGIN + 5 * mm, y - 23 * mm, 70 * mm * r["logic_used"] / r["logic_capacity"], 10 * mm, 2.5 * mm, fill=1, stroke=0)
    c.setFillColor(INK)
    c.setFont("Helvetica-Bold", 13)
    c.drawString(MARGIN + 5 * mm, y - 33 * mm, f"{r['logic_used']:,} / {r['logic_capacity']:,} LEs")
    c.setFillColor(MUTED)
    c.setFont("Helvetica", 7)
    c.drawString(MARGIN + 5 * mm, y - 40 * mm, f"{r['registers']:,} registers / {r['memory_bits']:,} memory bits")
    c.drawString(
        MARGIN + 5 * mm,
        y - 46 * mm,
        f"{r['m9k_blocks']} / {r['m9k_capacity']} M9Ks / {r['multiplier_elements']} multiplier elements",
    )

    # Timing.
    tx = MARGIN + 89 * mm
    tw = PAGE_W - MARGIN - tx
    rounded_card(c, tx, y - 52 * mm, tw, 52 * mm, fill=PANEL, stroke=PANEL)
    t = f["timing"]
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 10)
    c.drawString(tx + 5 * mm, y - 8 * mm, t["title"])
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 21)
    c.drawString(tx + 5 * mm, y - 21 * mm, f"{t['configured_clock_mhz']:.0f} MHz")
    c.setFillColor(LIME)
    c.setFont("Helvetica-Bold", 10)
    c.drawRightString(tx + tw - 5 * mm, y - 20 * mm, f"Fmax {t['fmax_mhz']:.2f} MHz")
    facts = [
        ("setup", t["setup_slack_ns"]),
        ("hold", t["hold_slack_ns"]),
        ("recovery", t["recovery_slack_ns"]),
        ("removal", t["removal_slack_ns"]),
    ]
    yy = y - 31 * mm
    for i, (label, value) in enumerate(facts):
        col = i % 2
        row = i // 2
        xx = tx + 5 * mm + col * 35 * mm
        cy = yy - row * 9 * mm
        c.setFillColor(HexColor("#AFC0D8"))
        c.setFont("Helvetica", 6.6)
        c.drawString(xx, cy, label)
        c.setFillColor(white)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(xx + 15 * mm, cy, f"+{value:.3f} ns")

    y -= 63 * mm
    section_label(c, "Evidence classes", MARGIN, y, BLUE)
    y -= 11 * mm
    class_gap = 4 * mm
    class_w = (PAGE_W - 2 * MARGIN - 2 * class_gap) / 3
    classes = [
        (
            "HARDWARE-CONFIRMED",
            LIME,
            f["hardware_confirmed"][0]["label"],
            mhz_label(f["hardware_confirmed"][0]["clock_mhz"]),
            f["hardware_confirmed"][0]["proof"],
        ),
        (
            "HARDWARE-CONFIRMED",
            CYAN,
            f["hardware_confirmed"][1]["label"],
            mhz_label(f["hardware_confirmed"][1]["clock_mhz"]),
            f["hardware_confirmed"][1]["proof"],
        ),
        (
            "BUILD-ONLY",
            ORANGE,
            f["build_only"]["label"],
            mhz_label(f["build_only"]["clock_mhz"]),
            f["build_only"]["status"],
        ),
    ]
    for i, (status, color, label, value, detail) in enumerate(classes):
        x = MARGIN + i * (class_w + class_gap)
        rounded_card(c, x, y - 57 * mm, class_w, 57 * mm, fill=LIGHT if i < 2 else HexColor("#FFF5E8"), stroke=color)
        pill(c, status, x + 4 * mm, y - 5 * mm, color)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x + 4 * mm, y - 18 * mm, label)
        c.setFillColor(color)
        c.setFont("Helvetica-Bold", 16)
        c.drawString(x + 4 * mm, y - 29 * mm, value)
        text_block(c, detail, x + 4 * mm, y - 38 * mm, class_w - 8 * mm, size=6.7, color=MUTED, leading=8.2, max_lines=5)

    y -= 68 * mm
    section_label(c, "Implementation moves", MARGIN, y, VIOLET)
    y -= 10 * mm
    for i, move in enumerate(f["implementation_moves"]):
        col = i % 2
        row = i // 2
        x = MARGIN + col * 90 * mm
        yy = y - row * 12 * mm
        c.setFillColor(VIOLET)
        c.circle(x + 1.5 * mm, yy + 1.5 * mm, 1.2 * mm, fill=1, stroke=0)
        text_block(c, move, x + 5 * mm, yy + 3.5 * mm, 81 * mm, size=7.3, color=INK, leading=9, max_lines=2)
    end_page(c, 6, data)


def draw_decisions(c: canvas.Canvas, data: dict[str, Any]) -> None:
    d = data["decisions"]
    y = page_base(c, 7, d["page_title"], "ENGINEERING JUDGMENT")
    y = text_block(c, d["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    gap = 5 * mm
    card_w = (PAGE_W - 2 * MARGIN - gap) / 2
    card_h = 67 * mm
    for i, item in enumerate(d["items"]):
        row, col = divmod(i, 2)
        x = MARGIN + col * (card_w + gap)
        top = y - row * (card_h + gap)
        yy = top - card_h
        color = [BLUE, ORANGE, VIOLET, CYAN][i]
        rounded_card(c, x, yy, card_w, card_h, fill=LIGHT, stroke=color)
        pill(c, item["id"], x + 4 * mm, top - 5 * mm, color)
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 9)
        c.drawString(x + 4 * mm, top - 19 * mm, item["title"])
        c.setFillColor(MUTED)
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 4 * mm, top - 27 * mm, "PROBLEM")
        pos = text_block(c, item["problem"], x + 4 * mm, top - 32 * mm, card_w - 8 * mm, size=6.8, color=INK, leading=8.3, max_lines=3)
        c.setFillColor(MUTED)
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 4 * mm, pos - 2 * mm, "CHOICE")
        pos = text_block(c, item["choice"], x + 4 * mm, pos - 7 * mm, card_w - 8 * mm, size=6.8, color=INK, leading=8.3, max_lines=4)
        c.setFillColor(color)
        c.setFont("Helvetica-Bold", 6.5)
        c.drawString(x + 4 * mm, pos - 1 * mm, "EVIDENCE")
        text_block(c, item["evidence"], x + 4 * mm, pos - 6 * mm, card_w - 8 * mm, size=6.8, color=INK, leading=8.3, max_lines=4)

    y = y - 2 * (card_h + gap) - 3 * mm
    rounded_card(c, MARGIN, y - 37 * mm, PAGE_W - 2 * MARGIN, 37 * mm, fill=PANEL, stroke=PANEL)
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, d["lessons_title"])
    for i, lesson in enumerate(d["lessons"]):
        col = i % 2
        row = i // 2
        x = MARGIN + 5 * mm + col * 90 * mm
        yy = y - 16 * mm - row * 9 * mm
        c.setFillColor(CYAN)
        c.circle(x + 1 * mm, yy + 1 * mm, 1 * mm, fill=1, stroke=0)
        text_block(c, lesson, x + 5 * mm, yy + 3 * mm, 82 * mm, size=6.8, color=white, leading=8.2, max_lines=2)
    end_page(c, 7, data)


def draw_evidence(c: canvas.Canvas, data: dict[str, Any]) -> None:
    e = data["evidence"]
    y = page_base(c, 8, e["page_title"], "REPRODUCIBILITY")
    y = text_block(c, e["page_intro"], MARGIN, y, PAGE_W - 2 * MARGIN, size=9.2, color=MUTED, leading=12)
    y -= 5 * mm
    # Evidence matrix.
    gap = 4 * mm
    w = (PAGE_W - 2 * MARGIN - 2 * gap) / 3
    colors = [BLUE, VIOLET, LIME]
    for i, row in enumerate(e["status_matrix"]):
        x = MARGIN + i * (w + gap)
        rounded_card(c, x, y - 54 * mm, w, 54 * mm, fill=LIGHT, stroke=colors[i])
        pill(c, row["class"], x + 4 * mm, y - 5 * mm, colors[i])
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 6.6)
        c.drawString(x + 4 * mm, y - 19 * mm, "PROVES")
        pos = text_block(c, row["proves"], x + 4 * mm, y - 24 * mm, w - 8 * mm, size=6.6, color=INK, leading=8, max_lines=4)
        c.setFillColor(MUTED)
        c.setFont("Helvetica-Bold", 6.3)
        c.drawString(x + 4 * mm, pos - 2 * mm, "DOES NOT PROVE")
        text_block(c, row["does_not_prove"], x + 4 * mm, pos - 7 * mm, w - 8 * mm, size=6.4, color=MUTED, leading=7.8, max_lines=3)

    y -= 65 * mm
    section_label(c, "Evidence links", MARGIN, y, CYAN)
    y -= 10 * mm
    for i, link in enumerate(e["links"]):
        col = i % 2
        row = i // 2
        x = MARGIN + col * 91 * mm
        yy = y - row * 14 * mm
        c.setFillColor(INK)
        c.setFont("Helvetica-Bold", 7.2)
        c.drawString(x, yy, link["label"])
        c.setFillColor(BLUE)
        c.setFont("Helvetica", 6.7)
        display = link["display"]
        c.drawString(x, yy - 5 * mm, display)
        width = stringWidth(display, "Helvetica", 6.7)
        c.linkURL(link["url"], (x, yy - 6 * mm, x + width, yy + 1 * mm), relative=0)

    y -= 61 * mm
    rounded_card(c, MARGIN, y - 42 * mm, 105 * mm, 42 * mm, fill=PANEL, stroke=PANEL)
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(MARGIN + 5 * mm, y - 8 * mm, "Reproduction entry points")
    for i, cmd in enumerate(e["commands"][:6]):
        col = i % 2
        row = i // 2
        x = MARGIN + 5 * mm + col * 50 * mm
        yy = y - 17 * mm - row * 8 * mm
        c.setFillColor(LIME)
        c.setFont("Courier-Bold", 6.7)
        c.drawString(x, yy, cmd["command"])
        text_block(
            c,
            cmd["purpose"],
            x,
            yy - 3.5 * mm,
            45 * mm,
            size=5.8,
            color=HexColor("#AFC0D8"),
            max_lines=1,
        )

    bx = MARGIN + 111 * mm
    bw = PAGE_W - MARGIN - bx
    rounded_card(c, bx, y - 42 * mm, bw, 42 * mm, fill=HexColor("#FFF5E8"), stroke=ORANGE)
    c.setFillColor(ORANGE)
    c.setFont("Helvetica-Bold", 9)
    c.drawString(bx + 5 * mm, y - 8 * mm, data["boundaries"]["title"])
    text_block(c, data["boundaries"]["short_statement"], bx + 5 * mm, y - 16 * mm, bw - 10 * mm, size=7.1, color=INK, leading=9, max_lines=5)

    y -= 52 * mm
    c.setFillColor(NAVY)
    c.roundRect(MARGIN, y - 38 * mm, PAGE_W - 2 * MARGIN, 38 * mm, 3 * mm, fill=1, stroke=0)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 15)
    c.drawString(MARGIN + 7 * mm, y - 11 * mm, e["contact_title"])
    c.setFillColor(HexColor("#AFC0D8"))
    c.setFont("Helvetica", 8)
    c.drawString(MARGIN + 7 * mm, y - 19 * mm, e["contact_line"])
    c.setFillColor(CYAN)
    c.setFont("Helvetica-Bold", 8)
    c.drawString(MARGIN + 7 * mm, y - 28 * mm, data["production"]["repo_url"])
    c.linkURL(data["production"]["repo_url"], (MARGIN + 7 * mm, y - 30 * mm, MARGIN + 95 * mm, y - 24 * mm), relative=0)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 7.2)
    c.drawRightString(PAGE_W - MARGIN - 7 * mm, y - 11 * mm, data["production"]["commit_label"])
    text_block(c, data["document"]["closing_line"], PAGE_W - MARGIN - 75 * mm, y - 20 * mm, 68 * mm, font="Helvetica-Oblique", size=7.2, color=HexColor("#C7D2E4"), leading=9, max_lines=3)
    end_page(c, 8, data)


def build_pdf(data: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    # ReportLab's invariant mode removes wall-clock timestamps and generates a
    # stable document ID. The same evidence and renderer therefore produce the
    # same bytes, which makes the checked-in PDF auditable instead of opaque.
    c = canvas.Canvas(str(output), pagesize=A4, pageCompression=1, invariant=1)
    c.setTitle(data["document"]["title"])
    c.setAuthor(data["identity"]["name"])
    c.setSubject(data["document"]["subject"])
    c.setCreator(data["document"]["creator"])
    draw_cover(c, data)
    draw_architecture(c, data)
    draw_performance(c, data)
    draw_verification(c, data)
    draw_npu(c, data)
    draw_fpga(c, data)
    draw_decisions(c, data)
    draw_evidence(c, data)
    c.save()


def main() -> int:
    args = parse_args()
    evidence_path = args.evidence.resolve()
    data = load_evidence(evidence_path)
    output = args.output or (ROOT / data["document"]["output_path"])
    output = output.resolve()
    build_pdf(data, output)
    print(f"portfolio: wrote {output} ({data['document']['page_count']} A4 pages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
