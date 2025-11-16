#!/bin/bash
# DevStack OVN - Create VM and assign floating IP

source /opt/stack/devstack/openrc admin demo
set -e

VM_NAME=${1:-test-vm}

echo "=== Step 1: Create VM ==="
SEC_GROUP_ID=$(openstack security group list -f value -c ID \
  --project $(openstack project show demo -f value -c id) | head -n1)

NET_ID=$(openstack network show private -f value -c id)

# Tạo VM nhưng chưa gán floating IP
openstack server create --flavor m1.small --image ubuntu-22.04-server-cloudimg-amd64 \
  --nic net-id=$NET_ID \
  --security-group $SEC_GROUP_ID \
  $VM_NAME

# --- Chờ VM ở trạng thái ACTIVE ---
echo "Waiting for VM $VM_NAME to become ACTIVE..."
openstack server list --name $VM_NAME -f value -c Status | grep -q ACTIVE || \
  until [ "$(openstack server show $VM_NAME -f value -c status)" == "ACTIVE" ]; do
    sleep 2
    echo "Waiting..."
  done

echo "=== Step 2: Allocate floating IP ==="
FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip $VM_NAME $FIP

sudo iptables -t nat -C PREROUTING -p tcp --dport 2222 -j DNAT --to-destination $FIP:22 2>/dev/null || \
sudo iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination $FIP:22

