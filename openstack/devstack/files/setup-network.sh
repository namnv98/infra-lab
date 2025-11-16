#!/bin/bash
# DevStack OVN post-install - Network Setup
# Create public/private network + router

source /opt/stack/devstack/openrc admin demo
set -e

echo "=== Step 1: Create public network ==="
openstack network create public \
  --external \
  --provider-network-type flat \
  --provider-physical-network public

openstack subnet create public-subnet \
  --network public \
  --subnet-range 172.24.4.0/24 \
  --gateway 172.24.4.1 \
  --allocation-pool start=172.24.4.100,end=172.24.4.200 \
  --no-dhcp

echo "=== Step 2: Create private network ==="
openstack network create private

openstack subnet create private-subnet \
  --network private \
  --subnet-range 10.0.0.0/26 \
  --gateway 10.0.0.1 \
  --dns-nameserver 8.8.8.8

echo "=== Step 3: Create router ==="
openstack router create router1
openstack router set router1 --external-gateway public
openstack router add subnet router1 private-subnet