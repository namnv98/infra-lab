#!/usr/bin/env bash
# Cài Jenkins lên các host trong inventory.ini [jenkins_controller] / [jenkins_agents]
set -euo pipefail
cd "$(dirname "$0")"
[[ -f inventory.ini ]] || { echo "Chưa có inventory.ini — cp inventory.example.ini inventory.ini rồi sửa host"; exit 1; }
ansible-playbook jenkins.yml "$@"
