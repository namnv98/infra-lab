#!/bin/bash

#ansible-playbook -i inventory.ini remove-devstack.yml

ansible-playbook -i inventory.ini install-devstack.yml

#ansible-playbook -i inventory.ini change_ip.yml



#export TERM=xterm

#c
#openstack server show vm-01 -f yaml | grep -i addresses


#openstack network set --qos-policy limit-01 public