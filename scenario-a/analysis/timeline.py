#!/usr/bin/env python3
"""Export the observability timeline from Prometheus (query_range API) and plot it.

Reads  results/timeline/phases.csv (written by scripts/07_timeline.sh)
Writes data/timeline_prometheus.csv, results/timeline/phase_summary.md, figures/fig9_timeline.png
"""
import os

import numpy as np
import pandas as pd
import requests
import matplotlib.pyplot as plt

import plotstyle as ps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROM = os.environ.get("PROM_URL", "http://127.0.0.1:9090")

QUERIES = {
    "throughput_up_mbps": 'rate(scena_iface_tx_bytes_total{ns="ue",iface="ue-eth0"}[3s]) * 8 / 1e6',
    "rtt_ms": "scena_probe_rtt_ms",
    "icmp_lost_10s": "increase(scena_probe_icmp_lost_total[10s])",
    "tcp_retrans_per_s": 'rate(scena_tcp_retrans_segs_total{endpoint="ue"}[3s])',
    "qdisc_drops_per_s": "sum(rate(scena_qdisc_drops_total[3s]))",
    "http_total_ms": 'scena_probe_http_seconds{phase="total"} * 1000',
    "http_up": "scena_probe_http_up",
    "added_rtt_ms": "sum(scena_impair_delay_ms)",
    "loss_percent": "max(scena_impair_loss_percent)",
    "rate_limit_mbit": "max(scena_impair_rate_mbit)",
}


def query_range(expr, start, end, step=1):
    r = requests.get(f"{PROM}/api/v1/query_range",
                     params={"query": expr, "start": start, "end": end, "step": step}, timeout=30)
    r.raise_for_status()
    res = r.json()["data"]["result"]
    if not res:
        return pd.Series(dtype=float)
    v = res[0]["values"]
    return pd.Series([float(x[1]) for x in v], index=[float(x[0]) for x in v])


def main():
    ps.apply()
    phases = pd.read_csv(os.path.join(ROOT, "results", "timeline", "phases.csv"), keep_default_na=False)
    t0 = phases.start_epoch.min()
    start, end = t0 - 5, phases.end_epoch.max() + 5

    df = pd.DataFrame({k: query_range(q, start, end) for k, q in QUERIES.items()})
    df.index.name = "epoch"
    df["t"] = df.index - t0
    df.to_csv(os.path.join(ROOT, "data", "timeline_prometheus.csv"))

    # per-phase summary (skip the first 5 s of each phase = transition)
    rows = []
    for _, p in phases.iterrows():
        d = df[(df.index >= p.start_epoch + 5) & (df.index < p.end_epoch)]
        rows.append({
            "phase": p.phase, "impairment": f"{p.link} {p.spec}".strip() if p.link != "none" else "none",
            "TCP up median [Mbit/s]": round(d.throughput_up_mbps.median(), 1),
            "RTT median [ms]": round(d.rtt_ms.median(), 2),
            "ICMP probes lost": int(round(d.icmp_lost_10s.diff().clip(lower=0).sum())),
            "TCP retrans/s (mean)": round(d.tcp_retrans_per_s.mean(), 1),
            "qdisc drops/s (mean)": round(d.qdisc_drops_per_s.mean(), 1),
            "HTTP median [ms]": round(d.http_total_ms.median(), 2),
            "HTTP availability [%]": round(100 * d.http_up.mean(), 1),
        })
    summ = pd.DataFrame(rows)
    with open(os.path.join(ROOT, "results", "timeline", "phase_summary.md"), "w", encoding="utf-8") as f:
        f.write(summ.to_markdown(index=False))
    print(summ.to_string(index=False))

    panels = [("throughput_up_mbps", "TCP upload at UE [Mbit/s]", True),
              ("rtt_ms", "ICMP RTT probe [ms]", True),
              ("tcp_retrans_per_s", "UE TCP retransmissions [seg/s]", True),
              ("http_total_ms", "HTTP probe response [ms]", True)]
    fig, axes = plt.subplots(len(panels), 1, figsize=(11, 9), sharex=True)
    for ax, (col, label, log) in zip(axes, panels):
        y = df[col].replace([np.inf, -np.inf], np.nan)
        if log:
            y = y.where(y > 0)
        ax.plot(df.t, y, color=ps.SERIES[0], linewidth=1.4)
        if log:
            ax.set_yscale("log")
        ax.set_ylabel(label, fontsize=9)
        if col == "http_total_ms":
            fail = df[df.http_up == 0]
            if len(fail):
                top = np.nanmax(y) if np.isfinite(np.nanmax(y)) else 1
                ax.scatter(fail.t, [top] * len(fail), marker="x", color=ps.CRITICAL, s=18,
                           label="HTTP probe failed", zorder=3)
                ax.legend(loc="upper left", fontsize=8)
        for _, p in phases.iterrows():
            if p.link != "none":
                ax.axvspan(p.start_epoch - t0, p.end_epoch - t0, color="#f0efec", zorder=0)
    for _, p in phases.iterrows():
        if p.link != "none":
            axes[0].annotate(p.phase, ((p.start_epoch + p.end_epoch) / 2 - t0, 1.02),
                             xycoords=("data", "axes fraction"), ha="center", fontsize=8, color=ps.INK_2)
    axes[-1].set_xlabel("time since start of the run [s]   (shaded = impairment active on the access-core link)")
    fig.suptitle("Fig. 9 - Observability timeline from Prometheus (1 s scrape): condition → transport → application",
                 x=0.01, ha="left", fontsize=11, fontweight="bold", color=ps.INK)
    fig.tight_layout()
    fig.savefig(os.path.join(ROOT, "figures", "fig9_timeline.png"))
    print("timeline written")


if __name__ == "__main__":
    main()
