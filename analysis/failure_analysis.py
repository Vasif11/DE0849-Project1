#!/usr/bin/env python3
"""Failure diagnosis - availability timeline and detection/recovery times of F1..F3.

Reads  results/failure/<case>_probe.csv and events.csv (scripts/06_failure.sh)
Writes results/failure/summary.md and figures/fig8_failures.png
"""
import os

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import plotstyle as ps

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FD = os.path.join(ROOT, "results", "failure")
CASES = {
    "F1_missing_return_route": "F1 missing return route on host",
    "F2_access_forwarding_off": "F2 IP forwarding off on access router",
    "F3_app_container_down": "F3 Nginx container stopped",
}


def main():
    ps.apply()
    ev = pd.read_csv(os.path.join(FD, "events.csv"))
    fig, axes = plt.subplots(len(CASES), 1, figsize=(10, 7.5), sharex=True)
    rows = []
    for ax, (case, title) in zip(axes, CASES.items()):
        p = pd.read_csv(os.path.join(FD, f"{case}_probe.csv"))
        e = ev[ev.case == case].set_index("event").epoch
        t_inj, t_rec = e["inject"], e["recover"]
        p["t"] = p.epoch - t_inj
        p["ok"] = (p.exit == 0) & (p.code == 200)
        ok, bad = p[p.ok], p[~p.ok]
        ax.scatter(ok.t, ok.t_total * 1000, s=14, color=ps.SERIES[0], label="HTTP 200 (response time)")
        ax.scatter(bad.t, [2000] * len(bad), s=22, marker="x", color=ps.CRITICAL, label="request failed")
        ax.axvline(0, color=ps.INK_2, linewidth=1, linestyle="--")
        ax.axvline(t_rec - t_inj, color=ps.INK_2, linewidth=1, linestyle=":")
        ax.annotate("inject", (0, 1), xycoords=("data", "axes fraction"), xytext=(3, -10),
                    textcoords="offset points", fontsize=8, color=ps.INK_2)
        ax.annotate("recover", (t_rec - t_inj, 1), xycoords=("data", "axes fraction"), xytext=(3, -10),
                    textcoords="offset points", fontsize=8, color=ps.INK_2)
        ax.set_yscale("log")
        ax.set_ylim(0.1, 5000)
        ax.set_title(title, fontsize=10)
        ax.set_ylabel("ms")

        before = p[p.t < 0]
        during = p[(p.t >= 0) & (p.epoch < t_rec)]
        after = p[p.epoch >= t_rec]
        first_fail = during[~during.ok].t.min()
        first_ok_after = (after[after.ok].epoch.min() - t_rec) if after.ok.any() else np.nan
        err = during[~during.ok].exit.mode()
        rows.append({
            "case": title,
            "availability before": f"{100 * before.ok.mean():.0f} %",
            "availability during": f"{100 * during.ok.mean():.0f} %",
            "availability after": f"{100 * after.ok.mean():.0f} %",
            "first failed probe after inject [s]": round(first_fail, 2) if pd.notna(first_fail) else "-",
            "time to first success after fix [s]": round(first_ok_after, 2) if pd.notna(first_ok_after) else "-",
            "curl exit code during failure": int(err.iloc[0]) if len(err) else "-",
        })
    axes[0].legend(loc="upper right", fontsize=8)
    axes[-1].set_xlabel("time relative to failure injection [s]  (HTTP probe from the UE every 0.5 s, timeout 1.5 s)")
    fig.suptitle("Fig. 8 - Service availability seen by the UE during injected failures",
                 x=0.01, ha="left", fontsize=11, fontweight="bold", color=ps.INK)
    fig.tight_layout()
    fig.savefig(os.path.join(ROOT, "figures", "fig8_failures.png"))
    t = pd.DataFrame(rows)
    with open(os.path.join(FD, "summary.md"), "w", encoding="utf-8") as f:
        f.write(t.to_markdown(index=False))
    print(t.to_string(index=False))


if __name__ == "__main__":
    main()
