#!/bin/bash
ansible-playbook playbooks/reset.yml
ansible-playbook playbooks/install.yml
