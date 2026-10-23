#!/usr/bin/env python3
"""Step 2 - correlate the same packets across the four observation points (P1..P4).

All captures are taken on the same Linux kernel clock, so the timestamp of one packet at
P1 (UE) and at P4 (Docker bridge) gives the one-way forwarding latency of each hop, and the
IP TTL shows which routers forwarded it.

Writes captures/step2/analysis/icmp_hop_table.md and udp_point_comparison.md.
"""
import os
import subprocess

import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CAP = os.path.join(ROOT, "captures", "step2")
AN = os.path.join(CAP, "analysis")
POINTS = [("P1", "ue-eth0", "UE"), ("P2", "acc-core", "after access router"),
          ("P3", "core-dn", "after core gateway"), ("P4", "br-dn", "Docker bridge")]


def fields(pcap, flt, names):
    out = subprocess.run(["tshark", "-n", "-r", pcap, "-Y", flt, "-T", "fields", "-E", "separator=,",
                          *sum((["-e", n] for n in names), [])], capture_output=True, text=True).stdout
    rows = [line.split(",") for line in out.splitlines() if line]
    return pd.DataFrame(rows, columns=names)


def icmp():
    names = ["frame.time_epoch", "ip.ttl", "ip.len", "icmp.type", "icmp.seq", "ip.id", "icmp.resptime"]
    frames = []
    for p, ifc, _ in POINTS:
        d = fields(os.path.join(CAP, f"icmp_{p}_{ifc}.pcap"), "icmp", names)
        d["point"] = p
        frames.append(d)
    d = pd.concat(frames)
    d["t"] = d["frame.time_epoch"].astype(float)
    d["ttl"] = d["ip.ttl"].astype(int)
    d["size"] = d["ip.len"].astype(int)
    d["type"] = d["icmp.type"].astype(int)
    key = ["type", "icmp.seq", "ip.id"]
    tables = []
    # echo requests travel P1 -> P4, echo replies travel P4 -> P1
    for typ, order, title in ((8, ["P1", "P2", "P3", "P4"], "Echo request UE → Nginx"),
                              (0, ["P4", "P3", "P2", "P1"], "Echo reply Nginx → UE")):
        rows = []
        for size, grp in d[d.type == typ].groupby("size"):
            src = grp[grp.point == order[0]].set_index(key)["t"]
            r = {"IP length [B]": size}
            for p in order:
                r[f"TTL at {p}"] = int(grp[grp.point == p]["ttl"].mode().iloc[0])
            for p in order[1:]:
                g = grp[grp.point == p].set_index(key)["t"]
                r[f"{order[0]}→{p} [µs]"] = round(((g - src.reindex(g.index)) * 1e6).mean(), 1)
            if typ == 0:
                r["RTT at UE [ms]"] = round(grp[grp.point == "P1"]["icmp.resptime"].astype(float).mean(), 3)
            rows.append(r)
        t = pd.DataFrame(rows)
        tables.append(f"**{title}** (mean of 5 packets per size)\n\n" + t.to_markdown(index=False))
        print(title); print(t.to_string(index=False))
    with open(os.path.join(AN, "icmp_hop_table.md"), "w", encoding="utf-8") as f:
        f.write("\n\n".join(tables) + "\n")


def udp():
    names = ["frame.time_epoch", "ip.id", "ip.ttl", "udp.length"]
    rows = []
    for p, ifc, desc in POINTS:
        d = fields(os.path.join(CAP, f"udp_iperf_{p}_{ifc}.pcap"), "udp and ip.src==10.0.1.10", names)
        t = d["frame.time_epoch"].astype(float)
        gaps = t.diff().dropna() * 1000
        rows.append({"point": f"{p} {ifc} ({desc})", "datagrams UE→server": len(d),
                     "TTL": int(d["ip.ttl"].astype(int).mode().iloc[0]),
                     "UDP length [B]": int(d["udp.length"].astype(int).mode().iloc[0]),
                     "mean inter-arrival [ms]": round(gaps.mean(), 3),
                     "inter-arrival std [ms]": round(gaps.std(), 3)})
    t = pd.DataFrame(rows)
    with open(os.path.join(AN, "udp_point_comparison.md"), "w", encoding="utf-8") as f:
        f.write(t.to_markdown(index=False))
    print(t.to_string(index=False))


if __name__ == "__main__":
    icmp()
    udp()
