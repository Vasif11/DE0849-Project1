#!/usr/bin/env bash
# Remove the Scenario A deployment.
#   --keep-containers   only remove the namespace part (used by 01_deploy.sh)
source "$(dirname "$0")/lib.sh"
require_root

pkill -f scenario_exporter.py 2>/dev/null || true

for ns in $NS_UE $NS_ACC $NS_CORE; do
  ip netns del "$ns" 2>/dev/null || true      # deleting a namespace also removes its veth ends
done
ip link del host-core 2>/dev/null || true
ip route del 10.0.1.0/24 2>/dev/null || true
ip route del 10.0.2.0/24 2>/dev/null || true

for rule in "-i host-core -o $DN_BRIDGE -j ACCEPT" "-i $DN_BRIDGE -o host-core -j ACCEPT"; do
  while iptables -C DOCKER-USER $rule 2>/dev/null; do iptables -D DOCKER-USER $rule; done
done

if [[ "${1:-}" != "--keep-containers" ]]; then
  docker compose -f "$COMPOSE_FILE" down
fi
echo "Teardown done."
