#!/usr/bin/env python3
"""Parse the raw Step 3 outputs (results/raw/<condition>/...) into a structured dataset.

Outputs (data/):
  measurements.csv     one row per (condition, repetition, metric)   - long format
  ping_samples.csv     every individual ICMP RTT sample
  http_requests.csv    every individual HTTP request (small page and 1 MiB object)
  iperf_intervals.csv  per-second iperf3 interval data (throughput, retransmits, cwnd, srtt)
  step3_packet_evidence.csv  tshark statistics of the evidence captures (captures/step3)
"""
import glob
import json
import os
import re
import subprocess
import sys

import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RAW = os.path.join(ROOT, "results", "raw")
DATA = os.path.join(ROOT, "data")


def rep_of(path):
    return int(re.search(r"rep(\d+)", path).group(1))


def parse_ping(path):
    txt = open(path).read()
    samples = [float(x) for x in re.findall(r"time=([\d.]+) ms", txt)]
    seqs = [int(x) for x in re.findall(r"icmp_seq=(\d+)", txt)]
    m = re.search(r"(\d+) packets transmitted, (\d+) received", txt)
    tx, rx = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    return samples, seqs, tx, rx


def iperf_tcp(path):
    j = json.load(open(path))
    end = j["end"]
    st = end["streams"][0]["sender"]
    return {
        "throughput_mbps": end["sum_received"]["bits_per_second"] / 1e6,
        "sender_mbps": end["sum_sent"]["bits_per_second"] / 1e6,
        "retransmits": end["sum_sent"].get("retransmits"),
        "bytes": end["sum_received"]["bytes"],
        "duration_s": end["sum_received"]["seconds"],
        "srtt_mean_ms": (st.get("mean_rtt") or float("nan")) / 1000,
        "srtt_max_ms": (st.get("max_rtt") or float("nan")) / 1000,
    }, j


def iperf_udp(path):
    j = json.load(open(path))
    end = j["end"]
    rcv = end.get("sum_received", end["sum"])
    snd = end.get("sum_sent", end["sum"])
    return {
        "offered_mbps": snd["bits_per_second"] / 1e6,
        "received_mbps": rcv["bits_per_second"] / 1e6,
        "loss_percent": rcv["lost_percent"],
        "lost_packets": rcv["lost_packets"],
        "packets": rcv["packets"],
        "jitter_ms": rcv["jitter_ms"],
    }, j


def tshark_count(pcap, display_filter):
    out = subprocess.run(["tshark", "-n", "-r", pcap, "-Y", display_filter],
                         capture_output=True, text=True).stdout
    return len(out.splitlines())


def tshark_ack_rtt(pcap):
    out = subprocess.run(["tshark", "-n", "-r", pcap, "-Y", "tcp.analysis.ack_rtt",
                          "-T", "fields", "-e", "tcp.analysis.ack_rtt"], capture_output=True, text=True).stdout
    vals = [float(v) for v in out.split()]
    return (sum(vals) / len(vals) * 1000) if vals else float("nan")


def main():
    os.makedirs(DATA, exist_ok=True)
    conds = pd.read_csv(os.path.join(ROOT, "results", "conditions.csv"), keep_default_na=False)
    rows, pings, https, intervals = [], [], [], []

    for _, c in conds.iterrows():
        cdir = os.path.join(RAW, c.condition)
        if not os.path.isdir(cdir):
            print("missing", cdir, file=sys.stderr)
            continue
        meta = {"condition": c.condition, "link": c.link, "spec": c.spec}

        def add(rep, layer, metric, value, unit):
            rows.append({**meta, "rep": rep, "layer": layer, "metric": metric, "value": value, "unit": unit})

        for f in sorted(glob.glob(os.path.join(cdir, "ping_rep*.txt"))):
            r = rep_of(f)
            s, seqs, tx, rx = parse_ping(f)
            for seq, v in zip(seqs, s):
                pings.append({**meta, "rep": r, "seq": seq, "rtt_ms": v})
            ser = pd.Series(s, dtype=float)
            add(r, "L1 network", "rtt_avg_ms", ser.mean(), "ms")
            add(r, "L1 network", "rtt_min_ms", ser.min(), "ms")
            add(r, "L1 network", "rtt_max_ms", ser.max(), "ms")
            add(r, "L1 network", "rtt_std_ms", ser.std(), "ms")
            add(r, "L1 network", "icmp_loss_percent", 100 * (tx - rx) / tx if tx else float("nan"), "%")

        for direction in ("up", "down"):
            for f in sorted(glob.glob(os.path.join(cdir, f"tcp_{direction}_rep*.json"))):
                r = rep_of(f)
                m, j = iperf_tcp(f)
                add(r, "L2 transport", f"tcp_{direction}_mbps", m["throughput_mbps"], "Mbit/s")
                add(r, "L2 transport", f"tcp_{direction}_retrans", m["retransmits"], "segments")
                add(r, "L2 transport", f"tcp_{direction}_srtt_ms", m["srtt_mean_ms"], "ms")
                for it in j["intervals"]:
                    s0 = it["streams"][0]
                    intervals.append({**meta, "test": f"tcp_{direction}", "rep": r, "t": it["sum"]["end"],
                                      "mbps": it["sum"]["bits_per_second"] / 1e6,
                                      "retrans": s0.get("retransmits"), "cwnd_kB": (s0.get("snd_cwnd") or 0) / 1024,
                                      "srtt_ms": (s0.get("rtt") or float("nan")) / 1000})

        for f in sorted(glob.glob(os.path.join(cdir, "udp_rep*.json"))):
            r = rep_of(f)
            m, j = iperf_udp(f)
            add(r, "L2 transport", "udp_offered_mbps", m["offered_mbps"], "Mbit/s")
            add(r, "L2 transport", "udp_received_mbps", m["received_mbps"], "Mbit/s")
            add(r, "L2 transport", "udp_loss_percent", m["loss_percent"], "%")
            add(r, "L2 transport", "udp_jitter_ms", m["jitter_ms"], "ms")
            add(r, "L2 transport", "udp_packets", m["packets"], "datagrams")

        for obj, pattern in (("small", "http_rep*.csv"), ("1MiB", "http1m_rep*.csv")):
            for f in sorted(glob.glob(os.path.join(cdir, pattern))):
                df = pd.read_csv(f)
                r = rep_of(f)
                for _, q in df.iterrows():
                    https.append({**meta, "object": obj, **q.to_dict()})
                ok = (df["exit"] == 0) & (df["code"] == 200)
                tag = "http" if obj == "small" else "http1m"
                add(r, "L3 application", f"{tag}_success_percent", 100 * ok.mean(), "%")
                add(r, "L3 application", f"{tag}_total_median_ms", 1000 * df.loc[ok, "t_total"].median(), "ms")
                add(r, "L3 application", f"{tag}_total_p95_ms", 1000 * df.loc[ok, "t_total"].quantile(0.95), "ms")
                add(r, "L3 application", f"{tag}_connect_median_ms", 1000 * df.loc[ok, "t_connect"].median(), "ms")

        for f in sorted(glob.glob(os.path.join(cdir, "http_nstat_rep*.txt"))):
            r = rep_of(f)
            v = {}
            for line in open(f):
                p = line.split()
                if len(p) >= 2 and not p[0].startswith("#"):
                    v[p[0]] = int(p[1])
            add(r, "L3 application", "http_tcp_retrans_segs", v.get("TcpRetransSegs", 0), "segments")
            add(r, "L3 application", "http_tcp_timeouts", v.get("TcpExtTCPTimeouts", 0), "events")

    pd.DataFrame(rows).to_csv(os.path.join(DATA, "measurements.csv"), index=False)
    pd.DataFrame(pings).to_csv(os.path.join(DATA, "ping_samples.csv"), index=False)
    pd.DataFrame(https).to_csv(os.path.join(DATA, "http_requests.csv"), index=False)
    pd.DataFrame(intervals).to_csv(os.path.join(DATA, "iperf_intervals.csv"), index=False)
    print(f"measurements: {len(rows)} rows, ping samples: {len(pings)}, http requests: {len(https)}")

    # packet-level evidence from the 3 s capture of every condition (P1 = UE, P4 = DN bridge)
    ev = []
    for _, c in conds.iterrows():
        for point, iface in (("P1", "ue-eth0"), ("P4", "br-dn")):
            pcap = os.path.join(ROOT, "captures", "step3", f"{c.condition}_{point}_{iface}.pcap.gz")
            if not os.path.exists(pcap):
                continue
            ev.append({
                "condition": c.condition, "point": point,
                "packets": tshark_count(pcap, "frame"),
                "data_segments_to_server": tshark_count(pcap, "tcp.len>0 and tcp.dstport==5201"),
                "retransmissions": tshark_count(pcap, "tcp.analysis.retransmission or tcp.analysis.fast_retransmission"),
                "duplicate_acks": tshark_count(pcap, "tcp.analysis.duplicate_ack"),
                "out_of_order": tshark_count(pcap, "tcp.analysis.out_of_order"),
                "lost_segment_flags": tshark_count(pcap, "tcp.analysis.lost_segment"),
                "mean_ack_rtt_ms": tshark_ack_rtt(pcap),
            })
    pd.DataFrame(ev).to_csv(os.path.join(DATA, "step3_packet_evidence.csv"), index=False)
    print(f"packet evidence rows: {len(ev)}")


if __name__ == "__main__":
    main()
