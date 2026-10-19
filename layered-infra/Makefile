# Cửa vào chuẩn của dự án: `make <lệnh>` — GIỐNG NHAU mọi môi trường (ENV=gcp mặc định; ENV=onprem, ENV=<tên> …).
# 2 lớp tách rời:
#   [tạo máy]   make provision — tuỳ chọn, theo môi trường (provision/<env>/); không có thì tự tạo máy đúng envs/<env>/plan.yml
#   [cấu hình]  make fw-config → (nạp vào firewall) → make bootstrap → make cluster → make test — chỉ đọc plan.yml
# Gõ `make` (hoặc `make help`) để xem danh sách.
.DEFAULT_GOAL := help
ENV ?= gcp
export LAB_ENV := $(ENV)
ENVS := $(notdir $(wildcard envs/*))
.PHONY: help all fw-config provision bootstrap cluster test lint fmt validate vpn tunnel

help: ## Danh sách lệnh
	@echo "Môi trường: ENV=$(ENV) (có: $(ENVS))"
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

all: fw-config provision bootstrap cluster test ## Dựng từ đầu: config firewall → tạo máy → firewall → cluster → kiểm thử

fw-config: ## Sinh config bootstrap 2 OPNsense từ plan.yml vào out/$(ENV)/ (trước khi tạo/nạp firewall)
	./lab.sh fw-config

provision: provision-$(ENV) ## Tạo máy theo plan.yml bằng bộ tạo máy của môi trường (provision/$(ENV)/)

# Môi trường không có bộ tạo máy: máy tạo bằng cách khác — chỉ nhắc hợp đồng
provision-%:
	@echo "Môi trường '$*' không có bộ tạo máy (provision/$*/). Tự chuẩn bị:"
	@echo "  1) máy chạy đúng tên/IP trong envs/$*/plan.yml (Ubuntu 24.04, user ubuntu sudo không mật khẩu, khoá SSH của máy này)"
	@echo "  2) 2 firewall cài OPNsense + nạp out/$*/opnsense-<edge|core>-bootstrap.xml (USB /conf/config.xml hoặc console)"
	@echo "  3) IP public của biên: public: { web: …, vpn: … } trong envs/$*/plan.yml"
	@echo "Xong thì: make bootstrap ENV=$*"

bootstrap: ## 2 firewall đã nạp config: API biên qua IP public → VPN → cấu hình đầy đủ (site.yml --tags bootstrap,network)
	./lab.sh fw-bootstrap

cluster: ## K8s, addon, dịch vụ, app, bảo mật ‖ SIEM, backup
	./lab.sh cluster

test: ## Kiểm thử đầu-cuối trên lab đang chạy (cần VPN: make vpn)
	./test/smoke.sh

vpn: ## Bật VPN quản trị
	./lab.sh vpn up

tunnel: ## SOCKS 127.0.0.1:1080 qua jump-01 (trình duyệt, kubectl)
	./lab.sh tunnel up

lint: ## yamllint + ansible-lint + tofu fmt + kiểm tra plan.yml của mọi môi trường
	yamllint -c .yamllint .
	cd ansible && ansible-lint
	$(if $(wildcard provision/*/*.tf),tofu fmt -check -recursive provision)
	@for e in $(ENVS); do LAB_ENV=$$e python3 scripts/plan.py check || exit 1; done

fmt: ## Tự định dạng code tofu (bộ tạo máy)
	$(if $(wildcard provision/*/*.tf),tofu fmt -recursive provision)

validate: ## Kiểm tra cú pháp Ansible mọi môi trường (+ tofu của bộ tạo máy nếu có) — không cần hạ tầng
	@for e in $(ENVS); do echo "== $$e"; (cd ansible && ansible-playbook -i inventories/$$e/inventory.py site.yml --syntax-check) || exit 1; done
	$(if $(wildcard provision/gcp/*.tf),tofu -chdir=provision/gcp validate)

# Lệnh riêng của từng bộ tạo máy (vd. make gcp-stop) — xoá provision/<env>/ là mất các lệnh đó, phần trên không đổi
-include provision/*/provision.mk
