# =============================================================================
# PAN-OS Terraform Provider — stub
#
# Alternative to SCM provider for direct device management.
# Uncomment and populate when using panos provider instead of or alongside SCM.
#
# Provider: https://registry.terraform.io/providers/PaloAltoNetworks/panos
# =============================================================================

# ---------------------------------------------------------------------------
# Add to required_providers in main.tf:
#
# panos = {
#   source  = "PaloAltoNetworks/panos"
#   version = "~> 2.0"
# }
# ---------------------------------------------------------------------------

# provider "panos" {
#   hostname = var.vmseries_mgmt_ip   # e.g. aws_eip.mgmt.public_ip
#   username = "admin"
#   password = var.vmseries_password
# }

# ---------------------------------------------------------------------------
# Interfaces
# ---------------------------------------------------------------------------

# resource "panos_ethernet_interface" "trust" {
#   name       = var.panos_trust_iface
#   vsys       = "vsys1"
#   mode       = "layer3"
#   enable_dhcp              = true
#   create_dhcp_default_route = false
# }

# resource "panos_ethernet_interface" "untrust" {
#   name       = var.panos_untrust_iface
#   vsys       = "vsys1"
#   mode       = "layer3"
#   enable_dhcp              = true
#   create_dhcp_default_route = true
# }

# ---------------------------------------------------------------------------
# Zones
# ---------------------------------------------------------------------------

# resource "panos_zone" "trust" {
#   name       = var.panos_zone_trust
#   mode       = "layer3"
#   interfaces = [var.panos_trust_iface]
# }

# resource "panos_zone" "workload1" {
#   name       = var.panos_zone_vpc1
#   mode       = "layer3"
#   interfaces = [var.panos_subif_vpc1]
# }

# resource "panos_zone" "workload2" {
#   name       = var.panos_zone_vpc2
#   mode       = "layer3"
#   interfaces = [var.panos_subif_vpc2]
# }

# resource "panos_zone" "public" {
#   name       = var.panos_zone_untrust
#   mode       = "layer3"
#   interfaces = [var.panos_untrust_iface]
# }

# ---------------------------------------------------------------------------
# Security rules
# ---------------------------------------------------------------------------

# resource "panos_security_rule_group" "workload_egress" {
#   rule {
#     name                  = "${var.panos_zone_vpc1}-to-internet"
#     source_zones          = [var.panos_zone_vpc1]
#     destination_zones     = [var.panos_zone_untrust]
#     source_addresses      = ["10.0.0.0/8"]
#     destination_addresses = ["10.0.0.0/8"]
#     negate_destination    = true
#     applications          = ["any"]
#     services              = ["any"]
#     action                = "allow"
#   }
#   rule {
#     name                  = "${var.panos_zone_vpc2}-to-internet"
#     source_zones          = [var.panos_zone_vpc2]
#     destination_zones     = [var.panos_zone_untrust]
#     source_addresses      = ["10.0.0.0/8"]
#     destination_addresses = ["10.0.0.0/8"]
#     negate_destination    = true
#     applications          = ["any"]
#     services              = ["any"]
#     action                = "allow"
#   }
# }

# ---------------------------------------------------------------------------
# NAT rule
# ---------------------------------------------------------------------------

# resource "panos_nat_rule_group" "workload_egress_snat" {
#   rule {
#     name = "workload-egress-snat"
#     original_packet {
#       source_zones      = [var.panos_zone_vpc1, var.panos_zone_vpc2]
#       destination_zone  = var.panos_zone_untrust
#       source_addresses  = ["10.0.0.0/8"]
#     }
#     translated_packet {
#       source {
#         dynamic_ip_and_port {
#           interface_address {
#             interface = var.panos_untrust_iface
#           }
#         }
#       }
#     }
#   }
# }
