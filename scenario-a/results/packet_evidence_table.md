3 s iperf3 TCP flow paced at 50 Mbit/s, captured at P1 (UE, ue-eth0) and P4 (Docker bridge br-dn).

| Condition | P1 data segs | P4 data segs | lost on path (P1-P4) | retransmissions (P1) | dup ACKs (P1) | mean ACK RTT at UE [ms] |
|---|---:|---:|---:|---:|---:|---:|
| C0 baseline | 13151 | 13151 | 0 | 39 | 17 | 0.47 |
| C1 +50 ms RTT | 13084 | 13084 | 0 | 0 | 1 | 51.22 |
| C2 1 % loss | 13249 | 13104 | 145 | 149 | 206 | 1.05 |
| C3 20 Mbit/s | 5175 | 5168 | 7 | 8 | 273 | 48.77 |
| C4 +50 ms & 1 % | 896 | 884 | 12 | 11 | 70 | 50.70 |
| C5 +50 ms RTT | 13081 | 13081 | 0 | 0 | 1 | 52.14 |
| C6 1 % loss | 13177 | 13066 | 111 | 122 | 159 | 0.38 |
