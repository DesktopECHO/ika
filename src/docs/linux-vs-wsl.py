#!/usr/bin/env python3
"""Writes linux-vs-wsl-light.svg and linux-vs-wsl-dark.svg, the chart in GRAPHICS.md's WSL2 section.

Each panel: rows = labels, l = Linux values, w = WSL2 values (None where there is no result),
n = a note for a row, by row index. Latest results only. Each panel is drawn with its rows in the
order of their Linux values, highest first. Run it in this directory after a change.
"""
import math
import os
from xml.sax.saxutils import escape

N = None
GPUS = ['RTX 4080 Laptop GPU', 'Radeon 780M', 'Apple M1 Pro', 'Intel UHD 770']
SUBTITLE = 'Ika 261111, Geekbench 7.1 and 3DMark. Higher is better. Percent: WSL2 as a share of Linux.'
PANELS = [
    dict(t='Geekbench 7.1 GPU (Vulkan)', u='Score',
         rows=GPUS,
         l=[140564, 33106, 24702, 6484], w=[71924, 16178, N, N],
         n={3: 'WSL2: host GPU reset during the test'}),
    dict(t='3DMark Wild Life Extreme', u='Score, mean of two passes', rows=GPUS,
         l=[28664, 5085, 5784, 1414], w=[12813, 4265, N, 1558], n={}),
    dict(t='3DMark Steel Nomad Light', u='Score, mean of two passes', rows=GPUS,
         l=[14720, 2459, 2015, N], w=[4568, 2444, N, N],
         n={3: 'Linux: not supported; WSL2: host GPU reset'}),
    dict(t='3DMark Sling Shot Extreme', u='Frames per second, mean of two passes', dec=1, rows=GPUS,
         l=[143.9, 60.0, 117.8, 42.6], w=[84.9, 58.7, N, 33.6], n={}),
]


def by_linux(p):
    """The panel with its rows in the order of their Linux values, highest first, those without one last."""
    order = sorted(range(len(p['rows'])), key=lambda i: (p['l'][i] is None, -(p['l'][i] or 0)))
    return dict(p, rows=[p['rows'][i] for i in order], l=[p['l'][i] for i in order],
                w=[p['w'][i] for i in order], n={k: p['n'][i] for k, i in enumerate(order) if i in p['n']})


PANELS = [by_linux(p) for p in PANELS]

THEMES = {
    'light': dict(ink='#0b0b0b', ink2='#52514e', muted='#6f6e69', grid='#e1e0d9', base='#c3c2b7',
                  linux='#008300', wsl='#2a78d6'),
    'dark': dict(ink='#f0efec', ink2='#c3c2b7', muted='#a09f98', grid='#2c2c2a', base='#4a4a46',
                 linux='#1c9a1c', wsl='#3987e5'),
}

W, LEFT = 760, 150                     # width, label column
PITCH, BAR, GAP = 44, 15, 2            # row pitch, bar thickness, gap between a row's two bars
HEAD, FOOT = 30, 46                    # a panel's title band, and its axis band
FONT = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def nice_step(span, ticks=5):
    raw = span / ticks
    mag = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 2.5, 5, 10):
        if raw <= m * mag:
            return m * mag
    return 10 * mag


def axis(p):
    """A panel's tick step and the value at the end of its axis: the first tick past its largest value."""
    top = max(v for v in p['l'] + p['w'] if v is not None)
    step = nice_step(top)
    return step, math.ceil(top / step) * step


def labels(p):
    """Each bar's value and the text beside it."""
    dec = p.get('dec', 0)
    for L, Wv in zip(p['l'], p['w']):
        if L is not None:
            yield L, f'{L:,.{dec}f}'
        if Wv is not None:
            yield Wv, f'{Wv:,.{dec}f}' + (f'  ({round(Wv / L * 100)}%)' if L is not None else '')


def plot_width():
    """The widest axis, the same for every panel, that leaves each bar's text inside the image."""
    width = W - LEFT - 8
    for p in PANELS:
        top = axis(p)[1]
        for v, s in labels(p):
            width = min(width, (W - LEFT - 6 - 6.6 * len(s)) * top / v)
    return width


def bar(x0, y, w, h, fill):
    r = min(4, w)
    x1 = x0 + w
    return (f'<path d="M{x0:.1f},{y:.1f}H{x1 - r:.1f}A{r:.1f},{r:.1f} 0 0 1 {x1:.1f},{y + r:.1f}V{y + h - r:.1f}'
            f'A{r:.1f},{r:.1f} 0 0 1 {x1 - r:.1f},{y + h:.1f}H{x0:.1f}Z" fill="{fill}"/>')


def render(c):
    out, y = [], 0
    text = lambda x, yy, s, fill, size=12, anchor='start', weight=400: (
        f'<text x="{x:.1f}" y="{yy:.1f}" fill="{fill}" font-size="{size}" font-weight="{weight}" '
        f'text-anchor="{anchor}" dominant-baseline="central">{escape(s)}</text>')
    out.append(text(0, 12, 'Linux and WSL2 on the same hosts', c['ink'], 17, weight=600))
    out.append(text(0, 36, SUBTITLE, c['ink2'], 12.5))
    out.append(f'<rect x="0" y="54" width="12" height="12" rx="2" fill="{c["linux"]}"/>')
    out.append(text(18, 60, 'Linux (upper bar)', c['ink2'], 12.5))
    out.append(f'<rect x="140" y="54" width="12" height="12" rx="2" fill="{c["wsl"]}"/>')
    out.append(text(158, 60, 'WSL2 (lower bar)', c['ink2'], 12.5))
    y = 84
    desc = []
    plot = plot_width()
    for p in PANELS:
        dec = p.get('dec', 0)
        fmt = lambda v: f'{v:,.{dec}f}'
        step, top = axis(p)
        sx = lambda v: LEFT + v / top * plot
        rows = len(p['rows'])
        y0 = y + HEAD
        y1 = y0 + rows * PITCH
        out.append(text(0, y + 10, p['t'], c['ink'], 14, weight=600))
        # A gridline stops where a bar's text would sit on it.
        taken = []
        for i in range(rows):
            L, Wv = p['l'][i], p['w'][i]
            for half, v in enumerate((L, Wv)):
                if v is not None:
                    s = fmt(v) + (f'  ({round(v / L * 100)}%)' if half and L is not None else '')
                    taken.append((y0 + i * PITCH + half * PITCH / 2, sx(v) + 2, sx(v) + 10 + 6.6 * len(s)))
        t = 0
        while t <= top + step / 2:
            x = sx(t)
            if t:
                ya = y0
                for yy, xa, xb in taken + [(y1, x, x)]:
                    if xa <= x <= xb:
                        if yy > ya:
                            out.append(f'<line x1="{x:.1f}" y1="{ya:.1f}" x2="{x:.1f}" y2="{yy:.1f}" stroke="{c["grid"]}" stroke-width="1"/>')
                        ya = yy + PITCH / 2
            out.append(text(x, y1 + 12, f'{t:,.0f}', c['muted'], 11.5, 'middle'))
            t += step
        out.append(text(LEFT + plot / 2, y1 + 32, p['u'], c['muted'], 11.5, 'middle'))
        out.append(f'<line x1="{LEFT}" y1="{y0}" x2="{LEFT}" y2="{y1}" stroke="{c["base"]}" stroke-width="1"/>')
        for i, name in enumerate(p['rows']):
            L, Wv = p['l'][i], p['w'][i]
            mid = y0 + i * PITCH + PITCH / 2
            yl, yw = mid - GAP / 2 - BAR, mid + GAP / 2
            out.append(text(LEFT - 8, mid, name, c['ink'], 12, 'end'))
            if L is not None:
                out.append(bar(LEFT, yl, sx(L) - LEFT, BAR, c['linux']))
                out.append(text(sx(L) + 6, yl + BAR / 2, fmt(L), c['ink']))
            if Wv is not None:
                share = f'  ({round(Wv / L * 100)}%)' if L is not None else ''
                out.append(bar(LEFT, yw, sx(Wv) - LEFT, BAR, c['wsl']))
                out.append(text(sx(Wv) + 6, yw + BAR / 2, fmt(Wv) + share, c['ink']))
            note = p['n'].get(i)
            if note:
                out.append(text(LEFT + 8, mid if L is None and Wv is None else yw + BAR / 2, note, c['muted']))
            desc.append(f'{p["t"]}, {name}: Linux {fmt(L) if L is not None else "none"}, '
                        f'WSL2 {fmt(Wv) if Wv is not None else "none"}.')
        y = y1 + FOOT + 18
    h = y - 14
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-16 -12 {W + 32} {h + 24}" width="{W + 32}" '
            f'height="{h + 24}" role="img" font-family="{FONT}">\n'
            f'<title>Ika 261111: Geekbench 7.1 and 3DMark on Linux and under WSL2</title>\n'
            f'<desc>{escape(" ".join(desc))}</desc>\n' + '\n'.join(out) + '\n</svg>\n')


here = os.path.dirname(os.path.abspath(__file__))
for name, colors in THEMES.items():
    with open(os.path.join(here, f'linux-vs-wsl-{name}.svg'), 'w') as f:
        f.write(render(colors))
