# =============================================================================
# SCM Provider - PAN-OS configuration via Strata Cloud Manager
#
# Configures the SCM folder (var.dgname) with the full firewall policy stack:
#   - Interface management profile (GWLB health check)
#   - Ethernet interfaces and sub-interfaces
#   - Security zones
#   - Logical router LR_default with VRF default and static routes
#   - Address object for 10/8
#   - Security rules (per-workload-zone for differentiated policy)
#   - NAT rule (interface SNAT)
#
# VPCE-to-sub-interface associations (plugin-op-commands) are handled via
# EC2 user-data and cannot be managed through SCM.
# =============================================================================

# ---------------------------------------------------------------------------
# SCM provider variables
# ---------------------------------------------------------------------------

variable "scm_client_id" {
  type        = string
  description = "SCM service account OAuth2 client ID"
}

variable "scm_client_secret" {
  type        = string
  sensitive   = true
  description = "SCM service account OAuth2 client secret"
}

variable "scm_scope" {
  type        = string
  description = "SCM OAuth2 scope (format: tsg_id:XXXXXXXXXX)"
}

# ---------------------------------------------------------------------------
# SCM provider
# ---------------------------------------------------------------------------

provider "scm" {
  client_id     = var.scm_client_id
  client_secret = var.scm_client_secret
  scope         = var.scm_scope
}

locals {
  folder = var.dgname
}

# ---------------------------------------------------------------------------
# Interface management profile - GWLB health check
# ---------------------------------------------------------------------------

resource "scm_interface_management_profile" "gwlb" {
  name   = "gwlb"
  folder = local.folder

  http         = true
  permitted_ip = [{ name = aws_subnet.gwlb.cidr_block }]
}

# ---------------------------------------------------------------------------
# Ethernet interfaces
# ---------------------------------------------------------------------------

resource "scm_ethernet_interface" "trust" {
  name   = var.panos_trust_iface
  folder = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = false
      send_hostname        = { enable = false }
    }
    interface_management_profile = scm_interface_management_profile.gwlb.name
  }
}

resource "scm_ethernet_interface" "untrust" {
  name   = var.panos_untrust_iface
  folder = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = true
    }
  }
}

# ---------------------------------------------------------------------------
# Sub-interfaces (GWLB VPC associations handled via user-data plugin-op-commands)
# ---------------------------------------------------------------------------

resource "scm_layer3_subinterface" "vpc1" {
  name             = var.panos_subif_vpc1
  parent_interface = var.panos_trust_iface
  folder           = local.folder
  tag              = 1
}

resource "scm_layer3_subinterface" "vpc2" {
  name             = var.panos_subif_vpc2
  parent_interface = var.panos_trust_iface
  folder           = local.folder
  tag              = 2
}

# ---------------------------------------------------------------------------
# Security zones
# ---------------------------------------------------------------------------

resource "scm_zone" "trust" {
  name   = var.panos_zone_trust
  folder = local.folder
  network = {
    layer3 = [var.panos_trust_iface]
  }
}

resource "scm_zone" "workload1" {
  name   = var.panos_zone_vpc1
  folder = local.folder
  network = {
    layer3 = [var.panos_subif_vpc1]
  }
}

resource "scm_zone" "workload2" {
  name   = var.panos_zone_vpc2
  folder = local.folder
  network = {
    layer3 = [var.panos_subif_vpc2]
  }
}

resource "scm_zone" "public" {
  name   = var.panos_zone_untrust
  folder = local.folder
  network = {
    layer3 = [var.panos_untrust_iface]
  }
}

# ---------------------------------------------------------------------------
# Address object
# ---------------------------------------------------------------------------

resource "scm_address" "rfc1918_10" {
  name       = "10.0.0.0_8"
  folder     = local.folder
  ip_netmask = "10.0.0.0/8"
}

# ---------------------------------------------------------------------------
# Logical router
# ---------------------------------------------------------------------------

resource "scm_logical_router" "main" {
  name   = "LR_default"
  folder = local.folder

  vrf = [
    {
      name      = "default"
      interface = [
        var.panos_trust_iface,
        var.panos_subif_vpc1,
        var.panos_subif_vpc2,
        var.panos_untrust_iface,
      ]
      routing_table = {
        ip = {
          static_route = [
            {
              name        = "10_8"
              destination = "10.0.0.0/8"
              interface   = var.panos_trust_iface
              nexthop     = { ip_address = cidrhost("172.16.2.0/24", 1) }
            },
            {
              name        = "gwlb_subnet"
              destination = aws_subnet.gwlb.cidr_block
              interface   = var.panos_trust_iface
              nexthop     = { ip_address = cidrhost("172.16.2.0/24", 1) }
            },
          ]
        }
      }
    }
  ]
}

# ---------------------------------------------------------------------------
# Security rules
# Separate rules per workload zone enable differentiated policy
# despite overlapping source IPs across VPCs
# ---------------------------------------------------------------------------

resource "scm_security_rule" "workload1_to_internet" {
  name   = "${var.panos_zone_vpc1}-to-internet"
  folder = local.folder

  from              = [var.panos_zone_vpc1]
  to                = [var.panos_zone_untrust]
  source            = [scm_address.rfc1918_10.name]
  destination       = [scm_address.rfc1918_10.name]
  negate_destination = true
  application       = ["any"]
  service           = ["any"]
  action            = "allow"
}

resource "scm_security_rule" "workload2_to_internet" {
  name   = "${var.panos_zone_vpc2}-to-internet"
  folder = local.folder

  from              = [var.panos_zone_vpc2]
  to                = [var.panos_zone_untrust]
  source            = [scm_address.rfc1918_10.name]
  destination       = [scm_address.rfc1918_10.name]
  negate_destination = true
  application       = ["any"]
  service           = ["any"]
  action            = "allow"
}

# ---------------------------------------------------------------------------
# NAT rule - interface SNAT on untrust
# ---------------------------------------------------------------------------

resource "scm_nat_rule" "workload_egress_snat" {
  name   = "workload-egress-snat"
  folder = local.folder

  from        = [var.panos_zone_vpc1, var.panos_zone_vpc2]
  to          = [var.panos_zone_untrust]
  source      = [scm_address.rfc1918_10.name]
  destination = ["any"]
  service     = "any"

  source_translation = {
    dynamic_ip_and_port = {
      interface_address = {
        interface = var.panos_untrust_iface
      }
    }
  }
}
