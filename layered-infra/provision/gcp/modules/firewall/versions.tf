terraform {
  required_providers {
    google      = { source = "hashicorp/google" }
    google-beta = { source = "hashicorp/google-beta" } # target instance chọn card WAN (tham số network còn beta)
  }
}
