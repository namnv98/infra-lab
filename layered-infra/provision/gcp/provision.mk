# Lệnh make của bộ tạo máy GCP — Makefile gốc tự nạp (-include provision/*/provision.mk). Xoá provision/gcp/ là mất các lệnh này.
GCP := provision/gcp/gcp.sh
.PHONY: provision-gcp gcp-plan gcp-image gcp-console gcp-stop gcp-start gcp-down gcp-cost

provision-gcp: ## [gcp] tofu apply → ghi IP public (provisioned.yml) → nạp config bootstrap vào firewall mới
	$(GCP) up

gcp-plan: ## [gcp] Xem trước thay đổi hạ tầng (kiểm tra hosts.yml trước)
	$(GCP) plan

gcp-image: ## [gcp] 1 lần: golden image OPNsense dựng ngay trên GCP (~5 phút)
	$(GCP) image

gcp-console: ## [gcp] Console nối tiếp firewall (cứu hộ khi mất VPN): make gcp-console FW=core
	$(GCP) console $(FW)

gcp-stop: ## [gcp] TẮT VM, giữ cấu hình (~0,07 USD/giờ khi tắt). Từng máy: make gcp-stop ONLY="siem-01 edge-01"
	$(GCP) stop $(ONLY)

gcp-start: ## [gcp] BẬT lại theo thứ tự firewall → jump → infra → master → worker → còn lại (chờ từng tầng sẵn sàng)
	$(GCP) start $(ONLY)

gcp-down: ## [gcp] XOÁ SẠCH hạ tầng (hỏi xác nhận)
	$(GCP) down

gcp-cost: ## [gcp] Tài nguyên còn lại trong project
	$(GCP) cost
