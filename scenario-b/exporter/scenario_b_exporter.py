#!/usr/bin/env python3
"""Prometheus exporter for Scenario B (runs as root on the host).

Complements the Open5GS NF metrics (AMF/SMF/UPF/PCF, scraped by Prometheus directly) with:
  * active probes from the UE PDU session (ICMP RTT and HTTP to Nginx, 1/s, inside the UE netns)
  * PDU-session state of the UE (uesimtun0 present and addressed)
  * interface counters of the user-plane ports (UE tunnel, gNB N3, UPF N3/N6/ogstun)
  * tc qdisc drops and the configured impairment on the N3 and N6 segments
  * TCP MIB of the UE (retransmissions)
"""
import argparse
import json
import re
import subprocess
import threading
import time

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily

UE, GNB, UPF = "scenario-b-ue", "scenario-b-gnb", "scenario-b-upf"
# (label, container, address) of the user-plane ports; address None = interface by name
PORTS = [("ue_tun", UE, "uesimtun0"), ("gnb_n3", GNB, "10.20.3.10"), ("upf_n3", UPF, "10.20.3.14"),
         ("upf_n6", UPF, "10.20.6.14"), ("upf_tun", UPF, "ogstun")]
TARGET, URL = "10.20.6.20", "http://10.20.6.20/"


def sh(cmd, timeout=2.0):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


class Pids:
    def __init__(self):
        self.p, self.at = {}, 0.0

    def get(self, c):
        if time.time() - self.at > 3:
            for name in (UE, GNB, UPF):
                pid = sh(["docker", "inspect", "-f", "{{.State.Pid}}", name], timeout=5).strip()
                if pid == "0":                 # container stopped
                    self.p.pop(name, None)
                elif pid:                      # empty = docker inspect timed out -> keep the cached PID
                    self.p[name] = pid
            self.at = time.time()
        return self.p.get(c)


PIDS = Pids()


def ns(c, *cmd):
    pid = PIDS.get(c)
    return ["nsenter", "-t", pid, "-n", *cmd] if pid else None


class Probes:
    def __init__(self):
        self.lock = threading.Lock()
        self.pdu_up = 0
        self.rtt = float("nan")
        self.sent = self.lost = 0
        self.http = {"connect": float("nan"), "ttfb": float("nan"), "total": float("nan")}
        self.http_up = 0
        self.ok = self.fail = 0

    def ping_loop(self):
        rx = re.compile(r"time=([\d.]+) ms")
        while True:
            t0 = time.time()
            cmd = ns(UE, "ping", "-n", "-c", "1", "-W", "1", TARGET)
            m = rx.search(sh(cmd, 3)) if cmd else None
            with self.lock:
                self.sent += 1
                if m:
                    self.rtt = float(m.group(1))
                else:
                    self.lost += 1
                    self.rtt = float("nan")
            time.sleep(max(0.0, 1.0 - (time.time() - t0)))

    def pdu_loop(self):
        # Under full CPU load a command can exceed its timeout; only a *completed* check that finds no
        # IPv4 address on uesimtun0 counts as "PDU session down" - a timeout keeps the last known state.
        while True:
            cmd = ns(UE, "ip", "-o", "-4", "addr", "show", "dev", "uesimtun0")
            state = None
            if cmd:
                try:
                    r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                    state = 1 if " inet " in r.stdout else 0
                except subprocess.TimeoutExpired:
                    pass
            else:
                state = 0
            if state is not None:
                with self.lock:
                    self.pdu_up = state
            time.sleep(1)

    def http_loop(self):
        fmt = "%{http_code} %{time_connect} %{time_starttransfer} %{time_total}"
        while True:
            t0 = time.time()
            cmd = ns(UE, "curl", "-s", "-o", "/dev/null", "--max-time", "2", "-w", fmt, URL)
            parts = sh(cmd, 4).split() if cmd else []
            with self.lock:
                if len(parts) == 4 and parts[0] == "200":
                    self.ok += 1
                    self.http_up = 1
                    self.http = dict(zip(("connect", "ttfb", "total"), map(float, parts[1:])))
                else:
                    self.fail += 1
                    self.http_up = 0
                    self.http = {k: float("nan") for k in self.http}
            time.sleep(max(0.0, 1.0 - (time.time() - t0)))


def links_of(c):
    cmd = ns(c, "ip", "-s", "-j", "addr", "show")
    try:
        return json.loads(sh(cmd) or "[]") if cmd else []
    except json.JSONDecodeError:
        return []


class Collector:
    def __init__(self, probes):
        self.p = probes

    def collect(self):
        lbl = ["port", "iface"]
        rxb = CounterMetricFamily("scenb_port_rx_bytes", "Bytes received", labels=lbl)
        txb = CounterMetricFamily("scenb_port_tx_bytes", "Bytes transmitted", labels=lbl)
        rxp = CounterMetricFamily("scenb_port_rx_packets", "Packets received", labels=lbl)
        txp = CounterMetricFamily("scenb_port_tx_packets", "Packets transmitted", labels=lbl)
        qd = CounterMetricFamily("scenb_qdisc_drops", "Packets dropped by the root qdisc", labels=lbl)
        delay = GaugeMetricFamily("scenb_impair_delay_ms", "Configured netem delay", labels=lbl)
        loss = GaugeMetricFamily("scenb_impair_loss_percent", "Configured netem loss", labels=lbl)
        rate = GaugeMetricFamily("scenb_impair_rate_mbit", "Configured tbf rate", labels=lbl)
        pdu = GaugeMetricFamily("scenb_pdu_session_up", "1 if the UE has uesimtun0 with an IPv4 address")

        cache = {}
        for port, c, key in PORTS:
            if c not in cache:
                cache[c] = links_of(c)
            link = next((l for l in cache[c] if l.get("ifname") == key or
                         any(a.get("local") == key for a in l.get("addr_info", []))), None)
            if not link:
                continue
            ifc = link["ifname"]
            s = link.get("stats64", {})
            if s:
                rxb.add_metric([port, ifc], s["rx"]["bytes"]); txb.add_metric([port, ifc], s["tx"]["bytes"])
                rxp.add_metric([port, ifc], s["rx"]["packets"]); txp.add_metric([port, ifc], s["tx"]["packets"])
            if port in ("gnb_n3", "upf_n3", "upf_n6"):
                cmd = ns(c, "tc", "-s", "-j", "qdisc", "show", "dev", ifc)
                try:
                    q = json.loads(sh(cmd) or "[]") if cmd else []
                except json.JSONDecodeError:
                    q = []
                root = next((x for x in q if x.get("root")), {})
                opt = root.get("options", {})
                qd.add_metric([port, ifc], root.get("drops", 0))
                delay.add_metric([port, ifc], opt.get("delay", {}).get("delay", 0) * 1000 if root.get("kind") == "netem" else 0)
                loss.add_metric([port, ifc], opt.get("loss-random", {}).get("loss", 0) * 100 if root.get("kind") == "netem" else 0)
                rate.add_metric([port, ifc], opt.get("rate", 0) * 8 / 1e6 if root.get("kind") == "tbf" else 0)
        with self.p.lock:
            pdu.add_metric([], self.p.pdu_up)
        yield from (rxb, txb, rxp, txp, qd, delay, loss, rate, pdu)

        pid = PIDS.get(UE)
        if pid:
            try:
                lines = open(f"/proc/{pid}/net/snmp").read().splitlines()
                tcp = [l.split() for l in lines if l.startswith("Tcp:")]
                v = dict(zip(tcp[0][1:], map(int, tcp[1][1:])))
                c = CounterMetricFamily("scenb_ue_tcp_retrans_segs", "UE TCP segments retransmitted")
                c.add_metric([], v["RetransSegs"]); yield c
            except (OSError, IndexError, KeyError):
                pass

        p = self.p
        with p.lock:
            g = GaugeMetricFamily("scenb_probe_rtt_ms", "ICMP RTT UE -> Nginx over the PDU session")
            g.add_metric([], p.rtt); yield g
            c = CounterMetricFamily("scenb_probe_icmp_sent", "ICMP probes sent"); c.add_metric([], p.sent); yield c
            c = CounterMetricFamily("scenb_probe_icmp_lost", "ICMP probes lost"); c.add_metric([], p.lost); yield c
            g = GaugeMetricFamily("scenb_probe_http_seconds", "HTTP probe timing", labels=["phase"])
            for k, v in p.http.items():
                g.add_metric([k], v)
            yield g
            g = GaugeMetricFamily("scenb_probe_http_up", "1 if the last HTTP probe returned 200")
            g.add_metric([], p.http_up); yield g
            c = CounterMetricFamily("scenb_probe_http_requests", "HTTP probes by result", labels=["result"])
            c.add_metric(["ok"], p.ok); c.add_metric(["fail"], p.fail); yield c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9102)
    a = ap.parse_args()
    probes = Probes()
    for fn in (probes.ping_loop, probes.http_loop, probes.pdu_loop):
        threading.Thread(target=fn, daemon=True).start()
    REGISTRY.register(Collector(probes))
    start_http_server(a.port, addr="0.0.0.0")
    print(f"scenario B exporter on :{a.port}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
