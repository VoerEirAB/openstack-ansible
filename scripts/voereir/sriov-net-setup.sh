#!/usr/bin/env bash
#
# Create or reconcile the SR-IOV provider network "sriov-net" on antelope.
#
#   VLAN 1000 on physical network sriovnet1 (enp8s0f1 VFs on the computes).
#   No DHCP and no gateway: the network node's OVS has no sriovnet1 mapping,
#   so neither a DHCP port nor a router interface can bind on it. VMs get
#   their address from a config drive (see sriov-vm-create.sh).
#   Shared with all projects, not external. The allocation pools leave out
#   the hosts' own untagged 30.0.0.1xx addresses on enp8s0f1.
#
# Usage: source an admin openrc, then
#   scripts/voereir/sriov-net-setup.sh            # dry run: show what would change
#   scripts/voereir/sriov-net-setup.sh --apply    # create / reconcile
#
# Every value can be overridden through the environment, for example
#   SRIOV_POOLS="30.0.0.150-30.0.0.199" scripts/voereir/sriov-net-setup.sh --apply

set -euo pipefail

NET_NAME=${SRIOV_NET_NAME:-"sriov-net"}
SUBNET_NAME=${SRIOV_SUBNET_NAME:-"sriov-net"}
PHYSNET=${SRIOV_PHYSNET:-"sriovnet1"}
VLAN_ID=${SRIOV_VLAN_ID:-"1000"}
MTU=${SRIOV_MTU:-"1500"}
CIDR=${SRIOV_CIDR:-"30.0.0.0/24"}
# Space separated start-end ranges. 30.0.0.100-120 is left out: it holds the
# hosts' untagged addresses on enp8s0f1 and the lab cloud's pool on the same VLAN.
POOLS=${SRIOV_POOLS:-"30.0.0.2-30.0.0.99 30.0.0.121-30.0.0.254"}
SHARED=${SRIOV_SHARED:-"yes"}

APPLY=no
[[ "${1:-}" == "--apply" ]] && APPLY=yes

function run {
    if [[ "${APPLY}" == "yes" ]]; then
        echo "+ $*"
        "$@"
    else
        echo "DRY RUN: $*"
    fi
}

function pool_args {
    local args=() p
    for p in ${POOLS}; do
        args+=(--allocation-pool "start=${p%-*},end=${p#*-}")
    done
    echo "${args[@]}"
}

openstack token issue -f value -c expires >/dev/null || {
    echo "No working OpenStack credentials; source an admin openrc first." >&2
    exit 1
}

echo "== network ${NET_NAME}"
if ! net_id=$(openstack network show "${NET_NAME}" -f value -c id 2>/dev/null); then
    share_flag=$([[ "${SHARED}" == "yes" ]] && echo --share || echo --no-share)
    run openstack network create "${NET_NAME}" \
        --provider-network-type vlan \
        --provider-physical-network "${PHYSNET}" \
        --provider-segment "${VLAN_ID}" \
        --mtu "${MTU}" --internal "${share_flag}"
    net_id=$(openstack network show "${NET_NAME}" -f value -c id 2>/dev/null || echo "<new>")
else
    read -r ptype pnet seg <<<"$(openstack network show "${NET_NAME}" -f value \
        -c provider:network_type -c provider:physical_network -c provider:segmentation_id | xargs)"
    if [[ "${ptype}/${pnet}/${seg}" != "vlan/${PHYSNET}/${VLAN_ID}" ]]; then
        echo "ERROR: ${NET_NAME} is ${ptype}/${pnet}/${seg}, expected vlan/${PHYSNET}/${VLAN_ID}." >&2
        echo "       Provider attributes cannot be changed; fix by hand." >&2
        exit 1
    fi
    share_flag=$([[ "${SHARED}" == "yes" ]] && echo --share || echo --no-share)
    run openstack network set "${net_id}" --internal "${share_flag}" --mtu "${MTU}"
fi

echo "== subnet ${SUBNET_NAME}"
if ! subnet_id=$(openstack subnet show "${SUBNET_NAME}" -f value -c id 2>/dev/null); then
    # shellcheck disable=SC2046
    run openstack subnet create "${SUBNET_NAME}" --network "${NET_NAME}" \
        --subnet-range "${CIDR}" --no-dhcp --gateway none $(pool_args)
else
    # Router interfaces cannot work on this network and hold the gateway address.
    for port in $(openstack port list --network "${net_id}" \
            --device-owner network:router_interface -f value -c ID); do
        router=$(openstack port show "${port}" -f value -c device_id)
        run openstack router remove port "${router}" "${port}"
    done
    # shellcheck disable=SC2046
    run openstack subnet set "${subnet_id}" --no-dhcp --gateway none \
        --no-allocation-pool $(pool_args)
fi

echo
echo "Network ID: ${net_id}"
echo "It must match voereir_sriov_net_id in etc/openstack_deploy/user_variables.yml,"
echo "which the Neutron policy uses to allow only direct (SR-IOV) ports on it."
