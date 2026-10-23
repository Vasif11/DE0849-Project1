3 s iperf3 TCP upload paced at 50 Mbit/s, captured at P1 (UE uesimtun0), P3 (N3, GTP-U) and P5 (N6). Uplink data segments counted at each point.

| Condition | P1 UE | P3 N3 | P5 N6 | missing before N3 (P1-P3) | missing between N3 and N6 (P3-P5) | retransmissions (P1) | dup ACKs (P1) | mean ACK RTT at UE [ms] |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C0 baseline | 14135 | 14135 | 14120 | 0 | 15 | 15 | 13 | 2.48 |
| C1 +50 ms RTT | 6341 | 6341 | 6275 | 0 | 66 | 66 | 281 | 55.80 |
| C2 +50 ms RTT | 14563 | 14452 | 14027 | 111 | 425 | 536 | 358 | 79.48 |
| C3 1 % loss | 14197 | 14063 | 14063 | 134 | 0 | 134 | 510 | 1.08 |
| C4 1 % loss | 14182 | 14182 | 14050 | 0 | 132 | 132 | 498 | 1.06 |
| C5 20 Mbit/s | 5319 | 5312 | 5312 | 7 | 0 | 8 | 239 | 43.57 |
