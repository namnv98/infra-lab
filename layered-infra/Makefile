# Cửa vào chuẩn của dự án: `make <lệnh>`. Không quan tâm máy chạy ở đâu: mọi IP ở ansible/shared/inventory/hosts.yml.
# 2 lớp tách rời:
#   [tạo máy]   make provision — tuỳ chọn, bộ tạo máy ở provision/<nền tảng>/ (đang có: gcp); không có thì tự tạo máy đúng hosts.yml
#   [cấu hình]  make fw-config → (nạp vào firewall) → make bootstrap → make cluster → make test — chỉ đọc hosts.yml
# Gõ `make` (hoặc `make help`) để xem danh sách.
.DEFAULT_GOAL := help
# Bộ tạo máy: thư mục provision/<tên>/ có provision.mk (xoá thư mục đó = không còn bộ tạo máy, tự tạo máy bằng cách khác)
PROVISIONER ?= $(notdir $(patsubst %/,%,$(dir $(firstword $(wildcard provision/*/provision.mk)))))
TEAMS := network platform observability   # ansible/<team>/site.yml — mỗi team một thư mục, chung hợp đồng ansible/shared/
.PHONY: help all fw-config provision bootstrap cluster test lint fmt validate vpn tunnel $(TEAMS)

help: ## Danh sách lệnh
	@echo "Bộ tạo máy: $(or $(PROVISIONER),(không có — tự tạo máy đúng ansible/shared/inventory/hosts.yml))"
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

all: fw-config provision bootstrap cluster test ## Dựng từ đầu: config firewall → tạo máy → firewall → cluster → kiểm thử

fw-config: ## Sinh config bootstrap 2 OPNsense từ hosts.yml vào out/ (trước khi tạo/nạp firewall)
	./lab.sh fw-config

provision: ## Tạo máy đúng hosts.yml bằng bộ tạo máy (provision/$(PROVISIONER)/); không có bộ tạo máy thì in việc cần tự làm
ifneq ($(PROVISIONER),)
	$(MAKE) provision-$(PROVISIONER)
else
	@echo "Không có bộ tạo máy (provision/<tên>/provision.mk). Tự chuẩn bị:"
	@echo "  1) máy chạy đúng tên/IP trong ansible/shared/inventory/hosts.yml (Ubuntu 24.04, user ubuntu sudo không mật khẩu, khoá SSH của máy này)"
	@echo "  2) 2 firewall cài OPNsense + nạp out/opnsense-<edge|core>-bootstrap.xml (USB /conf/config.xml hoặc console)"
	@echo "  3) IP public của biên: fw_public_ip, vpn_public_ip trong hosts.yml"
	@echo "Xong thì: make bootstrap"
endif

bootstrap: ## 2 firewall đã nạp config: API biên qua IP public → VPN → cấu hình đầy đủ (network/site.yml --tags bootstrap,firewall)
	./lab.sh fw-bootstrap

cluster: ## Dựng toàn bộ, điều phối 3 team: network → platform → network (biên) → platform ‖ observability → backup
	./lab.sh cluster

network: ## [team network] firewall, VPN, bastion, DNS/NTP, Squid, vùng biên — thêm tham số: make network ARGS='--tags firewall'
	./lab.sh network $(ARGS)

platform: ## [team platform] K8s, addon, Harbor/S3, app, bảo mật cluster, Prometheus, backup
	./lab.sh platform $(ARGS)

observability: ## [team observability] SIEM, bản sao log, agent log/audit/Wazuh mọi máy
	./lab.sh observability $(ARGS)

test: ## Kiểm thử đầu-cuối trên lab đang chạy (cần VPN: make vpn)
	./test/smoke.sh

vpn: ## Bật VPN quản trị
	./lab.sh vpn up

tunnel: ## SOCKS 127.0.0.1:1080 qua jump-01 (trình duyệt, kubectl)
	./lab.sh tunnel up

lint: ## yamllint + ansible-lint + tofu fmt + kiểm tra IP trong hosts.yml
	yamllint -c .yamllint .
	cd ansible && ansible-lint
	$(if $(wildcard provision/*/*.tf),tofu fmt -check -recursive provision)
	python3 -I scripts/inventory.py check

fmt: ## Tự định dạng code tofu (bộ tạo máy)
	$(if $(wildcard provision/*/*.tf),tofu fmt -recursive provision)

validate: ## Kiểm tra cú pháp Ansible mọi team (+ tofu của bộ tạo máy nếu có) — không cần hạ tầng
	@for t in $(TEAMS); do echo "== $$t"; (cd ansible && ansible-playbook $$t/site.yml --syntax-check) || exit 1; done
	$(if $(wildcard provision/gcp/*.tf),tofu -chdir=provision/gcp validate)

# Lệnh riêng của bộ tạo máy (vd. make gcp-stop) — xoá provision/<tên>/ là mất các lệnh đó, phần trên không đổi
-include provision/*/provision.mk
