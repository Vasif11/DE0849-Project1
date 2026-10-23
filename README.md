# DE0849 Telecommunications Software - Project 1
## Network Deployment, Measurement and Observability

**Author:** Vasif Yusifli, 261AEM001
**Course:** DE0849 Telecommunications Software - Riga Technical University (2026/27)
**Workflow:** Deploy → Verify → Observe → Measure → Diagnose → Explain

This repository contains both scenarios of Project 1. Each scenario is self-contained (deployment,
scripts, raw results, packet captures, dataset, analysis code, figures) and has its own technical report.

| | Scenario A | Scenario B |
|---|---|---|
| **Report** | [scenario-a/README.md](scenario-a/README.md) | [scenario-b/README.md](scenario-b/README.md) |
| **Network** | Software-based telecom network | 5G Standalone network |
| **Path** | UE → Access → Core/Gateway → Data Network → Application | UE → gNB → N3/GTP-U → UPF → N6 → Data Network → Application |
| **Implementation** | Linux namespaces + veth (UE, access router, core gateway) + Docker bridge (Nginx, iperf3) | UERANSIM (UE, gNB) + Open5GS 2.8 5GC (NRF, SCP, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) + MongoDB + Docker networks per interface (N2, N3, N4, N6, SBI) |
| **Control plane** | static routing | NGAP/SCTP (N2), HTTP/2 SBI, PFCP (N4), NAS-5GS registration, 5G-AKA, PDU session |
| **Observability** | tcpdump/tshark at 4 points, Prometheus (custom exporter), Grafana | tcpdump/tshark on N2/N3/N4/N6/SBI, Open5GS NF metrics + exporter in Prometheus, Grafana |
| **Impairments** | delay, loss, rate, combined; two links | delay, loss, rate on **N3 vs N6** |
| **Failure diagnosis** | F0 baseline retransmissions (found), F1-F3 injected (routing, forwarding, container) | F1 authentication failure, F2 UPF crash/restart, F3 N3 link down |

### Headline results

| Metric (baseline, mean of 3 runs) | Scenario A | Scenario B |
|---|---:|---:|
| ICMP RTT UE → Nginx | 0.17 ms | 1.67 ms |
| TCP upload / download | 3327 / 3024 Mbit/s | 435 / 440 Mbit/s |
| UDP @ 30 Mbit/s loss | 0 % | 0 % |
| HTTP median response | 0.56 ms | 2.33 ms |
| TCP with +50 ms RTT | 521 Mbit/s | 21 Mbit/s (N3) / 32 Mbit/s (N6) |
| TCP with 1 % loss | 303 Mbit/s | 108 Mbit/s (N3) / 103 Mbit/s (N6) |
| TCP through a 20 Mbit/s bottleneck | 19.1 Mbit/s (= 20 × 1448/1514) | 18.5 Mbit/s (= 20 × 1348/1458, GTP-U overhead) |

Scenario B is ~10× slower in RTT and ~8× in throughput, because the 5G user plane is processed by
user-space programs (UERANSIM gNB/UE, Open5GS UPF) and every packet is encapsulated in GTP-U
(+44 bytes). Scenario A forwards in the Linux kernel only.

### Repository layout

```
DE0849-Project1/
├── README.md            this overview
├── scenario-a/          Linux namespaces + Docker (report, deploy/, scripts/, results/, captures/, data/, figures/, analysis/)
└── scenario-b/          5G SA with Open5GS + UERANSIM (same structure)
```

Both scenarios are reproduced with `sudo ./scripts/00_install.sh` followed by `sudo ./scripts/run_all.sh`,
run inside the scenario directory. The test system was Ubuntu 26.04 on WSL2 (4 vCPU, 3.9 GB RAM), Docker 29.1.
