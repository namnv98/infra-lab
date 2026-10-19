variable "zone" { type = string }

variable "image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "vms" {
  description = "Tên VM → { zone, ip, type, disk, alias (IP phụ /32) }"
  type = map(object({
    zone  = string
    ip    = string
    type  = string
    disk  = number
    alias = list(string)
  }))
}

variable "subnet_ids" { type = map(string) }
variable "ssh_pubkey" { type = string }
