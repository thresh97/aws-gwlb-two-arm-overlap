# =============================================================================
# SCM Provider - PAN-OS policy configuration via Strata Cloud Manager
#
# Manages the SCM folder (var.dgname) with policy-layer objects:
#   - Interface management profile (GWLB health check)
#   - Security zones (logical policy labels)
#   - Logical router LR_default with static routes
#   - Address object for 10/8
#   - Security rules (per-workload-zone for differentiated policy)
#   - NAT rule (interface SNAT)
#
# NOT managed here:
#   - Interface-to-zone binding → panos_set_commands output
#   - Interface-to-LR binding → panos_set_commands output
#   - VPCE-to-sub-interface associations → EC2 user-data plugin-op-commands
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
# Interface variables
# ---------------------------------------------------------------------------

resource "scm_variable" "eth_local" {
  name   = "eth-local"
  folder = local.folder
  type   = "interface"
  value  = var.panos_trust_iface
}

resource "scm_variable" "eth_internet" {
  name   = "eth-internet"
  folder = local.folder
  type   = "interface"
  value  = var.panos_untrust_iface
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
  name   = "$eth-local"
  folder = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = false
      send_hostname        = { enable = false }
    }
    interface_management_profile = scm_interface_management_profile.gwlb.name
  }

  depends_on = [scm_variable.eth_local]
}

resource "scm_ethernet_interface" "untrust" {
  name   = "$eth-internet"
  folder = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = true
    }
  }

  depends_on = [scm_variable.eth_internet]
}

# ---------------------------------------------------------------------------
# Sub-interfaces
# ---------------------------------------------------------------------------

resource "scm_layer3_subinterface" "vpc1" {
  name             = "$eth-local.1"
  parent_interface = "$eth-local"
  folder           = local.folder
  tag              = 1
  dhcp_client      = { create_default_route = false }

  depends_on = [scm_ethernet_interface.trust]
}

resource "scm_layer3_subinterface" "vpc2" {
  name             = "$eth-local.2"
  parent_interface = "$eth-local"
  folder           = local.folder
  tag              = 2
  dhcp_client      = { create_default_route = false }

  depends_on = [scm_ethernet_interface.trust]
}

# ---------------------------------------------------------------------------
# Security zones
# ---------------------------------------------------------------------------

resource "scm_zone" "trust" {
  name   = var.panos_zone_trust
  folder = local.folder
  network = {
    layer3 = ["$eth-local"]
  }
  depends_on = [scm_ethernet_interface.trust]
}

resource "scm_zone" "workload1" {
  name   = var.panos_zone_vpc1
  folder = local.folder
  network = {
    layer3 = ["$eth-local.1"]
  }
  depends_on = [scm_layer3_subinterface.vpc1]
}

resource "scm_zone" "workload2" {
  name   = var.panos_zone_vpc2
  folder = local.folder
  network = {
    layer3 = ["$eth-local.2"]
  }
  depends_on = [scm_layer3_subinterface.vpc2]
}

resource "scm_zone" "public" {
  name   = var.panos_zone_untrust
  folder = local.folder
  network = {
    layer3 = ["$eth-internet"]
  }
  depends_on = [scm_ethernet_interface.untrust]
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
# Interface assignments applied via panos_set_commands on the device
# ---------------------------------------------------------------------------

resource "scm_logical_router" "main" {
  name   = "LR_default"
  folder = local.folder

  vrf = [
    {
      name = "default"
      routing_table = {
        ip = {
          static_route = [
            {
              name        = "10_8"
              destination = "10.0.0.0/8"
              nexthop     = { ip_address = cidrhost("172.16.2.0/24", 1) }
            },
            {
              name        = "gwlb_subnet"
              destination = aws_subnet.gwlb.cidr_block
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

  from               = [var.panos_zone_vpc1]
  to                 = [var.panos_zone_untrust]
  source             = [scm_address.rfc1918_10.name]
  destination        = [scm_address.rfc1918_10.name]
  negate_destination = true
  source_user        = ["any"]
  category           = ["any"]
  application        = ["any"]
  service            = ["any"]
  action             = "allow"
}

resource "scm_security_rule" "workload2_to_internet" {
  name   = "${var.panos_zone_vpc2}-to-internet"
  folder = local.folder

  from               = [var.panos_zone_vpc2]
  to                 = [var.panos_zone_untrust]
  source             = [scm_address.rfc1918_10.name]
  destination        = [scm_address.rfc1918_10.name]
  negate_destination = true
  source_user        = ["any"]
  category           = ["any"]
  application        = ["any"]
  service            = ["any"]
  action             = "allow"
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
        interface = "$eth-internet"
      }
    }
  }
}
