#!/usr/bin/env python3
"""Statistical summary + figures for the Step 3 experiments (reads data/*.csv from parse_results.py).

Outputs:
  data/summary.csv                 mean / std / CV per condition and metric
  results/summary_table.md         comparison table used in the README
  results/model_check.md           TCP throughput vs. the Mathis et al. loss model
  figures/fig1..fig7_*.png
"""
import os

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import plotstyle as ps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATA = os.path.join(ROOT, "data")
FIG = os.path.join(ROOT, "figures")
RES = os.path.join(ROOT, "results")

ps.apply()
os.makedirs(FIG, exist_ok=True)

m = pd.read_csv(os.path.join(DATA, "measurements.csv"))
pings = pd.read_csv(os.path.join(DATA, "ping_samples.csv"))
http = pd.read_csv(os.path.join(DATA, "http_requests.csv"))
ivl = pd.read_csv(os.path.join(DATA, "iperf_intervals.csv"))
ev_path = os.path.join(DATA, "step3_packet_evidence.csv")
ev = pd.read_csv(ev_path) if os.path.exists(ev_path) else pd.DataFrame()

CONDS = [c for c in ps.LABELS if c in set(m.condition)]

# ------------------------------------------------------------------ summary statistics
g = m.groupby(["condition", "metric"])["value"]
summary = g.agg(["mean", "std", "min", "max", "count"]).reset_index()
summary["cv_percent"] = 100 * summary["std"] / summary["mean"].abs()
summary.to_csv(os.path.join(DATA, "summary.csv"), index=False)


def val(cond, metric, stat="mean"):
    r = summary[(summary.condition == cond) & (summary.metric == metric)]
    return float(r[stat].iloc[0]) if len(r) else float("nan")


def fmt(cond, metric, digits=2):
    mu, sd = val(cond, metric), val(cond, metric, "std")
    if np.isnan(mu):
        return "-"
    return f"{mu:.{digits}f} ± {sd:.{digits}f}"


COLUMNS = [
    ("RTT avg [ms]", "rtt_avg_ms", 2),
    ("ICMP loss [%]", "icmp_loss_percent", 1),
    ("TCP up [Mbit/s]", "tcp_up_mbps", 1),
    ("TCP up retr. [/10 s]", "tcp_up_retrans", 0),
    ("TCP up sRTT [ms]", "tcp_up_srtt_ms", 2),
    ("TCP down [Mbit/s]", "tcp_down_mbps", 1),
    ("TCP down retr. [/10 s]", "tcp_down_retrans", 0),
    ("UDP rx @30M [Mbit/s]", "udp_received_mbps", 2),
    ("UDP loss [%]", "udp_loss_percent", 2),
    ("UDP jitter [ms]", "udp_jitter_ms", 3),
    ("HTTP median [ms]", "http_total_median_ms", 2),
    ("HTTP p95 [ms]", "http_total_p95_ms", 2),
    ("HTTP success [%]", "http_success_percent", 1),
    ("TCP connect median [ms]", "http_connect_median_ms", 2),
    ("1 MiB transfer median [ms]", "http1m_total_median_ms", 1),
]

with open(os.path.join(RES, "summary_table.md"), "w", encoding="utf-8") as f:
    f.write("Mean ± standard deviation over 3 repetitions per condition.\n\n")
    # transposed table: metrics as rows, conditions as columns (fits a README better)
    f.write("| Metric | " + " | ".join(ps.SHORT[c] for c in CONDS) + " |\n")
    f.write("|---|" + "---:|" * len(CONDS) + "\n")
    for title, metric, d in COLUMNS:
        f.write(f"| {title} | " + " | ".join(fmt(c, metric, d) for c in CONDS) + " |\n")

    f.write("\n**Baseline stability (coefficient of variation between repetitions)**\n\n")
    f.write("| Metric | mean | std | CV |\n|---|---:|---:|---:|\n")
    for title, metric, d in COLUMNS:
        r = summary[(summary.condition == "C0_baseline") & (summary.metric == metric)]
        if len(r):
            r = r.iloc[0]
            f.write(f"| {title} | {r['mean']:.{d}f} | {r['std']:.{d}f} | {r['cv_percent']:.1f} % |\n")

# ------------------------------------------------------------------ model check (Mathis et al. 1997)
MSS = 1448 * 8  # bits
with open(os.path.join(RES, "model_check.md"), "w", encoding="utf-8") as f:
    f.write("| Condition | loss p (per direction) | measured sRTT [ms] | Mathis bound MSS/RTT·1.22/√p [Mbit/s] | measured TCP up [Mbit/s] |\n")
    f.write("|---|---:|---:|---:|---:|\n")
    for c, p in (("C2_loss1", 0.01), ("C4_delay50_loss1", 0.01), ("C6_loss1_dn", 0.01)):
        rtt = val(c, "tcp_up_srtt_ms") / 1000
        bound = MSS / rtt * 1.22 / np.sqrt(p) / 1e6 if rtt > 0 else float("nan")
        f.write(f"| {ps.SHORT[c]} | {p} | {rtt*1000:.2f} | {bound:,.1f} | {val(c, 'tcp_up_mbps'):,.1f} |\n")

# ------------------------------------------------------------------ fig 1: RTT distribution
fig, ax = plt.subplots(figsize=(10, 4.2))
data = [pings[pings.condition == c].rtt_ms.values for c in CONDS]
bp = ax.boxplot(data, widths=0.5, patch_artist=True, showfliers=True,
                medianprops=dict(color=ps.INK, linewidth=1.5),
                flierprops=dict(marker="o", markersize=3, markerfacecolor=ps.MUTED, markeredgewidth=0),
                boxprops=dict(linewidth=1, color=ps.SERIES[0]), whiskerprops=dict(color=ps.AXIS),
                capprops=dict(color=ps.AXIS))
for b in bp["boxes"]:
    b.set_facecolor("#cde2fb")
ax.set_yscale("log")
ax.set_xticks(range(1, len(CONDS) + 1), [ps.LABELS[c] for c in CONDS], fontsize=8.5)
ax.set_ylabel("ICMP RTT UE → Nginx [ms] (log)")
ax.set_title("Fig. 1 - Round-trip time per condition (3 × 30 echo requests)")
for i, c in enumerate(CONDS, start=1):
    med = np.median(pings[pings.condition == c].rtt_ms)
    ax.annotate(f"median\n{med:.2f} ms", (i + 0.3, med), va="center", fontsize=7.5, color=ps.INK_2)
fig.savefig(os.path.join(FIG, "fig1_rtt.png"))
plt.close(fig)


# ------------------------------------------------------------------ helpers for grouped bars
def grouped(ax, metrics, names, ylog=False, digits=0):
    x = np.arange(len(CONDS))
    w = 0.8 / len(metrics)
    for i, (met, name) in enumerate(zip(metrics, names)):
        mu = [val(c, met) for c in CONDS]
        sd = [val(c, met, "std") for c in CONDS]
        bars = ax.bar(x + (i - (len(metrics) - 1) / 2) * w, mu, w - 0.03, yerr=sd, label=name,
                      color=ps.SERIES[i], ecolor=ps.INK_2, capsize=2, error_kw=dict(linewidth=0.8))
        for b, v, s in zip(bars, mu, sd):
            if not np.isnan(v):
                d = digits if v >= 10 else 1
                ax.annotate(f"{v:,.{d}f}", (b.get_x() + b.get_width() / 2, v + (s if s == s else 0)),
                            xytext=(0, 3), textcoords="offset points", ha="center", fontsize=7, color=ps.INK_2)
    ax.set_xticks(x, [ps.LABELS[c] for c in CONDS], fontsize=8.5)
    if ylog:
        ax.set_yscale("log")
    ax.legend(loc="upper right")


fig, ax = plt.subplots(figsize=(10, 4.4))
grouped(ax, ["tcp_up_mbps", "tcp_down_mbps"], ["upload UE → server", "download server → UE"], ylog=True)
ax.set_ylabel("iperf3 TCP throughput [Mbit/s] (log)")
ax.set_title("Fig. 2 - TCP throughput (mean ± std of 3 × 10 s)")
fig.savefig(os.path.join(FIG, "fig2_tcp_throughput.png"))
plt.close(fig)

fig, ax = plt.subplots(figsize=(10, 4.4))
grouped(ax, ["tcp_up_retrans", "tcp_down_retrans"], ["upload", "download"], ylog=True)
ax.set_ylabel("retransmitted segments per 10 s test (log)")
ax.set_title("Fig. 3 - TCP retransmissions reported by the sender (iperf3)")
fig.savefig(os.path.join(FIG, "fig3_tcp_retransmissions.png"))
plt.close(fig)

# ------------------------------------------------------------------ fig 4: UDP small multiples
fig, axes = plt.subplots(1, 3, figsize=(12, 3.8))
x = np.arange(len(CONDS))
for ax, (met, title, d) in zip(axes, [("udp_received_mbps", "received bit-rate [Mbit/s] (dashed = offered)", 1),
                                       ("udp_loss_percent", "datagram loss [%]", 1),
                                       ("udp_jitter_ms", "jitter [ms]", 3)]):
    mu = [val(c, met) for c in CONDS]
    sd = [val(c, met, "std") for c in CONDS]
    bars = ax.bar(x, mu, 0.6, yerr=sd, color=ps.SERIES[0], ecolor=ps.INK_2, capsize=2,
                  error_kw=dict(linewidth=0.8))
    for b, v in zip(bars, mu):
        ax.annotate(f"{v:.{d}f}", (b.get_x() + b.get_width() / 2, v), xytext=(0, 3),
                    textcoords="offset points", ha="center", fontsize=7, color=ps.INK_2)
    ax.set_xticks(x, [ps.SHORT[c].split(" ")[0] for c in CONDS])
    ax.set_title(title, fontsize=10)
    if met == "udp_received_mbps":
        ax.axhline(30, color=ps.MUTED, linestyle="--", linewidth=1)
        ax.set_ylim(0, 34)
fig.suptitle("Fig. 4 - iperf3 UDP at a fixed offered rate of 30 Mbit/s (mean ± std, 3 × 10 s)",
             x=0.01, ha="left", fontsize=11, fontweight="bold", color=ps.INK)
fig.tight_layout()
fig.savefig(os.path.join(FIG, "fig4_udp.png"))
plt.close(fig)

# ------------------------------------------------------------------ fig 5: HTTP response time CDF
fig, ax = plt.subplots(figsize=(10, 4.4))
small = http[(http.object == "small") & (http.exit == 0) & (http.code == 200)]
for c in CONDS:
    v = np.sort(small[small.condition == c].t_total.values * 1000)
    if len(v):
        ax.step(v, np.arange(1, len(v) + 1) / len(v), where="post", color=ps.COND_COLOR[c],
                label=ps.SHORT[c], linewidth=1.8)
ax.set_xscale("log")
ax.set_xlabel("HTTP response time (curl time_total, new TCP connection) [ms] (log)")
ax.set_ylabel("fraction of requests")
ax.set_title("Fig. 5 - Application response time, CDF of 150 requests per condition")
ax.legend(loc="lower right", fontsize=8.5)
fig.savefig(os.path.join(FIG, "fig5_http_cdf.png"))
plt.close(fig)

# ------------------------------------------------------------------ fig 6: impairment location
pairs = [("+50 ms RTT", "C1_delay50", "C5_delay50_dn"), ("1 % loss", "C2_loss1", "C6_loss1_dn")]
mets = [("rtt_avg_ms", "RTT avg [ms]"), ("tcp_up_mbps", "TCP up [Mbit/s]"),
        ("tcp_down_mbps", "TCP down [Mbit/s]"), ("http_total_median_ms", "HTTP median [ms]")]
if all(c in CONDS for _, a, b in pairs for c in (a, b)):
    fig, axes = plt.subplots(1, 4, figsize=(13, 3.6))
    for ax, (met, title) in zip(axes, mets):
        xx = np.arange(len(pairs))
        for i, (loc, idx) in enumerate((("access-core link", 1), ("core-DN link", 2))):
            mu = [val(p[idx], met) for p in pairs]
            sd = [val(p[idx], met, "std") for p in pairs]
            ax.bar(xx + (i - 0.5) * 0.38, mu, 0.36, yerr=sd, color=ps.SERIES[i], label=loc,
                   ecolor=ps.INK_2, capsize=2, error_kw=dict(linewidth=0.8))
        ax.set_xticks(xx, [p[0] for p in pairs])
        ax.set_title(title, fontsize=10)
    axes[0].legend(loc="upper right", fontsize=8)
    fig.suptitle("Fig. 6 - Same impairment applied on two different links of the path",
                 x=0.01, ha="left", fontsize=11, fontweight="bold", color=ps.INK)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "fig6_location.png"))
    plt.close(fig)

# ------------------------------------------------------------------ fig 7: per-second TCP upload
fig, ax = plt.subplots(figsize=(10, 4.2))
up = ivl[(ivl.test == "tcp_up") & (ivl.rep == 1)]
for c in CONDS:
    d = up[up.condition == c]
    ax.plot(d.t, d.mbps, color=ps.COND_COLOR[c], label=ps.SHORT[c], marker="o", markersize=3, linewidth=1.6)
ax.set_yscale("log")
ax.set_xlabel("time in test [s]")
ax.set_ylabel("throughput per 1 s interval [Mbit/s] (log)")
ax.set_title("Fig. 7 - TCP upload, per-second throughput (repetition 1)")
ax.legend(loc="lower right", fontsize=8, ncol=2)
fig.savefig(os.path.join(FIG, "fig7_tcp_intervals.png"))
plt.close(fig)

# ------------------------------------------------------------------ packet evidence table
if len(ev):
    with open(os.path.join(RES, "packet_evidence_table.md"), "w", encoding="utf-8") as f:
        f.write("3 s iperf3 TCP flow paced at 50 Mbit/s, captured at P1 (UE, ue-eth0) and P4 (Docker bridge br-dn).\n\n")
        f.write("| Condition | P1 data segs | P4 data segs | lost on path (P1-P4) | retransmissions (P1) "
                "| dup ACKs (P1) | mean ACK RTT at UE [ms] |\n|---|---:|---:|---:|---:|---:|---:|\n")
        for c in CONDS:
            p1 = ev[(ev.condition == c) & (ev.point == "P1")]
            p4 = ev[(ev.condition == c) & (ev.point == "P4")]
            if not len(p1) or not len(p4):
                continue
            p1, p4 = p1.iloc[0], p4.iloc[0]
            f.write(f"| {ps.SHORT[c]} | {p1.data_segments_to_server} | {p4.data_segments_to_server} | "
                    f"{p1.data_segments_to_server - p4.data_segments_to_server} | {p1.retransmissions} | "
                    f"{p1.duplicate_acks} | {p1.mean_ack_rtt_ms:.2f} |\n")

print("summary + figures written")
