ansible-playbook -i inventories/hosts uninstall.yml
ansible-playbook -i inventories/hosts install-kafka.yml



#sudo systemctl status kafka
#sudo journalctl -u kafka -f