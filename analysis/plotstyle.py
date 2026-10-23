"""Shared Matplotlib style for all figures (light surface, recessive grid, fixed categorical order)."""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
# categorical slots, always assigned in this order
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
CRITICAL = "#d03b3b"

LABELS = {
    "C0_baseline": "C0 baseline",
    "C1_delay50": "C1 +50 ms RTT\n(access-core)",
    "C2_loss1": "C2 1 % loss\n(access-core)",
    "C3_rate20": "C3 20 Mbit/s\n(access-core)",
    "C4_delay50_loss1": "C4 +50 ms & 1 %\n(access-core)",
    "C5_delay50_dn": "C5 +50 ms RTT\n(core-DN)",
    "C6_loss1_dn": "C6 1 % loss\n(core-DN)",
}
SHORT = {k: v.split("\n")[0] for k, v in LABELS.items()}
COND_COLOR = {c: SERIES[i] for i, c in enumerate(LABELS)}


def apply():
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "font.family": "sans-serif", "font.size": 10,
        "axes.edgecolor": AXIS, "axes.labelcolor": INK_2, "axes.titlecolor": INK,
        "axes.titlesize": 11, "axes.titleweight": "bold", "axes.titlelocation": "left",
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
        "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": INK_2, "ytick.labelcolor": INK_2,
        "legend.frameon": False, "legend.labelcolor": INK_2,
        "lines.linewidth": 2, "lines.markersize": 6,
        "figure.dpi": 110, "savefig.dpi": 150, "savefig.bbox": "tight",
    })
