#!/usr/bin/env bash
#
# Boot a VM with an SR-IOV port on sriov-net.
#
# Picking sriov-net as a network in the launch dialog (or with --network) does
# not work: Nova then asks for a normal (OVS) port, which Neutron's policy
# refuses on sriov-net. Instead this creates a "direct" port first and boots
# the VM with that port and a config drive (sriov-net has no DHCP).
#
# Usage: source an openrc, then
#   scripts/voereir/sriov-vm-create.sh NAME IMAGE FLAVOR [KEYPAIR]
#
# Optional environment:
#   SRIOV_NET_NAME  network for the SR-IOV port (default: sriov-net)
#   SRIOV_IP        fixed IP for the SR-IOV port (default: picked by Neutron)
#   EXTRA_NETWORK   also attach a normal port on this network, e.g. "private",
#                   for SSH / internet access (sriov-net has no gateway)
#   EXTRA_ARGS      extra arguments for "openstack server create"

set -euo pipefail

if [[ $# -lt 3 ]]; then
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

NAME=$1
IMAGE=$2
FLAVOR=$3
KEYPAIR=${4:-""}
NET_NAME=${SRIOV_NET_NAME:-"sriov-net"}
PORT_NAME="${NAME}-sriov"

fixed_ip=()
[[ -n "${SRIOV_IP:-}" ]] && fixed_ip=(--fixed-ip "ip-address=${SRIOV_IP}")

if openstack port show "${PORT_NAME}" -f value -c id >/dev/null 2>&1; then
    echo "Reusing existing port ${PORT_NAME}"
else
    echo "Creating direct port ${PORT_NAME} on ${NET_NAME}"
    # Security groups do not apply to SR-IOV ports, so port security is off.
    openstack port create "${PORT_NAME}" --network "${NET_NAME}" \
        --vnic-type direct --disable-port-security "${fixed_ip[@]}" -f value -c id
fi
port_id=$(openstack port show "${PORT_NAME}" -f value -c id)
port_ip=$(openstack port show "${PORT_NAME}" -f json -c fixed_ips \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["fixed_ips"][0]["ip_address"])')

args=(--image "${IMAGE}" --flavor "${FLAVOR}" --port "${port_id}" --config-drive True)
[[ -n "${KEYPAIR}" ]] && args+=(--key-name "${KEYPAIR}")
[[ -n "${EXTRA_NETWORK:-}" ]] && args+=(--network "${EXTRA_NETWORK}")
# shellcheck disable=SC2206
[[ -n "${EXTRA_ARGS:-}" ]] && args+=(${EXTRA_ARGS})

echo "Booting ${NAME} (sriov-net address ${port_ip})"
openstack server create "${NAME}" "${args[@]}" --wait -f value -c id -c status
