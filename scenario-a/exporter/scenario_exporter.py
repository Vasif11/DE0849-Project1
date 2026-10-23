#!/usr/bin/env python3
"""Prometheus exporter for Scenario A (runs as root in the host / root network namespace).

Exposes three kinds of operational evidence:
  * passive state  - per-interface counters of every hop (ip -s -j link), tc qdisc
                     counters and the configured impairment (tc -s -j qdisc),
                     TCP MIB counters of the UE and of the service containers (/proc/<pid>/net/snmp),
                     Nginx stub_status.
  * active probes  - ICMP RTT and HTTP response time measured FROM the UE namespace
                     towards the application server, once per second.
  * path state     - operstate of each link and success of the last HTTP probe.

Prometheus scrapes it through the observability bridge (10.0.5.1:9101); it is never
part of the UE -> application traffic path.
"""
import argparse
import json
import re
import subprocess
import threading
import time
import urllib.request

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily

# (namespace, interface) of every observation point; "host" = root namespace
LINKS = [
    ("ue", "ue-eth0"),
    ("access", "acc-ue"), ("access", "acc-core"),
    ("core", "core-acc"), ("core", "core-dn"),
    ("host", "host-core"), ("host", "br-dn"),
]
CONTAINERS = {"nginx": "scena-nginx", "iperf3": "scena-iperf3"}


def sh(cmd, timeout=2.0):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


def in_ns(ns, *cmd):
    return list(cmd) if ns == "host" else ["ip", "netns", "exec", ns, *cmd]


def ns_flag(ns):
    return [] if ns == "host" else ["-n", ns]


def parse_snmp(text):
    """Return {'Tcp': {...}, 'Udp': {...}, 'Ip': {...}} from /proc/net/snmp content."""
    out, lines = {}, text.splitlines()
    for hdr, val in zip(lines[::2], lines[1::2]):
        proto, keys = hdr.split(":", 1)
        _, vals = val.split(":", 1)
        out[proto] = dict(zip(keys.split(), (int(v) for v in vals.split())))
    return out


class Probes:
    """Active measurements from the UE namespace (1 Hz), run in background threads."""

    def __init__(self, target, port):
        self.target, self.port = target, port
        self.lock = threading.Lock()
        self.rtt_ms = float("nan")
        self.icmp_sent = self.icmp_lost = 0
        self.http = {"connect": float("nan"), "ttfb": float("nan"), "total": float("nan")}
        self.http_up = 0
        self.http_ok = self.http_fail = 0

    def ping_loop(self):
        rx = re.compile(r"time=([\d.]+) ms")
        while True:
            t0 = time.time()
            out = sh(in_ns("ue", "ping", "-n", "-c", "1", "-W", "1", self.target), timeout=3)
            m = rx.search(out)
            with self.lock:
                self.icmp_sent += 1
                if m:
                    self.rtt_ms = float(m.group(1))
                else:
                    self.icmp_lost += 1
                    self.rtt_ms = float("nan")
            time.sleep(max(0.0, 1.0 - (time.time() - t0)))

    def http_loop(self):
        url = f"http://{self.target}:{self.port}/"
        fmt = "%{http_code} %{time_connect} %{time_starttransfer} %{time_total}"
        while True:
            t0 = time.time()
            out = sh(in_ns("ue", "curl", "-s", "-o", "/dev/null", "--max-time", "2", "-w", fmt, url), timeout=4)
            parts = out.split()
            with self.lock:
                if len(parts) == 4 and parts[0] == "200":
                    self.http_ok += 1
                    self.http_up = 1
                    self.http = dict(zip(("connect", "ttfb", "total"), map(float, parts[1:])))
                else:
                    self.http_fail += 1
                    self.http_up = 0
                    self.http = {k: float("nan") for k in self.http}
            time.sleep(max(0.0, 1.0 - (time.time() - t0)))

    def start(self):
        for fn in (self.ping_loop, self.http_loop):
            threading.Thread(target=fn, daemon=True).start()


class ScenarioCollector:
    def __init__(self, probes, app_ip, app_port):
        self.probes = probes
        self.status_url = f"http://{app_ip}:{app_port}/nginx_status"
        self._pids, self._pids_at = {}, 0.0

    def container_pids(self):
        # docker inspect is slow (~50 ms); refresh the PIDs every 5 s (they change on restart)
        if time.time() - self._pids_at > 5:
            self._pids = {}
            for name, cname in CONTAINERS.items():
                pid = sh(["docker", "inspect", "-f", "{{.State.Pid}}", cname]).strip()
                if pid and pid != "0":
                    self._pids[name] = pid
            self._pids_at = time.time()
        return self._pids

    def collect(self):
        lbl = ["ns", "iface"]
        rx_b = CounterMetricFamily("scena_iface_rx_bytes", "Bytes received on interface", labels=lbl)
        tx_b = CounterMetricFamily("scena_iface_tx_bytes", "Bytes transmitted on interface", labels=lbl)
        rx_p = CounterMetricFamily("scena_iface_rx_packets", "Packets received on interface", labels=lbl)
        tx_p = CounterMetricFamily("scena_iface_tx_packets", "Packets transmitted on interface", labels=lbl)
        drop = CounterMetricFamily("scena_iface_dropped", "Interface rx+tx drops", labels=lbl)
        up = GaugeMetricFamily("scena_link_up", "1 if the interface operstate is UP", labels=lbl)
        q_drop = CounterMetricFamily("scena_qdisc_drops", "Packets dropped by the root qdisc (netem/tbf)", labels=lbl)
        q_pkts = CounterMetricFamily("scena_qdisc_sent_packets", "Packets sent by the root qdisc", labels=lbl)
        q_back = GaugeMetricFamily("scena_qdisc_backlog_bytes", "Bytes queued in the root qdisc", labels=lbl)
        delay = GaugeMetricFamily("scena_impair_delay_ms", "Configured netem delay", labels=lbl)
        loss = GaugeMetricFamily("scena_impair_loss_percent", "Configured netem random loss", labels=lbl)
        rate = GaugeMetricFamily("scena_impair_rate_mbit", "Configured tbf rate (0 = unlimited)", labels=lbl)

        by_ns = {}
        for ns, ifc in LINKS:
            by_ns.setdefault(ns, []).append(ifc)
        for ns, ifaces in by_ns.items():
            try:
                links = {l["ifname"]: l for l in json.loads(sh(["ip", *ns_flag(ns), "-s", "-j", "link", "show"]) or "[]")}
            except json.JSONDecodeError:
                links = {}
            for ifc in ifaces:
                l = links.get(ifc)
                if not l:
                    up.add_metric([ns, ifc], 0)
                    continue
                s = l["stats64"]
                rx_b.add_metric([ns, ifc], s["rx"]["bytes"])
                tx_b.add_metric([ns, ifc], s["tx"]["bytes"])
                rx_p.add_metric([ns, ifc], s["rx"]["packets"])
                tx_p.add_metric([ns, ifc], s["tx"]["packets"])
                drop.add_metric([ns, ifc], s["rx"]["dropped"] + s["tx"]["dropped"])
                up.add_metric([ns, ifc], 1 if l.get("operstate") in ("UP", "UNKNOWN") else 0)

                try:
                    q = json.loads(sh(["tc", *ns_flag(ns), "-s", "-j", "qdisc", "show", "dev", ifc]) or "[]")
                except json.JSONDecodeError:
                    q = []
                root = next((x for x in q if x.get("root")), None)
                d = lo = r = 0.0
                if root:
                    q_drop.add_metric([ns, ifc], root.get("drops", 0))
                    q_pkts.add_metric([ns, ifc], root.get("packets", 0))
                    q_back.add_metric([ns, ifc], root.get("backlog", 0))
                    opt = root.get("options", {})
                    if root["kind"] == "netem":
                        d = opt.get("delay", {}).get("delay", 0) * 1000
                        lo = opt.get("loss-random", {}).get("loss", 0) * 100
                    elif root["kind"] == "tbf":
                        r = opt.get("rate", 0) * 8 / 1e6
                delay.add_metric([ns, ifc], d)
                loss.add_metric([ns, ifc], lo)
                rate.add_metric([ns, ifc], r)

        for m in (rx_b, tx_b, rx_p, tx_p, drop, up, q_drop, q_pkts, q_back, delay, loss, rate):
            yield m

        # TCP/UDP MIB of the UE and of the service containers (server side of the flows)
        retr = CounterMetricFamily("scena_tcp_retrans_segs", "TCP segments retransmitted", labels=["endpoint"])
        outs = CounterMetricFamily("scena_tcp_out_segs", "TCP segments sent", labels=["endpoint"])
        udp_err = CounterMetricFamily("scena_udp_rcvbuf_errors", "UDP datagrams dropped (receive buffer)", labels=["endpoint"])
        sources = {"ue": in_ns("ue", "cat", "/proc/net/snmp")}
        for name, pid in self.container_pids().items():
            sources[name] = ["cat", f"/proc/{pid}/net/snmp"]
        for ep, cmd in sources.items():
            txt = sh(cmd)
            if not txt:
                continue
            snmp = parse_snmp(txt)
            retr.add_metric([ep], snmp["Tcp"]["RetransSegs"])
            outs.add_metric([ep], snmp["Tcp"]["OutSegs"])
            udp_err.add_metric([ep], snmp["Udp"].get("RcvbufErrors", 0))
        yield retr
        yield outs
        yield udp_err

        # Nginx stub_status (queried from the host on the data network, not via the UE path)
        try:
            body = urllib.request.urlopen(self.status_url, timeout=0.5).read().decode()
            nums = list(map(int, re.findall(r"\d+", body)))
            # Active connections: N / accepts handled requests / Reading Writing Waiting
            g = GaugeMetricFamily("scena_nginx_active_connections", "Nginx active connections")
            g.add_metric([], nums[0]); yield g
            c = CounterMetricFamily("scena_nginx_requests", "Nginx total requests")
            c.add_metric([], nums[3]); yield c
            ng = GaugeMetricFamily("scena_nginx_up", "Nginx stub_status reachable")
            ng.add_metric([], 1); yield ng
        except Exception:
            ng = GaugeMetricFamily("scena_nginx_up", "Nginx stub_status reachable")
            ng.add_metric([], 0); yield ng

        p = self.probes
        with p.lock:
            g = GaugeMetricFamily("scena_probe_rtt_ms", "Last ICMP RTT UE->app (NaN if lost)")
            g.add_metric([], p.rtt_ms); yield g
            c = CounterMetricFamily("scena_probe_icmp_sent", "ICMP probes sent from UE")
            c.add_metric([], p.icmp_sent); yield c
            c = CounterMetricFamily("scena_probe_icmp_lost", "ICMP probes without reply")
            c.add_metric([], p.icmp_lost); yield c
            g = GaugeMetricFamily("scena_probe_http_seconds", "Last HTTP probe timing UE->app", labels=["phase"])
            for k, v in p.http.items():
                g.add_metric([k], v)
            yield g
            g = GaugeMetricFamily("scena_probe_http_up", "1 if the last HTTP probe returned 200")
            g.add_metric([], p.http_up); yield g
            c = CounterMetricFamily("scena_probe_http_requests", "HTTP probes by result", labels=["result"])
            c.add_metric(["ok"], p.http_ok)
            c.add_metric(["fail"], p.http_fail)
            yield c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9101)
    ap.add_argument("--target", default="10.0.4.10")
    ap.add_argument("--app-port", type=int, default=8080)
    a = ap.parse_args()

    probes = Probes(a.target, a.app_port)
    probes.start()
    REGISTRY.register(ScenarioCollector(probes, a.target, a.app_port))
    start_http_server(a.port, addr=a.listen)
    print(f"scenario exporter listening on {a.listen}:{a.port}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
