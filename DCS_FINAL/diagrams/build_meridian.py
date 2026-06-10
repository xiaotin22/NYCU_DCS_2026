# -*- coding: utf-8 -*-
"""
SILICON MERIDIAN — Conformer Accelerator (CA.sv) charted as engineering plates.
Plate I  : ARCHITECTURE  — the static structure (Control + DataPath hierarchy)
Plate II : DATA FLOW     — the journey of one matrix through the shared pipeline
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Polygon, Circle
from matplotlib.backends.backend_pdf import PdfPages
import matplotlib.font_manager as fm

# ----------------------------------------------------------------------------- paths
FONT_DIR = r"C:\Users\terry\.claude\skills\canvas-design\canvas-fonts"
OUT_DIR  = r"C:\Users\terry\OneDrive\文件\NYCU_DCS_2026\DCS_FINAL\diagrams"
os.makedirs(OUT_DIR, exist_ok=True)

def F(name):
    return fm.FontProperties(fname=os.path.join(FONT_DIR, name))

f_display = F("BigShoulders-Bold.ttf")
f_disp_r  = F("BigShoulders-Regular.ttf")
f_label_b = F("IBMPlexMono-Bold.ttf")
f_label   = F("IBMPlexMono-Regular.ttf")
f_micro   = F("GeistMono-Regular.ttf")
f_serif   = F("IBMPlexSerif-Italic.ttf")
f_tag     = F("Tektur-Medium.ttf")

# ----------------------------------------------------------------------------- palette
PAPER     = "#EAE3D1"   # aged drafting stock
BLOCK     = "#F6F1E5"   # near-white module fill
BLOCK_DP  = "#EFE7D5"   # inner sub-module fill
INK       = "#1C2530"   # graphite navy-black
INK_SOFT  = "#566070"   # slate
HAIR      = "#B7AC92"   # faint drafting hairline
DATA      = "#B14C26"   # oxide / burnt sienna  — the path data walks
CTRL      = "#2E6B66"   # deep teal             — the quieter hand of control
GOLD      = "#BE9540"   # rationed highlight    — the last token

W, H = 120.0, 150.0     # data field (portrait), fig = 12 x 15 in

# ----------------------------------------------------------------------------- helpers
def track(s, sp=" "):
    return sp.join(list(s))

def T(ax, x, y, s, fp, size, color=INK, ha="left", va="center", rot=0,
      alpha=1.0, z=6):
    ax.text(x, y, s, fontproperties=fp, fontsize=size, color=color,
            ha=ha, va=va, rotation=rot, alpha=alpha, zorder=z)

def rect(ax, x, y, w, h, fc, ec=None, lw=1.0, z=2, alpha=1.0, ls="-"):
    ax.add_patch(Rectangle((x, y), w, h, facecolor=fc,
                 edgecolor=ec if ec else "none", linewidth=lw, zorder=z,
                 alpha=alpha, linestyle=ls, joinstyle="miter"))

def line(ax, x0, y0, x1, y1, color, lw=1.0, z=3, ls="-", alpha=1.0):
    ax.plot([x0, x1], [y0, y1], color=color, lw=lw, ls=ls, alpha=alpha,
            zorder=z, solid_capstyle="round")

def head(ax, x, y, ang, color, size=1.5, z=5):
    w = size * 0.60
    bx, by = x - size*np.cos(ang), y - size*np.sin(ang)
    px, py = -np.sin(ang), np.cos(ang)
    ax.add_patch(Polygon([(x, y), (bx+w*px, by+w*py), (bx-w*px, by-w*py)],
                 closed=True, facecolor=color, edgecolor="none", zorder=z))

def parrow(ax, pts, color, lw=1.6, z=3, ls="-", size=1.6, alpha=1.0,
           arrow=True):
    pts = np.asarray(pts, float)
    for i in range(len(pts)-1):
        line(ax, pts[i,0], pts[i,1], pts[i+1,0], pts[i+1,1], color,
             lw=lw, z=z, ls=ls, alpha=alpha)
    if arrow:
        ang = np.arctan2(pts[-1,1]-pts[-2,1], pts[-1,0]-pts[-2,0])
        head(ax, pts[-1,0], pts[-1,1], ang, color, size=size, z=z+1)

def dot(ax, x, y, color, r=0.5, z=5):
    ax.add_patch(Circle((x, y), r, facecolor=color, edgecolor="none", zorder=z))

def module(ax, x, y, w, h, title, sub=None, accent=INK, fill=BLOCK,
           tsize=10.0, hbar=2.4, sub_color=INK_SOFT, sub_size=6.6, z=2,
           right=None):
    """Engineering block: ink header strip + paper title, optional sub-lines."""
    rect(ax, x, y, w, h, fill, ec=INK, lw=1.0, z=z)
    rect(ax, x, y+h-hbar, w, hbar, INK, z=z+0.1)                  # header strip
    rect(ax, x, y+h-hbar, 0.9, hbar, accent, z=z+0.2)            # accent index tab
    T(ax, x+2.2, y+h-hbar/2.0, title, f_label_b, tsize,
      color=PAPER, ha="left", va="center", z=z+3)
    if right:
        T(ax, x+w-2.0, y+h-hbar/2.0, right, f_micro, 6.0, color=PAPER,
          ha="right", va="center", z=z+3)
    if sub:
        yy = y + h - hbar - 2.5
        for ln in sub:
            T(ax, x+2.4, yy, ln, f_micro, sub_size, color=sub_color,
              ha="left", va="center", z=z+3)
            yy -= 2.55
    return (x, y, w, h)

def region(ax, x, y, w, h, title, accent, sub=None):
    """Outer container for a named region (Control / DataPath)."""
    rect(ax, x, y, w, h, accent, ec="none", lw=0, z=1.4, alpha=0.05)
    rect(ax, x, y, w, h, "none", ec=accent, lw=1.6, z=1.6)
    T(ax, x+1.4, y+h+2.2, title, f_label_b, 12.0, color=accent,
      ha="left", va="center")
    if sub:
        T(ax, x+w-0.6, y+h+2.2, sub, f_serif, 9.0, color=INK_SOFT,
          ha="right", va="center")
    for cx, cy, dx, dy in [(x,y,1.8,1.8),(x+w,y,-1.8,1.8),
                           (x,y+h,1.8,-1.8),(x+w,y+h,-1.8,-1.8)]:
        line(ax, cx, cy, cx+dx, cy, accent, lw=1.6, z=1.7)
        line(ax, cx, cy, cx, cy+dy, accent, lw=1.6, z=1.7)

def micro_grid(ax, x0, y0, x1, y1, step=4.0):
    xs = np.arange(np.ceil(x0/step)*step, x1, step)
    ys = np.arange(np.ceil(y0/step)*step, y1, step)
    for gx in xs:
        for gy in ys:
            ax.plot([gx], [gy], marker="+", ms=2.0, mew=0.45,
                    color=HAIR, alpha=0.32, zorder=0.5)

def frame_plate(ax, plate, title_lines, kicker, foot, foot_r):
    rect(ax, 0, 0, W, H, PAPER, z=0)
    micro_grid(ax, 10, 16, W-10, H-22, step=4.0)
    fx0, fy0, fx1, fy1 = 8, 9, W-8, H-9
    rect(ax, fx0, fy0, fx1-fx0, fy1-fy0, "none", ec=INK, lw=1.4, z=1)
    rect(ax, fx0+1.1, fy0+1.1, (fx1-fx0)-2.2, (fy1-fy0)-2.2, "none",
         ec=INK, lw=0.5, z=1)
    for cx, cy in [(fx0,fy0),(fx1,fy0),(fx0,fy1),(fx1,fy1)]:
        line(ax, cx-2.4, cy, cx+2.4, cy, INK, lw=0.7, z=1.2)
        line(ax, cx, cy-2.4, cx, cy+2.4, INK, lw=0.7, z=1.2)
        ax.add_patch(Circle((cx, cy), 1.5, facecolor="none", edgecolor=INK,
                     lw=0.6, zorder=1.2))
    tx = 13.5
    T(ax, tx, H-16.0, track("SILICON  MERIDIAN"), f_tag, 9.5, color=DATA,
      ha="left", va="center")
    line(ax, tx, H-19.0, W-13.5, H-19.0, INK, lw=0.7, z=2)
    if len(title_lines) == 1:
        T(ax, tx-0.6, H-26.5, title_lines[0], f_display, 33, color=INK,
          ha="left", va="center")
    else:
        T(ax, tx-0.6, H-25.0, title_lines[0], f_display, 31, color=INK,
          ha="left", va="center")
        T(ax, tx-0.6, H-33.8, title_lines[1], f_display, 31, color=INK,
          ha="left", va="center")
    T(ax, W-13.7, H-16.0, plate, f_tag, 9.5, color=INK_SOFT, ha="right",
      va="center")
    T(ax, W-13.7, H-23.0, kicker, f_serif, 11, color=INK_SOFT, ha="right",
      va="center")
    line(ax, 13.5, 17.5, W-13.5, 17.5, INK, lw=0.7, z=2)
    T(ax, 13.5, 14.3, foot, f_micro, 7.2, color=INK_SOFT, ha="left", va="center")
    T(ax, W-13.5, 14.3, foot_r, f_micro, 7.2, color=INK_SOFT, ha="right",
      va="center")

def legend_row(ax, x, y, items):
    cx = x
    for kind, color, lab in items:
        if kind == "data":
            parrow(ax, [(cx, y),(cx+5.0, y)], color, lw=1.8, size=1.5, z=4)
        elif kind == "ctrl":
            parrow(ax, [(cx, y),(cx+5.0, y)], color, lw=1.5, size=1.4,
                   ls=(0,(3,2)), z=4)
        elif kind == "reg":
            for k in range(3):
                line(ax, cx+k*1.6, y-1.2, cx+k*1.6, y+1.2, color, lw=1.4, z=4)
        T(ax, cx+6.2, y, lab, f_micro, 7.2, color=INK, ha="left", va="center")
        cx += 6.2 + 0.60*len(lab) + 5.4

def stage_ticks(ax, x, y, w, n, color, lab=None, z=4):
    xs = [x + w/2] if n <= 1 else np.linspace(x, x+w, n)
    for sx in xs:
        line(ax, sx, y-1.05, sx, y+1.05, color, lw=1.5, z=z)
    if lab:
        T(ax, x+w+1.7, y, lab, f_micro, 6.6, color=color, ha="left", va="center")


# ============================================================================ PLATE I
def plate_architecture():
    fig = plt.figure(figsize=(12, 15))
    ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, W); ax.set_ylim(0, H)
    ax.set_aspect("equal"); ax.axis("off")

    frame_plate(ax, "PLATE  I / II", ["CONFORMER", "ACCELERATOR"],
                "the structure — charted",
                "ARCHITECTURE  ·  CA  →  CA_Control  +  CA_DataPath",
                "CA.sv  ·  4-bit  ·  8×8  ·  PoT")

    # ---- CA die boundary ---------------------------------------------------
    dx, dy, dw, dh = 15, 20, 76, 88            # die top = 108
    rect(ax, dx, dy, dw, dh, INK, ec="none", z=1.42, alpha=0.025)
    rect(ax, dx, dy, dw, dh, "none", ec=INK, lw=1.9, z=1.5)
    T(ax, dx+2.0, 104.6, track("CA"), f_display, 16, color=INK, ha="left",
      va="center")
    T(ax, dx+10.5, 104.4, "conformer accelerator · top module", f_serif, 9.5,
      color=INK_SOFT, ha="left", va="center")

    # ---- PATTERN interface (left) -----------------------------------------
    pat_x = 9.4
    T(ax, pat_x+0.2, 79, track("PATTERN"), f_label_b, 7.6, color=INK_SOFT,
      ha="center", va="center", rot=90)
    for nm, yy in [("mem_set", 100), ("in_valid", 96), ("op / act", 92),
                   ("param[255:0]", 88)]:
        parrow(ax, [(pat_x+0.6, yy), (dx, yy)], CTRL, lw=1.2, size=1.1, z=3)
        T(ax, pat_x+0.9, yy+1.5, nm, f_micro, 6.0, color=INK_SOFT, ha="left",
          va="center")

    # ---- RAM (right) -------------------------------------------------------
    rx, ry, rw, rh = 100, 42, 9.6, 52
    module(ax, rx, ry, rw, rh, "RAM", accent=DATA,
           sub=["256×256", "neg-edge", "burst", "≤128 w", "", "rd 50c", "wr 5c"],
           sub_size=6.2, tsize=9.0)

    # ======================================================== CONTROL region
    cxx, cyy, cww, chh = 18.5, 24, 25, 80      # region top = 104
    region(ax, cxx, cyy, cww, chh, "CA_CONTROL", CTRL, sub="scheduler")

    sx, sy, sw, sh = cxx+2, cyy+58, cww-4, 20
    module(ax, sx, sy, sw, sh, "FSM · 5 STATE", accent=CTRL)
    states = [("IDLE",      sx+sw*0.50, sy+12.4),
              ("FAST_RUN",  sx+sw*0.23, sy+6.6),
              ("ATT_PARAM", sx+sw*0.80, sy+9.4),
              ("ATT_READ",  sx+sw*0.80, sy+4.8),
              ("ATT_WAIT",  sx+sw*0.50, sy+2.6)]
    pos = {n:(a,b) for n,a,b in states}
    for a,b in [("IDLE","FAST_RUN"),("IDLE","ATT_PARAM"),("ATT_PARAM","ATT_READ"),
                ("ATT_READ","ATT_WAIT"),("ATT_WAIT","ATT_READ")]:
        line(ax, pos[a][0],pos[a][1], pos[b][0],pos[b][1], CTRL, lw=0.8, z=3, alpha=0.7)
    for n,(a,b) in pos.items():
        dot(ax, a, b, CTRL, r=0.6, z=5)
        T(ax, a, b+1.4, n, f_micro, 5.3, color=INK, ha="center", va="center")

    module(ax, cxx+2, cyy+36, cww-4, 19, "READ SCHED", accent=CTRL,
           sub=["FAST → FFN / Conv", "ATT  → SHA / MHA",
                "burst 128 · 2 halves", "issue_valid / mode"])
    module(ax, cxx+2, cyy+15, cww-4, 18, "WRITEBACK", accent=CTRL,
           sub=["pre-result counter", "completion counter",
                "half toggle · skid", "FAST / ATT shared"])
    module(ax, cxx+2, cyy+2, cww-4, 10, "RAM CMD", accent=CTRL,
           sub=["rd_en · wr_en", "addr · burst = 128"])

    # ======================================================== DATAPATH region
    pxx, pyy, pww, phh = 50, 24, 38, 80
    region(ax, pxx, pyy, pww, phh, "CA_DATAPATH", DATA, sub="compute spine")

    scx, scy, scw, sch = pxx+2, pyy+34, pww-4, 44
    rect(ax, scx, scy, scw, sch, BLOCK, ec=INK, lw=1.1, z=2)
    rect(ax, scx, scy+sch-2.4, scw, 2.4, INK, z=2.1)
    rect(ax, scx, scy+sch-2.4, 0.9, 2.4, DATA, z=2.2)
    T(ax, scx+2.2, scy+sch-1.2, "ATT_STREAM_CORE", f_label_b, 9.0, color=PAPER,
      ha="left", va="center", z=5)
    T(ax, scx+scw-2.0, scy+sch-1.2, "shared MAC", f_micro, 6.0, color=PAPER,
      ha="right", va="center", z=5)

    sw2 = scw-4
    module(ax, scx+2, scy+sch-17, sw2, 12.5, "QKV_PROJ_QUANT", accent=DATA,
           fill=BLOCK_DP, tsize=8.4,
           sub=["src × {Wq,Wk,Wv} · 3 pipes", "FFN/Conv mult shares Q-pipe",
                "PoT quantise → 4-bit"])
    stage_ticks(ax, scx+2, scy+sch-18.7, sw2, 5, INK_SOFT, lab="×5")
    module(ax, scx+2, scy+sch-31.5, sw2, 11.5, "SCORE_8TAP", accent=DATA,
           fill=BLOCK_DP, tsize=8.4,
           sub=["64 lanes · Q·K^T dot", "MHA → head0 / head1",
                "act : x<0 → x>>2"])
    stage_ticks(ax, scx+2, scy+sch-33.2, sw2, 5, INK_SOFT, lab="×5")
    module(ax, scx+2, scy+2, sw2, 11.5, "FINAL_BOOTH_ACC", accent=DATA,
           fill=BLOCK_DP, tsize=8.4,
           sub=["64 Booth lanes · partial·V", "radix-4 partial products",
                "→ attention context"])
    stage_ticks(ax, scx+2, scy+0.3, sw2, 5, INK_SOFT, lab="×5")

    cmid = scx+2+sw2*0.5
    parrow(ax, [(cmid, scy+sch-17), (cmid, scy+sch-19.9)], DATA, lw=1.5, size=1.3, z=4)
    parrow(ax, [(cmid, scy+sch-31.5), (cmid, scy+13.5)], DATA, lw=1.5, size=1.3, z=4)

    module(ax, pxx+2, pyy+18, pww-4, 12, "ACT_5STAGE", accent=DATA, tsize=8.8,
           sub=["ReLU / RAT / CAT / BAT", "pair→psum→thresh→apply"])
    stage_ticks(ax, pxx+2, pyy+16.4, pww-4, 4, INK_SOFT, lab="×4")
    module(ax, pxx+2, pyy+2, pww-4, 12, "POT_5STAGE", accent=DATA, tsize=8.8,
           sub=["abs → Matrix_Max (OR→MSB)", "arith-shift + clamp → 4-bit"])
    stage_ticks(ax, pxx+2, pyy+0.4, pww-4, 3, INK_SOFT, lab="×3")

    spx = pxx+2+(pww-4)*0.5
    parrow(ax, [(spx, scy), (spx, pyy+30.0)], DATA, lw=2.0, size=1.7, z=4)
    parrow(ax, [(spx, pyy+18), (spx, pyy+14.0)], DATA, lw=2.0, size=1.7, z=4)

    # ---- memory data routing (right) --------------------------------------
    # rd_data : RAM -> stream core top (upper channel y=106)
    parrow(ax, [(rx, 84), (96, 84), (96, 106), (spx, 106), (spx, scy+sch)],
           DATA, lw=1.8, size=1.6, z=3.2)
    T(ax, 90.5, 107.4, "rd_data", f_micro, 6.2, color=DATA, ha="right", va="center")
    # wr_data : PoT -> RAM
    pot_r = pxx+2+(pww-4)
    parrow(ax, [(pot_r, pyy+8), (94, pyy+8), (94, ry+8), (rx, ry+8)],
           DATA, lw=1.8, size=1.6, z=3.2)
    T(ax, 90.5, pyy+9.6, "wr_data", f_micro, 6.2, color=DATA, ha="right", va="center")
    # out_data : PoT -> PATTERN (last token, gold)
    parrow(ax, [(spx, pyy+2), (spx, pyy-1.0), (dx, pyy-1.0)],
           GOLD, lw=1.6, size=1.4, z=3.4)
    parrow(ax, [(dx, pyy-1.0), (pat_x+0.6, pyy-1.0)], GOLD, lw=1.6, size=1.3, z=3.4)
    T(ax, pat_x+0.9, pyy+0.6, "out_valid", f_micro, 6.0, color=GOLD, ha="left", va="center")
    T(ax, 44, pyy-2.7, "out_data[31:0]  ·  last token", f_micro, 6.0, color=GOLD,
      ha="left", va="center")

    # ---- control routing ---------------------------------------------------
    # issue_valid / mode : control -> stream core
    parrow(ax, [(cxx+cww, scy+30), (scx, scy+30)], CTRL, lw=1.3, size=1.3,
           ls=(0,(3,2)), z=3.3)
    T(ax, (cxx+cww+scx)/2, scy+31.6, "issue", f_micro, 6.0, color=CTRL,
      ha="center", va="center")
    # rd_en / wr_en : control -> RAM (top channel y=107)
    parrow(ax, [(cxx+cww, 102), (45.5, 107), (98, 107), (98, ry+rh)],
           CTRL, lw=1.2, size=1.3, ls=(0,(3,2)), z=3.1)
    T(ax, 70, 108.4, "rd_en / wr_en · addr / burst", f_micro, 6.0, color=CTRL,
      ha="center", va="center")
    # tag rail note
    T(ax, pot_r+1.4, pyy+26, "tag", f_micro, 6.0, color=INK_SOFT, ha="left", va="center")
    T(ax, pot_r+1.4, pyy+23.4, "DT_NORM", f_micro, 5.6, color=INK_SOFT, ha="left", va="center")
    T(ax, pot_r+1.4, pyy+21.2, "DT_ATT", f_micro, 5.6, color=INK_SOFT, ha="left", va="center")

    legend_row(ax, 14, 15.5,
        [("data", DATA, "data payload"), ("ctrl", CTRL, "control / handshake"),
         ("data", GOLD, "last token"), ("reg", INK_SOFT, "pipeline registers")])

    fig.savefig(os.path.join(OUT_DIR, "plate1_architecture.png"), dpi=200,
                facecolor=PAPER)
    return fig


# ============================================================================ PLATE II
def plate_dataflow():
    fig = plt.figure(figsize=(12, 15))
    ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, W); ax.set_ylim(0, H)
    ax.set_aspect("equal"); ax.axis("off")

    frame_plate(ax, "PLATE  II / II", ["DATA FLOW"],
                "the journey of one matrix",
                "DATAFLOW  ·  one 8×8 matrix  ·  read → compute → quantise → write",
                "shared silicon · two op-classes")

    top_m, bot_m, mx = 120.0, 24.0, 16.5
    midx = 60.0

    # ---- depth meridian (left dyadic scale) --------------------------------
    line(ax, mx, bot_m, mx, top_m, INK, lw=1.1, z=2)
    T(ax, mx, top_m+2.6, track("DEPTH"), f_label_b, 7.2, color=INK_SOFT,
      ha="center", va="center")
    for val, frac in [(1,0.0),(2,0.12),(4,0.27),(8,0.46),(16,0.70),(24,0.93)]:
        yy = top_m - frac*(top_m-bot_m)
        line(ax, mx-1.6, yy, mx+1.6, yy, INK, lw=0.9, z=2)
        T(ax, mx-2.8, yy, str(val), f_micro, 6.4, color=INK, ha="right", va="center")
    for k in range(0, 41):
        yy = top_m - (k/40.0)*(top_m-bot_m)
        line(ax, mx-0.7, yy, mx+0.7, yy, HAIR, lw=0.5, z=1.6, alpha=0.6)
    T(ax, mx, bot_m-2.4, "cycles", f_micro, 6.2, color=INK_SOFT, ha="center", va="center")

    def band(x, y, w, h, title, sub, stages, fill=BLOCK, tsize=9.0, lab=None,
             accent=DATA):
        module(ax, x, y, w, h, title, sub=sub, accent=accent, fill=fill,
               tsize=tsize, sub_size=6.4)
        if stages:
            stage_ticks(ax, x+2, y-1.5, w-4, stages, INK_SOFT,
                        lab=lab if lab else f"×{stages}")

    # ---- RAM SOURCE --------------------------------------------------------
    band(30, 112, 60, 7.5, "RAM · READ BURST",
         ["address 0…255 · burst ≤ 128 words · negative-edge"], 0)
    line(ax, 30, 109.0, 90, 109.0, HAIR, lw=0.8, z=1.8, ls=(0,(2,2)))
    T(ax, 30, 107.2, "50-cycle read horizon — compute of the prior matrix hides the latency",
      f_serif, 8.0, color=INK_SOFT, ha="left", va="center")

    forky = 104.0
    parrow(ax, [(midx, 112), (midx, forky)], DATA, lw=2.0, size=1.5, z=3)
    parrow(ax, [(midx, forky), (44, forky), (44, 94.2)], DATA, lw=1.7, size=1.4, z=3)
    parrow(ax, [(midx, forky), (81, forky), (81, 103.2)], DATA, lw=1.7, size=1.4, z=3)
    T(ax, 44, forky+1.7, "DT_NORM", f_micro, 6.0, color=INK_SOFT, ha="center", va="center")
    T(ax, 81, forky+1.7, "DT_ATT", f_micro, 6.0, color=DATA, ha="center", va="center")

    # ---- NORM current (left) ----------------------------------------------
    band(31, 80, 26, 14, "MULTIPLY",
         ["FFN  y = Wx", "Conv 3×3 · pad 1", "shared Q-pipe MAC"], 5, tsize=8.8)
    T(ax, 44, 78.0, "FFN / Conv", f_micro, 6.4, color=INK_SOFT, ha="center", va="center")

    # ---- ATT current (right) : qkv -> score -> final ----------------------
    band(63, 91, 36, 12, "QKV PROJ + QUANT",
         ["Q,K,V = src × W", "PoT quantise → 4-bit"], 5, tsize=8.6)
    parrow(ax, [(81, 91), (81, 88.5)], DATA, lw=1.6, size=1.3, z=3)
    band(63, 76, 36, 12, "SCORE  Q·K^T",
         ["64 lanes · 8-tap dot", "MHA head0 / head1", "act : x<0 → x>>2"], 5, tsize=8.6)
    parrow(ax, [(81, 76), (81, 73.5)], DATA, lw=1.6, size=1.3, z=3)
    band(63, 61, 36, 12, "FINAL · V  (BOOTH)",
         ["64 Booth lanes", "score · V → context"], 5, tsize=8.6)

    # ---- merge into ACT ----------------------------------------------------
    merge_y = 56.0
    parrow(ax, [(44, 78.0-1.6), (44, merge_y), (midx, merge_y)], DATA, lw=1.7, size=1.4, z=3)
    parrow(ax, [(81, 61), (81, merge_y), (midx, merge_y)], DATA, lw=1.7, size=1.4, z=3)
    parrow(ax, [(midx, merge_y), (midx, 53.0)], DATA, lw=2.0, size=1.5, z=3)

    band(30, 43, 60, 10, "ACTIVATION",
         ["ReLU · RAT (row) · CAT (col) · BAT (4×4 block)  —  thr = mean,  v<thr → v>>3"],
         4, tsize=9.0)
    parrow(ax, [(midx, 43), (midx, 39.0)], DATA, lw=2.0, size=1.5, z=3)
    band(30, 29, 60, 10, "PoT  QUANTISE",
         ["max_abs → MSB → shift = msb−2 · arith-shift + clamp → signed 4-bit"],
         3, tsize=9.0)
    parrow(ax, [(midx, 29), (midx, 25.0)], DATA, lw=2.0, size=1.5, z=3)
    band(30, 17, 60, 8, "RAM · WRITE BURST",
         ["store result to original address · burst ≤ 128 · skid-buffered"], 0, tsize=9.0)

    # ---- last token tap (gold) --------------------------------------------
    parrow(ax, [(90, 33.5), (92.5, 33.5)], GOLD, lw=1.5, size=1.3, z=4)
    module(ax, 92.5, 29.6, 15.5, 7.8, "LAST TOKEN", accent=GOLD, tsize=7.6,
           sub=["out_data[31:0]", "8 × signed 4-bit"], sub_size=6.0)

    # ---- recirculation loop (right) ---------------------------------------
    parrow(ax, [(90, 21), (104, 21), (104, 115.7), (90, 115.7)],
           CTRL, lw=1.2, size=1.3, ls=(0,(3,2)), z=3)
    T(ax, 106.2, 68, track("× 256  MATRICES"), f_label_b, 6.8, color=CTRL,
      ha="center", va="center", rot=90)

    legend_row(ax, 14, 11.4,
        [("data", DATA, "data payload"), ("ctrl", CTRL, "loop / control"),
         ("data", GOLD, "last token"), ("reg", INK_SOFT, "× N pipeline depth")])

    fig.savefig(os.path.join(OUT_DIR, "plate2_dataflow.png"), dpi=200,
                facecolor=PAPER)
    return fig


# ============================================================================ main
def main():
    f1 = plate_architecture()
    f2 = plate_dataflow()
    pdf_path = os.path.join(OUT_DIR, "silicon-meridian.pdf")
    with PdfPages(pdf_path) as pdf:
        pdf.savefig(f1, facecolor=PAPER)
        pdf.savefig(f2, facecolor=PAPER)
    plt.close("all")
    print("wrote:", pdf_path)

if __name__ == "__main__":
    main()
