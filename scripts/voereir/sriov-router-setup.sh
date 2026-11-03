#!/usr/bin/env bash
#
# Create or reconcile "sriov-router" on antelope: routes between the SR-IOV
# networks sriov-net (VLAN 1000) and sriov-net-bose (VLAN 1001).
#
#   No external gateway. sriov-net has no gateway on purpose (VMs boot from a
#   config drive), so the router gets a fixed port there (30.0.0.1, outside the
#   allocation pools) and sriov-net's subnet gets a host route to
#   sriov-net-bose through it. sriov-net-bose is attached through its subnet
#   gateway (30.0.1.1), so it is its VMs' default route.
#
#   Needs the network node (voereir11) to map sriovnet1 in OVS (br-vlan on
#   enp8s0f1) and the switch to carry both VLANs; otherwise the router ports
#   end up binding_failed. See "Routing between SR-IOV networks" in
#   ve_README.rst.
#
# Usage: source an admin openrc, then
#   scripts/voereir/sriov-router-setup.sh            # dry run: show what would change
#   scripts/voereir/sriov-router-setup.sh --apply    # create / reconcile
#
# Every value can be overridden through the environment, for example
#   SRIOV_ROUTER_NET_B=other-net scripts/voereir/sriov-router-setup.sh --apply

set -euo pipefail

ROUTER=${SRIOV_ROUTER_NAME:-"sriov-router"}
NET_A=${SRIOV_ROUTER_NET_A:-"sriov-net"}
NET_A_SUBNET=${SRIOV_ROUTER_NET_A_SUBNET:-"sriov-net"}
# Router address on NET_A, which has no gateway of its own.
NET_A_ROUTER_IP=${SRIOV_ROUTER_NET_A_IP:-"30.0.0.1"}
NET_B=${SRIOV_ROUTER_NET_B:-"sriov-net-bose"}
NET_B_SUBNET=${SRIOV_ROUTER_NET_B_SUBNET:-"sriov-net-bose"}

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

openstack token issue -f value -c expires >/dev/null || {
    echo "No working OpenStack credentials; source an admin openrc first." >&2
    exit 1
}

echo "== router ${ROUTER}"
if ! router_id=$(openstack router show "${ROUTER}" -f value -c id 2>/dev/null); then
    run openstack router create "${ROUTER}" \
        --description "Routes between ${NET_A} and ${NET_B} (SR-IOV VLANs)"
    router_id=$(openstack router show "${ROUTER}" -f value -c id 2>/dev/null || echo "${ROUTER}")
else
    echo "exists: ${router_id}"
fi

# Router ports already on a subnet, as "subnet_id ip" lines.
function router_ips {
    openstack port list --router "${router_id}" -f value -c "Fixed IP Addresses" 2>/dev/null \
        | grep -o "'subnet_id': '[^']*', 'ip_address': '[^']*'" \
        | sed -E "s/'subnet_id': '([^']*)', 'ip_address': '([^']*)'/\1 \2/" || true
}

echo "== ${NET_A}: router port ${NET_A_ROUTER_IP}"
subnet_a=$(openstack subnet show "${NET_A_SUBNET}" -f value -c id)
if router_ips | grep -q "^${subnet_a} "; then
    echo "attached: $(router_ips | grep "^${subnet_a} ")"
else
    port_name="${ROUTER}-${NET_A}"
    if ! openstack port show "${port_name}" -f value -c id >/dev/null 2>&1; then
        run openstack port create "${port_name}" --network "${NET_A}" \
            --fixed-ip "subnet=${subnet_a},ip-address=${NET_A_ROUTER_IP}"
    fi
    run openstack router add port "${ROUTER}" "${port_name}"
fi

echo "== ${NET_B}: router on the subnet gateway"
subnet_b=$(openstack subnet show "${NET_B_SUBNET}" -f value -c id)
cidr_b=$(openstack subnet show "${NET_B_SUBNET}" -f value -c cidr)
gateway_b=$(openstack subnet show "${NET_B_SUBNET}" -f value -c gateway_ip)
if router_ips | grep -q "^${subnet_b} "; then
    echo "attached: $(router_ips | grep "^${subnet_b} ")"
elif [[ -z "${gateway_b}" || "${gateway_b}" == "None" ]]; then
    echo "${NET_B_SUBNET} has no gateway_ip; set one or attach a port by hand." >&2
    exit 1
else
    run openstack router add subnet "${ROUTER}" "${NET_B_SUBNET}"
fi

echo "== ${NET_A_SUBNET}: host route to ${cidr_b} via ${NET_A_ROUTER_IP}"
if openstack subnet show "${NET_A_SUBNET}" -f value -c host_routes | grep -q "${cidr_b}"; then
    echo "present: $(openstack subnet show "${NET_A_SUBNET}" -f value -c host_routes)"
else
    run openstack subnet set "${NET_A_SUBNET}" \
        --host-route "destination=${cidr_b},gateway=${NET_A_ROUTER_IP}"
fi

echo "== router ports"
if [[ "${APPLY}" == "yes" ]]; then
    for port in $(openstack port list --router "${router_id}" -f value -c ID); do
        echo "${port} $(openstack port show "${port}" -f value \
            -c status -c binding_vif_type -c binding_host_id | tr '\n' ' ')"
    done
    cat <<EOF
Each port should be ACTIVE with binding_vif_type "ovs" on the network node.
"binding_failed" means the network node's OVS has no sriovnet1 mapping yet.
VMs on ${NET_A} that booted before the host route was added need the route
by hand:  ip route add ${cidr_b} via ${NET_A_ROUTER_IP}
EOF
fi
