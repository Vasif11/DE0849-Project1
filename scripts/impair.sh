#!/usr/bin/env bash
# Apply / clear controlled impairments with tc (netem, tbf) on one link of the path.
#
#   impair.sh apply <link> <qdisc spec...>   e.g. impair.sh apply access-core netem delay 25ms
#   impair.sh clear                          remove all impairments
#   impair.sh show                           print qdiscs + statistics on both links
#
# Links (the qdisc is installed on the egress of BOTH ends, i.e. both directions are impaired):
#   access-core : access/acc-core (UE->server)  +  core/core-acc   (server->UE)   10.0.2.0/24
#   core-dn     : core/core-dn    (UE->server)  +  host/host-core  (server->UE)   10.0.3.0/24
# netem "delay 25ms" on both directions therefore adds 50 ms to the round-trip time.
source "$(dirname "$0")/lib.sh"
require_root

link_ends() {   # prints: <ns-uplink> <dev-uplink> <ns-downlink> <dev-downlink>   ("-" = root ns)
  case "$1" in
    access-core) echo "$NS_ACC acc-core $NS_CORE core-acc" ;;
    core-dn)     echo "$NS_CORE core-dn - host-core" ;;
    *) echo "unknown link '$1' (use access-core | core-dn)" >&2; exit 2 ;;
  esac
}

tc_in() {  # tc_in <ns|-> <tc args...>
  local ns=$1; shift
  if [[ $ns == "-" ]]; then tc "$@"; else tc -n "$ns" "$@"; fi
}

clear_all() {
  tc_in $NS_ACC  qdisc del dev acc-core  root 2>/dev/null || true
  tc_in $NS_CORE qdisc del dev core-acc  root 2>/dev/null || true
  tc_in $NS_CORE qdisc del dev core-dn   root 2>/dev/null || true
  tc_in -        qdisc del dev host-core root 2>/dev/null || true
}

show_all() {
  for e in "$NS_ACC acc-core" "$NS_CORE core-acc" "$NS_CORE core-dn" "- host-core"; do
    set -- $e
    echo "## $1/$2"; tc_in "$1" -s qdisc show dev "$2"
  done
}

cmd=${1:-show}; shift || true
case "$cmd" in
  apply)
    link=$1; shift
    read -r ns1 dev1 ns2 dev2 <<< "$(link_ends "$link")"
    spec=("$@")
    # netem keeps delayed packets in its own queue (default limit 1000 packets); raise it so that
    # the delay experiment does not silently turn into a tail-drop experiment at high rates.
    if [[ ${spec[0]} == netem ]]; then spec+=(limit 10000); fi
    clear_all
    tc_in "$ns1" qdisc replace dev "$dev1" root "${spec[@]}"
    tc_in "$ns2" qdisc replace dev "$dev2" root "${spec[@]}"
    echo "applied on $link ($ns1/$dev1 + $ns2/$dev2): ${spec[*]}"
    ;;
  clear) clear_all; echo "all impairments removed" ;;
  show)  show_all ;;
  *) echo "usage: $0 apply <link> <spec...> | clear | show" >&2; exit 2 ;;
esac
