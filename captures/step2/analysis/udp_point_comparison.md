| point                             |   datagrams UE→server |   TTL |   UDP length [B] |   mean inter-arrival [ms] |   inter-arrival std [ms] |
|:----------------------------------|----------------------:|------:|-----------------:|--------------------------:|-------------------------:|
| P1 ue-eth0 (UE)                   |                   865 |    64 |             1456 |                     2.317 |                    0.19  |
| P2 acc-core (after access router) |                   865 |    63 |             1456 |                     2.317 |                    0.225 |
| P3 core-dn (after core gateway)   |                   865 |    62 |             1456 |                     2.317 |                    0.235 |
| P4 br-dn (Docker bridge)          |                   865 |    61 |             1456 |                     2.317 |                    0.266 |