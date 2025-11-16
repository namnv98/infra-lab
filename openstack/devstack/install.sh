#!/bin/bash

ansible-playbook -i inventory.ini remove-devstack.yml

ansible-playbook -i inventory.ini install-devstack.yml

#tail -n 1000 /opt/stack/logs/stack.sh.log  -f

#https://github.com/openstack/trove/blob/master/doc/source/install/install-devstack.rst


#openstack server list --all-projects
#openstack console log show <vm-id>
#openstack server delete <nova_server_id> --force
