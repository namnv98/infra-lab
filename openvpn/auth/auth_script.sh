#!/bin/bash

CREDENTIAL_FILE="$1"
PASSWD_FILE="/etc/openvpn/users.htpasswd"
LOG_FILE="/var/log/openvpn-auth.log"

ts() { date +"%F %T"; }

username=$(head -n1 "$CREDENTIAL_FILE" | tr -d '\r\n')
password=$(tail -n1 "$CREDENTIAL_FILE" | tr -d '\r\n')

if htpasswd -vb "$PASSWD_FILE" "$username" "$password" &>/dev/null; then
  echo "$(ts) | SUCCESS: $username" >> "$LOG_FILE"
  exit 0
else
  echo "$(ts) | FAIL: $username" >> "$LOG_FILE"
  exit 1
fi