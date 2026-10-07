
locals {
  services_map = { for s in var.services : s.name => s }
}
