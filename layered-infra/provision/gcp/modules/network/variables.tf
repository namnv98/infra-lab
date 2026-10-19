variable "prefix" { type = string }
variable "region" { type = string }
variable "mtu" { type = number }
variable "zones" {
  description = "Vùng → { cidr }; vùng \"wan\" giữ đường ra Internet của GCP, các vùng khác thì không"
  type        = map(object({ cidr = string }))
}
