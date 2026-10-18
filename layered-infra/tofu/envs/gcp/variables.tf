variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

variable "prefix" {
  type    = string
  default = "lab"
}

variable "opnsense_image" {
  description = "Image OPNsense tự đưa lên (./lab.sh image)"
  type        = string
  default     = "opnsense-26-7-nano"
}

variable "ssh_pubkey_file" {
  description = "Khoá SSH công khai cho user ubuntu trên mọi VM Linux (giống lab local)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# Vùng, firewall, VM, route: KHÔNG khai báo ở đây — đọc từ envs/gcp/plan.yml (main.tf, locals)
