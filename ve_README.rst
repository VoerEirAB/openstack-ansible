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

sudo ceph auth get-or-create client.cinder mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=volumes, allow rwx pool=vms' -o /etc/ceph/ceph.client.cinder.keyring 
sudo ceph auth get-or-create client.glance mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=images' -o /etc/ceph/ceph.client.glance.keyring

```

4. Run the playbook mention below in sequence.

Files changes:
1. ~/openstack-ansible/roles/zookeeper/templates/zoo.cfg.j2 -> admin.serverPort=8081

```
sudo openstack-ansible playbooks/setup-hosts.yml -vv
sudo openstack-ansible playbooks/setup-infrastructure.yml -vv -e galera_ignore_cluster_state=true -e galera_upgrade=true
sudo openstack-ansible playbooks/setup-openstack.yml -vv -e galera_address=172.16.227.129 -e _oslodb_setup_endpoint=172.16.227.129

```
