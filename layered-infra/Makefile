# Cửa vào chuẩn của dự án: `make <lệnh>`. Logic nằm ở lab.sh / Ansible / tofu — Makefile chỉ gọi lại.
# Gõ `make` (hoặc `make help`) để xem danh sách.
.DEFAULT_GOAL := help
.PHONY: help all plan up bootstrap cluster test lint fmt validate down cost vpn tunnel

TOFU := tofu -chdir=tofu/envs/gcp

help: ## Danh sách lệnh
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

all: up bootstrap cluster test ## Dựng từ đầu: hạ tầng → firewall → cluster → kiểm thử

plan: ## Xem trước thay đổi hạ tầng (kiểm tra plan.yml trước)
	./lab.sh plan

up: ## Tạo/cập nhật hạ tầng GCP (sinh config bootstrap OPNsense + tofu apply)
	./lab.sh up

bootstrap: ## 2 firewall mới tạo: console → VPN → cấu hình đầy đủ (site.yml --tags bootstrap,network)
	./lab.sh fw-bootstrap

cluster: ## K8s, addon, dịch vụ, app, bảo mật ‖ SIEM, backup
	./lab.sh cluster

test: ## Kiểm thử đầu-cuối trên lab đang chạy (cần VPN: make vpn)
	./test/smoke.sh

lint: ## yamllint + ansible-lint + tofu fmt + kiểm tra plan.yml
	yamllint -c .yamllint .
	cd ansible && ansible-lint
	tofu fmt -check -recursive tofu
	python3 scripts/plan.py check
	LAB_ENV=onprem python3 scripts/plan.py check

fmt: ## Tự định dạng code tofu
	tofu fmt -recursive tofu

validate: ## Kiểm tra cú pháp tofu + Ansible (không cần hạ tầng)
	$(TOFU) validate
	cd ansible && ansible-playbook site.yml --syntax-check
	cd ansible && ansible-playbook -i inventories/onprem/inventory.py site.yml --syntax-check

vpn: ## Bật VPN quản trị
	./lab.sh vpn up

tunnel: ## SOCKS 127.0.0.1:1080 qua jump-01 (trình duyệt, kubectl)
	./lab.sh tunnel up

cost: ## Tài nguyên còn lại trong project
	./lab.sh cost

down: ## XOÁ SẠCH hạ tầng (hỏi xác nhận)
	./lab.sh down
