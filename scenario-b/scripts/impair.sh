#!/usr/bin/env bash
# Apply / clear controlled impairments on the N3 or the N6 segment of the 5G user plane.
#
#   impair.sh apply n3|n6 <qdisc spec...>    e.g. impair.sh apply n3 netem delay 25ms
#   impair.sh clear | show
#
#   n3 : gNB N3 interface egress (uplink, UE->DN)    + UPF N3 interface egress (downlink)
#   n6 : UPF N6 interface egress (uplink)            + host-side veth of the UPF N6 port (downlink,
#                                                      i.e. everything the DN sends towards the UPF)
# Both directions are impaired, so "delay 25ms" adds 50 ms to the round-trip time.
source "$(dirname "$0")/lib.sh"
require_root

# prints "<container|-> <iface>" for the two ends of a segment ("-" = root namespace)
ends() {
  case "$1" in
    n3) echo "$C_GNB $(ifname_of $C_GNB $GNB_N3_IP)"; echo "$C_UPF $(ifname_of $C_UPF $UPF_N3_IP)" ;;
    n6) local i; i=$(ifname_of $C_UPF $UPF_N6_IP)
        echo "$C_UPF $i"; echo "- $(host_peer_of $C_UPF "$i")" ;;
    *) echo "unknown segment '$1' (n3|n6)" >&2; exit 2 ;;
  esac
}
tc_at() { local c=$1; shift; if [[ $c == "-" ]]; then tc "$@"; else cns "$c" tc "$@"; fi; }

clear_all() {
  local s c i
  for s in n3 n6; do
    while read -r c i; do tc_at "$c" qdisc del dev "$i" root 2>/dev/null || true; done < <(ends $s)
  done
}
show_all() {
  local s c i
  for s in n3 n6; do
    while read -r c i; do echo "## $s $c/$i"; tc_at "$c" -s qdisc show dev "$i"; done < <(ends $s)
  done
}

cmd=${1:-show}; shift || true
case "$cmd" in
  apply)
    seg=$1; shift
    spec=("$@")
    [[ ${spec[0]} == netem ]] && spec+=(limit 10000)
    clear_all
    while read -r c i; do tc_at "$c" qdisc replace dev "$i" root "${spec[@]}"; done < <(ends "$seg")
    echo "applied on $seg: ${spec[*]}"
    ;;
  clear) clear_all; echo "all impairments removed" ;;
  show) show_all ;;
  *) echo "usage: $0 apply n3|n6 <spec...> | clear | show" >&2; exit 2 ;;
esac
