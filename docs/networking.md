# Networking

This document defines the network layout, addressing, naming, and storage networking requirements for the ProxSynQ lab environment.

## Table of Contents
- [1. Topology](#1-topology)
- [2. Address Plan and Hostnames](#2-address-plan-and-hostnames)
- [3. Name Resolution](#3-name-resolution)
- [4. Static IP Configuration](#4-static-ip-configuration)
- [5. SSH Access](#5-ssh-access)
- [6. Shared Storage Network](#6-shared-storage-network)
  - [6.1 GlusterFS Roles](#61-glusterfs-roles)
  - [6.2 GlusterFS Mounting with Failover](#62-glusterfs-mounting-with-failover)
  - [6.3 Permissions Model for Shared Storage](#63-permissions-model-for-shared-storage)
  - [6.4 Verification](#64-verification)
- [7. Required Ports](#7-required-ports)
- [8. Optional Heartbeat Broadcast](#8-optional-heartbeat-broadcast)
- [9. Troubleshooting](#9-troubleshooting)

---

## 1. Topology

The environment uses one private subnet for all nodes.

- A Raspberry Pi acts as an out-of-band management and monitoring node.
- Three Ubuntu VMs act as equal peers for storage and distributed execution.

All nodes must be reachable from each other on the lab network.

---

## 2. Address Plan and Hostnames

Subnet: 10.26.0.0/24  
Gateway: 10.26.0.1

| Node | Hostname | IP |
|---|---|---|
| RPi | COE892-RPi | 10.26.0.170 |
| VM1 | COE892-VM-1 | 10.26.0.171 |
| VM2 | COE892-VM-2 | 10.26.0.172 |
| VM3 | COE892-VM-3 | 10.26.0.173 |

---

## 3. Name Resolution

Each node maintains /etc/hosts entries so the cluster works without relying on external DNS.

Add on all nodes.

10.26.0.170 coe892-rpi COE892-RPi  
10.26.0.171 coe892-vm1 COE892-VM-1  
10.26.0.172 coe892-vm2 COE892-VM-2  
10.26.0.173 coe892-vm3 COE892-VM-3  

Verification commands.

sudo getent hosts coe892-rpi coe892-vm1 coe892-vm2 coe892-vm3  
ping -c 2 coe892-vm1

---

## 4. Static IP Configuration

### Ubuntu VMs (netplan)

VMs use netplan with systemd-networkd renderer.

Example netplan file structure.

network:  
  version: 2  
  renderer: networkd  
  ethernets:  
    <IFACE>:  
      dhcp4: no  
      addresses: [10.26.0.171/24]  
      gateway4: 10.26.0.1  
      nameservers:  
        addresses: [10.26.0.1,8.8.8.8]

Apply.

sudo netplan generate  
sudo netplan apply

### Raspberry Pi (client)

RPi can be managed via NetworkManager or dhcpcd depending on OS image. The environment also supports running a recovery script that configures hostname and IP based on role.

---

## 5. SSH Access

- All nodes should accept SSH on port 22.
- SSH keys are recommended for automation between nodes.
- If a key is passphrase protected, load it once per session with ssh-agent to avoid repeated prompts.

eval "$(ssh-agent -s)"  
ssh-add ~/.ssh/id_ed25519

The first connection to a new host will prompt to accept its host key. This is expected and should occur once per host unless the VM is rebuilt.

---

## 6. Shared Storage Network

Shared storage is provided by GlusterFS and mounted at /srv/proxsyncq/shared.

- Shared mount path: /srv/proxsyncq/shared
- Volume name: proxsyncqvol
- Brick path on each VM: /gluster/brick1/proxsyncq

### 6.1 GlusterFS Roles

- VM1, VM2, VM3 run glusterfs-server and host replicated bricks.
- RPi mounts the GlusterFS volume as a client for monitoring and to read cluster artifacts.

The storage is replicated across VM1, VM2, and VM3.

### 6.2 GlusterFS Mounting with Failover

Clients mount using a primary volfile server and one backup. The primary can be different per node so the environment does not depend on a single VM for mounting.

Recommended /etc/fstab lines.

VM1  
10.26.0.171:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.172 0 0

VM2  
10.26.0.172:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.173 0 0

VM3  
10.26.0.173:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.171 0 0

RPi  
10.26.0.172:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.173 0 0

This ensures mounts can still be established even if VM1 is down, as long as at least one of the specified volfile servers is reachable.

GlusterFS client setup notes and the brick port scheme are documented by GlusterFS. 

### 6.3 Permissions Model for Shared Storage

Use a shared group across nodes so files created by any VM remain writable by others.

On VM1, VM2, VM3.

sudo groupadd -f proxsyncq  
sudo usermod -aG proxsyncq krishadmin

Set the mount directory ownership and enable setgid so new files inherit the group.

sudo chown -R krishadmin:proxsyncq /srv/proxsyncq/shared  
sudo chmod 2775 /srv/proxsyncq/shared

Verification.

ls -ld /srv/proxsyncq/shared

Expected permissions resemble drwxrwsr-x and group proxsyncq.

### 6.4 Verification

Confirm the mount is glusterfs.

sudo findmnt /srv/proxsyncq/shared  
stat -f -c '%T  %m' /srv/proxsyncq/shared

Expected: fstype glusterfs and filesystem type fuse.glusterfs.

Create a proof file on one node and read it from others.

TS=$(date +%s)  
echo "from $(hostname) $TS" > /srv/proxsyncq/shared/proof_$(hostname)_$TS.txt  
sync

On another node.

ls -l /srv/proxsyncq/shared | tail -n 10  
cat /srv/proxsyncq/shared/proof_* | tail -n 5

---

## 7. Required Ports

All nodes should allow the following within the lab subnet.

- SSH: TCP 22
- GlusterFS management: TCP 24007
- GlusterFS brick ports: TCP 49152-49251 (common defaults) plus dynamically assigned brick ports
- GlusterFS self-heal and internal traffic: handled by glusterd and brick ports
- Application ports: defined by ProxSynQ services as implemented

If firewall rules are added later, restrict these ports to 10.26.0.0/24.

---

## 8. Optional Heartbeat Broadcast

A simple UDP broadcast can be used to show nodes announcing presence on the subnet.

Listener on one node.

nc -u -l -k 9999

Broadcaster loop on other nodes.

while true; do  
  echo "$(hostname) alive $(date -Iseconds)" | nc -u -b -w1 10.26.0.255 9999  
  sleep 1  
done

---

## 9. Troubleshooting

### 9.1 Mount looks local, not shared
If findmnt does not show glusterfs, the path is not mounted and writes are local. Mount again.

sudo umount /srv/proxsyncq/shared 2>/dev/null || true  
sudo mount /srv/proxsyncq/shared

### 9.2 Permission denied when writing to /srv/proxsyncq/shared
Ensure the shared directory ownership and setgid permissions were applied.

sudo chown -R krishadmin:proxsyncq /srv/proxsyncq/shared  
sudo chmod 2775 /srv/proxsyncq/shared

Ensure the user is in the proxsyncq group and re-login.

groups

### 9.3 Peer not connected
Check gluster peer status on a VM node.

sudo gluster peer status

If needed, probe again.

sudo gluster peer probe 10.26.0.172  
sudo gluster peer probe 10.26.0.173

### 9.4 RPi cannot mount glusterfs
Install the GlusterFS client.

sudo apt-get update  
sudo apt-get install -y glusterfs-client
