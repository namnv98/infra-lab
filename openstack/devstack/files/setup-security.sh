#!/bin/bash
# DevStack OVN - Setup security group (ICMP + SSH)

source /opt/stack/devstack/openrc admin demo
set -e

echo "=== Step 6: Open ICMP + SSH ==="
SEC_GROUP_ID=$(openstack security group list --project $(openstack project show demo -f value -c id) -f value -c ID | head -n1)

openstack security group rule create --proto icmp $SEC_GROUP_ID || true
openstack security group rule create --proto tcp --dst-port 22 $SEC_GROUP_ID || true

echo "✅ Security group updated (ICMP + SSH allowed)."
