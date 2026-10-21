# Lệnh make của bộ tạo máy libvirt (máy nhà) — Makefile gốc tự nạp (-include provision/*/provision.mk). Xoá provision/libvirt/ là mất các lệnh này.
LIBVIRT := provision/libvirt/libvirt.sh
.PHONY: provision-libvirt libvirt-use libvirt-restore libvirt-image libvirt-console libvirt-stop libvirt-start libvirt-status libvirt-down libvirt-purge

provision-libvirt: ## [libvirt] Tạo mạng + VM còn thiếu theo hosts.yml → nạp config bootstrap vào firewall mới qua console
	$(LIBVIRT) up

libvirt-use: ## [libvirt] Chuyển lab sang máy nhà: chép provisioned.yml (IP public + biến riêng máy nhà), cất out/ cũ
	$(LIBVIRT) use

libvirt-restore: ## [libvirt] Quay về môi trường trước libvirt-use (vd. GCP): trả lại inventory + out/
	$(LIBVIRT) restore

libvirt-image: ## [libvirt] 1 lần: tải OPNsense nano + Ubuntu 24.04 cloud image vào pool (provision tự gọi nếu thiếu)
	$(LIBVIRT) image

libvirt-console: ## [libvirt] Console nối tiếp firewall (cứu hộ khi mất VPN): make libvirt-console FW=core
	$(LIBVIRT) console $(FW)

libvirt-stop: ## [libvirt] TẮT lab theo tầng, giữ đĩa. Từng máy: make libvirt-stop ONLY="siem-01 edge-01"
	$(LIBVIRT) stop $(ONLY)

libvirt-start: ## [libvirt] BẬT lại theo thứ tự firewall → jump → infra → master → worker → còn lại
	$(LIBVIRT) start $(ONLY)

libvirt-status: ## [libvirt] VM + mạng của lab
	$(LIBVIRT) status

libvirt-down: ## [libvirt] XOÁ VM, đĩa, mạng của lab (hỏi xác nhận), giữ image gốc
	$(LIBVIRT) down

libvirt-purge: ## [libvirt] GỠ SẠCH: down + image gốc + kết nối VPN + trạng thái máy nhà trong out/ (hỏi xác nhận)
	$(LIBVIRT) purge
