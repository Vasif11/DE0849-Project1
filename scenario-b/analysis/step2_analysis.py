#!/usr/bin/env python3
"""Scenario B, Step 2 - merge the decoded N2 (NGAP/NAS), SBI (HTTP/2) and N4 (PFCP) traces into one
chronological procedure timeline and summarise the service-based interactions.

Reads  captures/step2/analysis/{n2_ngap,sbi_http2,n4_pfcp,packet_counts}.txt (scripts/03_capture.sh)
Writes captures/step2/analysis/{procedure_timeline,sbi_interactions,interface_comparison}.md
"""
import os
import re

import pandas as pd

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AN = os.path.join(ROOT, "captures", "step2", "analysis")

NF = {
    "10.20.4.10": "NRF", "10.20.4.11": "SCP", "10.20.4.12": "AMF", "10.20.4.13": "SMF",
    "10.20.4.14": "UDR", "10.20.4.15": "UDM", "10.20.4.16": "AUSF", "10.20.4.17": "PCF",
    "10.20.4.18": "NSSF", "10.20.4.19": "BSF", "10.20.2.10": "gNB", "10.20.2.12": "AMF",
    "10.20.5.13": "SMF", "10.20.5.14": "UPF",
}
SCP = "10.20.4.11"
# producer NF from the service name (used when the SCP -> producer leg could not be decoded)
SERVICE_NF = {"nausf": "AUSF", "nudm": "UDM", "nudr": "UDR", "npcf": "PCF", "nsmf": "SMF", "namf": "AMF",
              "nnrf": "NRF", "nbsf": "BSF", "nnssf": "NSSF"}


def read(name, cols):
    rows = [l.rstrip("\n").split("|") for l in open(os.path.join(AN, name), encoding="utf-8") if l.strip()]
    return pd.DataFrame([r + [""] * (len(cols) - len(r)) for r in rows], columns=cols)


def n2_events():
    d = read("n2_ngap.txt", ["t", "src", "dst", "proc", "info"])
    out = []
    for _, r in d.iterrows():
        info = re.sub(r"SACK \([^)]*\)\s*,\s*", "", r["info"]).strip(" ,")
        out.append({"t": float(r.t), "interface": "N2 NGAP/SCTP", "from": NF.get(r.src, r.src),
                    "to": NF.get(r.dst, r.dst), "message": info})
    return out


def sbi_requests():
    d = read("sbi_http2.txt", ["t", "src", "sport", "dst", "dport", "stream", "method", "path", "status"])
    d["t"] = d.t.astype(float)
    reqs = d[d.method != ""].copy()
    resp = d[d.status != ""]
    status = {(r.dst, r.dport, r.src, r.sport, r.stream): r.status.split(",")[0] for _, r in resp.iterrows()}
    out, used = [], set()
    for i, r in reqs.iterrows():
        if r.src == SCP or i in used:
            continue
        base = r.path.split("?")[0]
        producer = NF.get(r.dst, r.dst)
        if r.dst == SCP:   # indirect communication: find the SCP -> producer leg of the same request
            leg = reqs[(reqs.src == SCP) & (reqs.method == r.method) & (reqs.t >= r.t) &
                       (reqs.path.str.split("?").str[0] == base) & (~reqs.index.isin(used))].head(1)
            if len(leg):
                used.add(leg.index[0])
                producer = NF.get(leg.iloc[0].dst, leg.iloc[0].dst)
            else:
                # HTTP/2 header compression (HPACK) state of connections opened before the capture is
                # unknown to tshark, so some headers are not decodable -> infer the producer from the API
                producer = SERVICE_NF.get(base.strip("/").split("-")[0], "?") + "*"
        out.append({"t": r.t, "consumer": NF.get(r.src, r.src), "producer": producer,
                    "via_scp": r.dst == SCP, "method": r.method, "path": base,
                    "service": base.strip("/").split("/")[0],
                    "status": status.get((r.src, r.sport, r.dst, r.dport, r.stream), "n/d")})
    return pd.DataFrame(out)


def n4_events():
    d = read("n4_pfcp.txt", ["t", "src", "dst", "type", "seq", "info"])
    return [{"t": float(r.t), "interface": "N4 PFCP/UDP", "from": NF.get(r.src, r.src), "to": NF.get(r.dst, r.dst),
             "message": r["info"]} for _, r in d.iterrows() if "Heartbeat" not in r["info"]]


def main():
    sbi = sbi_requests()
    ev = n2_events() + n4_events()
    for _, r in sbi[~sbi.path.str.startswith("/nnrf-nfm")].iterrows():
        hop = f"{r.consumer} → SCP → {r.producer}" if r.via_scp else f"{r.consumer} → {r.producer}"
        ev.append({"t": r.t, "interface": "SBI HTTP/2", "from": hop.split(" → ")[0], "to": hop.split(" → ", 1)[1],
                   "message": f"{r.method} {r.path} → {r.status}"})
    tl = pd.DataFrame(ev).sort_values("t")
    t0 = tl[tl.message.str.contains("Registration request")].t.min()
    tl = tl[(tl.t >= t0 - 0.05) & (tl.t <= tl[tl.message.str.contains("PDUSessionResourceSetupResponse")].t.max() + 0.05)]
    tl.insert(0, "t [ms]", ((tl.t - t0) * 1000).round(1))
    tl = tl.drop(columns="t")
    with open(os.path.join(AN, "procedure_timeline.md"), "w", encoding="utf-8") as f:
        f.write(tl.to_markdown(index=False))
    print(tl.to_string(index=False))

    s = (sbi.groupby(["consumer", "producer", "service", "method", "path"]).size().reset_index(name="count"))
    s["path"] = s.path.str.replace(r"imsi-\d+|suci-[\d-]+", "{ue}", regex=True).str.replace(r"/[0-9a-f-]{36}", "/{id}", regex=True)
    s = s.groupby(["consumer", "producer", "service", "method", "path"])["count"].sum().reset_index()
    with open(os.path.join(AN, "sbi_interactions.md"), "w", encoding="utf-8") as f:
        f.write(s.to_markdown(index=False))

    pc = pd.read_csv(os.path.join(AN, "packet_counts.txt"), sep=r"\s+")
    with open(os.path.join(AN, "interface_comparison.md"), "w", encoding="utf-8") as f:
        f.write(pc.to_markdown(index=False))


if __name__ == "__main__":
    main()
