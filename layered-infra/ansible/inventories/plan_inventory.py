#!/usr/bin/env python3
"""Inventory Ansible sinh từ plan.yml — DÙNG CHUNG mọi môi trường: mỗi inventories/<env>/inventory.py là symlink tới file này;
tên thư mục chứa symlink = tên môi trường → đọc envs/<env>/plan.yml (+ provisioned.yml) bằng scripts/plan.py. Không ghi IP/tên máy ở chỗ khác.

Nhóm theo VAI TRÒ (hosts.*.groups) + nhóm cha (k8s, linux) + nhóm theo VÙNG (zone_<vùng>) + firewalls.
Biến: ansible_host từng VM; `plan` (toàn bộ plan.yml) + `lab_env` (tên môi trường) cho mọi máy — group_vars đọc IP từ đây.
Kiểm tra:  ansible-inventory --graph   ·   ansible-inventory --host k8s-master-01
"""
import json, pathlib, sys

ENV_DIR = pathlib.Path(__file__).absolute().parent   # absolute, KHÔNG resolve: giữ thư mục của symlink (ansible/inventories/<env>) → gốc dự án = parents[2]
sys.path.insert(0, str(ENV_DIR.parents[2] / "scripts"))
import plan as planlib  # noqa: E402
plan = planlib.load(ENV_DIR.name)
PARENTS = {"k8s": ["k8s_control_plane", "k8s_workers"]}   # nhóm cha: nhóm con theo vai trò


def inventory():
    inv = {"_meta": {"hostvars": {}}, "all": {"children": ["firewalls", "linux"], "vars": {"plan": plan, "lab_env": ENV_DIR.name}},
           "firewalls": {"hosts": list(plan["firewalls"])}}
    roles = {}
    for name, h in plan["hosts"].items():
        inv["_meta"]["hostvars"][name] = {"ansible_host": h["ip"]}
        for g in h["groups"]:
            roles.setdefault(g, []).append(name)
        inv.setdefault(f"zone_{h['zone']}", {"hosts": []})["hosts"].append(name)
    for g, hosts in roles.items():
        inv[g] = {"hosts": hosts}
    for parent, kids in PARENTS.items():
        inv[parent] = {"children": [k for k in kids if k in roles]}
    in_parent = {k for kids in PARENTS.values() for k in kids}
    inv["linux"] = {"children": list(PARENTS) + [g for g in roles if g not in in_parent]}
    return inv


if __name__ == "__main__":
    if sys.argv[1:2] == ["--host"]:
        print(json.dumps({}))
    else:
        print(json.dumps(inventory(), ensure_ascii=False, indent=1))
