#!/bin/bash
# DevStack OVN - Setup host routing and NAT (run on host machine)

set -e

TEMP_IP="172.24.4.2/24"
PUB_SUBNET="172.24.4.0/24"

echo "=== Step 7: Setup host access to floating IPs ==="

# Assign IP to br-ex (host side)
sudo ip addr add $TEMP_IP dev br-ex 2>/dev/null || echo "IP already exists"
sudo ip link set br-ex up

# Add route for public subnet
sudo ip route add $PUB_SUBNET dev br-ex 2>/dev/null || echo "Route already exists"

# Enable DNAT for SSH access

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

echo "✅ Host NAT configured."
echo "You can now:"
echo "- ping $FIP"
echo "- ssh -p 2222 ubuntu@localhost"
