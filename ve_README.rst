Deploy openstack Antelope using openstack-ansible

1. Clone the project

git clone -b stable/2023.1 https://opendev.org/openstack/openstack-ansible

/usr/bin/python3.8 -m venv venv
source  venv/bin/activate
sudo scripts/bootstrap-ansible.sh

2. Create bridge and bind br-mgmt with eno2 interface
Creare bridge br-mgmt using the netplan config attached to the story.

3. Create pools and keyrings for the openstack services.

```
Create pools for openstack services.

sudo ceph osd pool create volumes 128
sudo ceph osd pool application enable volumes rbd
sudo rbd pool init -p volumes

sudo ceph osd pool create images 128
sudo ceph osd pool application enable images rbd
sudo rbd pool init -p images

sudo ceph osd pool create vms 128
sudo ceph osd pool application enable vms rbd
sudo rbd pool init -p vms



Create keyrings for the pools

sudo ceph auth get-or-create client.cinder mon 'profile rbd' osd 'profile rbd pool=volumes, profile rbd pool=vms, allow class-read object_prefix rbd_children' -o /etc/ceph/ceph.client.cinder.keyring
sudo ceph auth get-or-create client.glance mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=images' -o /etc/ceph/ceph.client.glance.keyring

```

client.cinder (used by Nova and Cinder) needs mon 'profile rbd': with only
mon 'allow r' it cannot blocklist a dead client, so a stale RBD exclusive lock
(left by a crashed QEMU) is never broken and VMs or volume deletes hang.
To fix an existing key: sudo ceph auth caps client.cinder <same caps as above>

4. Run the playbook mention below in sequence.

Files changes:
1. ~/openstack-ansible/roles/zookeeper/templates/zoo.cfg.j2 -> admin.serverPort=8081

```
sudo openstack-ansible playbooks/setup-hosts.yml -vv
sudo openstack-ansible playbooks/setup-infrastructure.yml -vv -e galera_ignore_cluster_state=true -e galera_upgrade=true
sudo openstack-ansible playbooks/setup-openstack.yml -vv -e galera_address=172.16.227.129 -e _oslodb_setup_endpoint=172.16.227.129

```

5. SR-IOV network (sriov-net)

Host side: each compute has 16 VFs on enp8s0f1 (virtual-function-count in
netplan, see etc/netplan/antelope/). OSA side: network_sriov_mappings,
nova_pci_passthrough_whitelist and the sriov-net Neutron policy in
etc/openstack_deploy/user_variables.yml.

```
source <admin openrc>
scripts/voereir/sriov-net-setup.sh            # dry run
scripts/voereir/sriov-net-setup.sh --apply    # create / reconcile sriov-net
```

If sriov-net is (re)created, put its ID in voereir_sriov_net_id in
user_variables.yml and rerun os-neutron-install.yml, otherwise the policy that
allows only direct ports on it points at the wrong network.

Boot VMs on it with a direct port and a config drive (no DHCP, no gateway):

```
scripts/voereir/sriov-vm-create.sh <name> <image> <flavor> [keypair]
EXTRA_NETWORK=private scripts/voereir/sriov-vm-create.sh ...   # plus a normal NIC
```

When a server fails with "No valid host was found", see why on voereir11 (the
host running nova-scheduler). It prints what the server asked for, which
scheduler filter removed the hosts and the reason for each host, and works for
servers Heat has already deleted:

```
sudo scripts/voereir/why-no-valid-host.sh <server name or UUID>
sudo SINCE="2 weeks ago" scripts/voereir/why-no-valid-host.sh <server name or UUID>
```

Routing between SR-IOV networks (sriov-router)
----------------------------------------------

sriov-router routes between sriov-net (VLAN 1000, 30.0.0.0/24) and
sriov-net-bose (VLAN 1001, 30.0.1.0/24). A Neutron router lives on the network
node (voereir11) and plugs in through OVS, so voereir11's OVS maps sriovnet1 to
br-vlan on enp8s0f1 (host_vars of infra1 in openstack_user_config.yml). The
computes keep only physnet1 in OVS; their VMs use VFs. Order of work:

1. Switch (voereir_switch, Dell OS9): VLAN 1001 has no member ports, so
   sriov-net-bose traffic never leaves a host. Tag it like VLAN 1000 on the
   enp8s0f1 ports of voereir11, 13, 14 and 15:

```
configure
interface vlan 1001
 tagged twentyFiveGigE 1/13,1/15-1/17
end
write memory
```

2. voereir11 OVS, with OSA from a deploy host:

```
openstack-ansible os-neutron-install.yml --limit infra1
```

   or by hand on voereir11 (same result; no deploy host needed). Copy
   etc/netplan/antelope/voereir11/50-cloud-init.yaml to /etc/netplan/ (no
   netplan apply), then drop the old address and add the bridge:

```
sudo ip addr flush dev enp8s0f1
sudo ip rule del from 30.0.0.0/24 lookup 3 priority 100
sudo ip rule del from 30.0.0.0/24 to 30.0.0.0/24 lookup main
sudo ip route flush table 3
sudo ovs-vsctl --may-exist add-br br-vlan -- set bridge br-vlan fail_mode=secure
sudo ovs-vsctl --may-exist add-port br-vlan enp8s0f1
sudo sed -i 's/^bridge_mappings = physnet1:br-flat$/bridge_mappings = physnet1:br-flat,sriovnet1:br-vlan/' /etc/neutron/plugins/ml2/openvswitch_agent.ini
sudo systemctl restart neutron-openvswitch-agent neutron-dhcp-agent
```

   The OVS agent on voereir11 should now report
   bridge_mappings {"physnet1": "br-flat", "sriovnet1": "br-vlan"}, and
   sriov-net-bose's DHCP port should go from binding_failed to ACTIVE.

3. Router, with an admin openrc (the sriov-net policy lets only admins create
   its non-direct router port; members still get direct ports only):

```
scripts/voereir/sriov-router-setup.sh            # dry run
scripts/voereir/sriov-router-setup.sh --apply    # create / reconcile sriov-router
```

   It attaches sriov-net-bose on its gateway 30.0.1.1, gives the router
   30.0.0.1 on sriov-net and adds a host route 30.0.1.0/24 via 30.0.0.1 to
   sriov-net's subnet, which new VMs get from the config drive. VMs already
   running on sriov-net need "ip route add 30.0.1.0/24 via 30.0.0.1".

Rollback on voereir11: "sudo ovs-vsctl del-br br-vlan", put bridge_mappings back
to physnet1:br-flat, restart neutron-openvswitch-agent, restore the old
netplan file from git and re-add 30.0.0.111/24 to enp8s0f1.
