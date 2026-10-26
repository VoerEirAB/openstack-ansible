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
