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
    "C1_delay50_n3": "C1 +50 ms RTT\n(N3 gNB-UPF)",
    "C2_delay50_n6": "C2 +50 ms RTT\n(N6 UPF-DN)",
    "C3_loss1_n3": "C3 1 % loss\n(N3)",
    "C4_loss1_n6": "C4 1 % loss\n(N6)",
    "C5_rate20_n3": "C5 20 Mbit/s\n(N3)",
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
