#!/bin/bash

ansible-playbook -i inventory.ini remove-devstack.yml

ansible-playbook -i inventory.ini install-devstack.yml

#tail -n 1000 /opt/stack/logs/stack.sh.log  -f