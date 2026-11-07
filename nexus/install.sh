#!/usr/bin/env bash
# Cài Nexus lên host trong inventory.ini [nexus]
set -euo pipefail
cd "$(dirname "$0")"
[[ -f inventory.ini ]] || { echo "Chưa có inventory.ini — cp inventory.example.ini inventory.ini rồi sửa host"; exit 1; }
ansible-playbook nexus.yml "$@"
