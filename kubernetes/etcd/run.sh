#!/bin/bash
ansible-playbook -i inventory cleanup-etcd.yml
ansible-playbook -i inventory install-etcd.yml
