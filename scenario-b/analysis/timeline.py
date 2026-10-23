#!/usr/bin/env python3
"""Scenario B - export the observability timeline from Prometheus (query_range API) and plot it.

Reads  results/timeline/phases.csv (scripts/07_timeline.sh)
Writes data/timeline_prometheus.csv, results/timeline/phase_summary.md, figures/fig9_timeline.png
"""
import os

import numpy as np
import pandas as pd
import requests
import matplotlib.pyplot as plt

import plotstyle as ps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PROM = os.environ.get("PROM_URL", "http://127.0.0.1:9091")

QUERIES = {
    "ue_tun_up_mbps": 'rate(scenb_port_tx_bytes_total{port="ue_tun"}[3s]) * 8 / 1e6',
    "n3_up_mbps": 'rate(scenb_port_rx_bytes_total{port="upf_n3"}[3s]) * 8 / 1e6',
    "n6_up_mbps": 'rate(scenb_port_tx_bytes_total{port="upf_n6"}[3s]) * 8 / 1e6',
    "rtt_ms": "scenb_probe_rtt_ms",
    "icmp_lost_10s": "increase(scenb_probe_icmp_lost_total[10s])",
    "tcp_retrans_per_s": "rate(scenb_ue_tcp_retrans_segs_total[3s])",
    "qdisc_drops_n3": 'sum(rate(scenb_qdisc_drops_total{port=~"gnb_n3|upf_n3"}[3s]))',
    "qdisc_drops_n6": 'sum(rate(scenb_qdisc_drops_total{port="upf_n6"}[3s]))',
    "http_total_ms": 'scenb_probe_http_seconds{phase="total"} * 1000',
    "http_up": "scenb_probe_http_up",
    "pdu_up": "scenb_pdu_session_up",
    "smf_pfcp_sessions": 'pfcp_sessions_active{nf="smf"}',
    "upf_sessions": 'fivegs_upffunction_upf_sessionnbr{nf="upf"}',
    "amf_ran_ue": 'ran_ue{nf="amf"}',
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
    df = pd.DataFrame({k: query_range(q, t0 - 5, phases.end_epoch.max() + 5) for k, q in QUERIES.items()})
    df.index.name = "epoch"
    df["t"] = df.index - t0
    df.to_csv(os.path.join(ROOT, "data", "timeline_prometheus.csv"))

    rows = []
    for _, p in phases.iterrows():
        d = df[(df.index >= p.start_epoch + 5) & (df.index < p.end_epoch)]
        rows.append({
            "phase": p.phase, "impairment": f"{p.link} {p.spec}" if p.link != "none" else "none",
            "UE up median [Mbit/s]": round(d.ue_tun_up_mbps.median(), 1),
            "N3/N6 byte ratio": round((d.n3_up_mbps / d.n6_up_mbps).median(), 3),
            "RTT median [ms]": round(d.rtt_ms.median(), 2),
            "UE retrans/s": round(d.tcp_retrans_per_s.mean(), 1),
            "drops/s N3": round(d.qdisc_drops_n3.mean(), 1),
            "drops/s N6": round(d.qdisc_drops_n6.mean(), 1),
            "HTTP median [ms]": round(d.http_total_ms.median(), 2),
            "HTTP availability [%]": round(100 * d.http_up.mean(), 1),
            # session state from the 5G core itself (authoritative); the exporter's uesimtun0 check
            # can time out under full CPU load and is therefore not used here
            "UPF sessions (min)": int(d.upf_sessions.min()),
            "SMF PFCP sessions (min)": int(d.smf_pfcp_sessions.min()),
        })
    summ = pd.DataFrame(rows)
    with open(os.path.join(ROOT, "results", "timeline", "phase_summary.md"), "w", encoding="utf-8") as f:
        f.write(summ.to_markdown(index=False))
    print(summ.to_string(index=False))

    panels = [("ue_tun_up_mbps", "TCP upload at UE [Mbit/s]"), ("rtt_ms", "ICMP RTT probe [ms]"),
              ("tcp_retrans_per_s", "UE TCP retrans [seg/s]"), ("http_total_ms", "HTTP probe [ms]")]
    shade = {"n3": "#e8f0fb", "n6": "#fdeee6"}
    fig, axes = plt.subplots(len(panels), 1, figsize=(11, 9), sharex=True)
    for ax, (col, label) in zip(axes, panels):
        y = df[col].replace([np.inf, -np.inf], np.nan)
        y = y.where(y > 0)
        ax.plot(df.t, y, color=ps.SERIES[0], linewidth=1.4)
        ax.set_yscale("log")
        ax.set_ylabel(label, fontsize=9)
        for _, p in phases.iterrows():
            if p.link != "none":
                ax.axvspan(p.start_epoch - t0, p.end_epoch - t0, color=shade[p.link], zorder=0)
    for _, p in phases.iterrows():
        if p.link != "none":
            axes[0].annotate(p.phase, ((p.start_epoch + p.end_epoch) / 2 - t0, 1.02),
                             xycoords=("data", "axes fraction"), ha="center", fontsize=8, color=ps.INK_2)
    axes[-1].set_xlabel("time since start of the run [s]   (blue band = impairment on N3, orange band = on N6)")
    fig.suptitle("Fig. 9 - 5G user-plane timeline from Prometheus (1 s scrape): N3 vs N6 impairments",
                 x=0.01, ha="left", fontsize=11, fontweight="bold", color=ps.INK)
    fig.tight_layout()
    fig.savefig(os.path.join(ROOT, "figures", "fig9_timeline.png"))
    print("timeline written")


if __name__ == "__main__":
    main()
