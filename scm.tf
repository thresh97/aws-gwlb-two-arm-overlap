# =============================================================================
# SCM Provider - PAN-OS policy configuration via Strata Cloud Manager
#
# Set enable_scm = true to manage PAN-OS config via SCM Terraform provider.
# When enabled, all resources are created in the SCM folder (var.dgname) and
# a candidate commit is triggered before the VM-Series instance is created.
#
# Set enable_scm = false to skip SCM management entirely and apply config
# manually via panos_set_commands output or the PAN-OS Terraform provider.
# =============================================================================

# ---------------------------------------------------------------------------
# SCM toggle and credentials
# ---------------------------------------------------------------------------

variable "enable_scm" {
  type        = bool
  default     = true
  description = "Enable SCM Terraform provider management of PAN-OS config"
}

variable "scm_client_id" {
  type        = string
  default     = ""
  description = "SCM service account OAuth2 client ID (required when enable_scm = true)"
}

variable "scm_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "SCM service account OAuth2 client secret (required when enable_scm = true)"
}

variable "scm_scope" {
  type        = string
  default     = ""
  description = "SCM OAuth2 scope (format: tsg_id:XXXXXXXXXX) (required when enable_scm = true)"
}

# ---------------------------------------------------------------------------
# SCM provider
# ---------------------------------------------------------------------------

provider "scm" {
  client_id     = var.scm_client_id
  client_secret = var.scm_client_secret
  scope         = var.scm_scope
}

variable "scm_parent_folder" {
  type        = string
  default     = "ngfw-shared"
  description = "SCM parent folder for the deployment folder"
}

locals {
  folder = "${local.deploy_id}-${var.dgname}"
}

# ---------------------------------------------------------------------------
# SCM folder
# ---------------------------------------------------------------------------

resource "scm_folder" "main" {
  count       = var.enable_scm ? 1 : 0
  name        = local.folder
  parent      = var.scm_parent_folder
  description = local.folder
}

# ---------------------------------------------------------------------------
# Interface management profile - GWLB health check
# ---------------------------------------------------------------------------

resource "scm_interface_management_profile" "gwlb" {
  count  = var.enable_scm ? 1 : 0
  name   = "gwlb"
  folder = local.folder

  http         = true
  permitted_ip = [{ name = aws_subnet.gwlb.cidr_block }]

  depends_on = [scm_folder.main]
}

# ---------------------------------------------------------------------------
# Ethernet interfaces
# ---------------------------------------------------------------------------

resource "scm_ethernet_interface" "trust" {
  count         = var.enable_scm ? 1 : 0
  name          = "$eth-data"
  default_value = var.panos_trust_iface
  folder        = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = false
      send_hostname        = { enable = false }
    }
    interface_management_profile = "gwlb"
  }

  depends_on = [scm_interface_management_profile.gwlb]
}

resource "scm_ethernet_interface" "untrust" {
  count         = var.enable_scm ? 1 : 0
  name          = "$eth-public"
  default_value = var.panos_untrust_iface
  folder        = local.folder

  layer3 = {
    dhcp_client = {
      enable               = true
      create_default_route = true
    }
  }

  depends_on = [scm_folder.main]
}

# ---------------------------------------------------------------------------
# Sub-interfaces
# ---------------------------------------------------------------------------

resource "scm_layer3_subinterface" "vpc1" {
  count            = var.enable_scm ? 1 : 0
  name             = "$eth-data.1"
  parent_interface = "$eth-data"
  folder           = local.folder
  tag              = 1
  dhcp_client      = { create_default_route = false }

  depends_on = [scm_ethernet_interface.trust]
}

resource "scm_layer3_subinterface" "vpc2" {
  count            = var.enable_scm ? 1 : 0
  name             = "$eth-data.2"
  parent_interface = "$eth-data"
  folder           = local.folder
  tag              = 2
  dhcp_client      = { create_default_route = false }

  depends_on = [scm_ethernet_interface.trust]
}

# ---------------------------------------------------------------------------
# Security zones
# ---------------------------------------------------------------------------

resource "scm_zone" "trust" {
  count  = var.enable_scm ? 1 : 0
  name   = var.panos_zone_trust
  folder = local.folder
  network = {
    layer3 = ["$eth-data"]
  }
  depends_on = [scm_ethernet_interface.trust]
}

resource "scm_zone" "workload1" {
  count  = var.enable_scm ? 1 : 0
  name   = var.panos_zone_vpc1
  folder = local.folder
  network = {
    layer3 = ["$eth-data.1"]
  }
  depends_on = [scm_layer3_subinterface.vpc1]
}

resource "scm_zone" "workload2" {
  count  = var.enable_scm ? 1 : 0
  name   = var.panos_zone_vpc2
  folder = local.folder
  network = {
    layer3 = ["$eth-data.2"]
  }
  depends_on = [scm_layer3_subinterface.vpc2]
}

resource "scm_zone" "public" {
  count  = var.enable_scm ? 1 : 0
  name   = var.panos_zone_untrust
  folder = local.folder
  network = {
    layer3 = ["$eth-public"]
  }
  depends_on = [scm_ethernet_interface.untrust]
}

# ---------------------------------------------------------------------------
# Address object
# ---------------------------------------------------------------------------

resource "scm_address" "rfc1918_10" {
  count      = var.enable_scm ? 1 : 0
  name       = "10.0.0.0_8"
  folder     = local.folder
  ip_netmask = "10.0.0.0/8"

  depends_on = [scm_folder.main]
}

# ---------------------------------------------------------------------------
# Logical router
# ---------------------------------------------------------------------------

resource "scm_logical_router" "main" {
  count  = var.enable_scm ? 1 : 0
  name   = "LR_default"
  folder = local.folder

  vrf = [
    {
      name      = "default"
      interface = ["$eth-data", "$eth-data.1", "$eth-data.2", "$eth-public"]
      routing_table = {
        ip = {
          static_route = [
            {
              name        = "10_8"
              destination = "10.0.0.0/8"
              interface   = "$eth-data"
              nexthop     = { ip_address = cidrhost("172.16.2.0/24", 1) }
            },
            {
              name        = "gwlb_subnet"
              destination = aws_subnet.gwlb.cidr_block
              interface   = "$eth-data"
              nexthop     = { ip_address = cidrhost("172.16.2.0/24", 1) }
            },
          ]
        }
      }
    }
  ]

  depends_on = [
    scm_ethernet_interface.trust,
    scm_ethernet_interface.untrust,
    scm_layer3_subinterface.vpc1,
    scm_layer3_subinterface.vpc2,
  ]
}

# ---------------------------------------------------------------------------
# Security rules
# Separate rules per workload zone enable differentiated policy
# despite overlapping source IPs across VPCs
# ---------------------------------------------------------------------------

resource "scm_security_rule" "workload1_to_internet" {
  count  = var.enable_scm ? 1 : 0
  name   = "${var.panos_zone_vpc1}-to-internet"
  folder = local.folder

  from               = [var.panos_zone_vpc1]
  to                 = [var.panos_zone_untrust]
  source             = ["10.0.0.0_8"]
  destination        = ["10.0.0.0_8"]
  negate_destination = true
  source_user        = ["any"]
  category           = ["any"]
  application        = ["any"]
  service            = ["any"]
  action             = "allow"

  depends_on = [
    scm_zone.workload1,
    scm_zone.public,
    scm_address.rfc1918_10,
  ]
}

resource "scm_security_rule" "workload2_to_internet" {
  count  = var.enable_scm ? 1 : 0
  name   = "${var.panos_zone_vpc2}-to-internet"
  folder = local.folder

  from               = [var.panos_zone_vpc2]
  to                 = [var.panos_zone_untrust]
  source             = ["10.0.0.0_8"]
  destination        = ["10.0.0.0_8"]
  negate_destination = true
  source_user        = ["any"]
  category           = ["any"]
  application        = ["any"]
  service            = ["any"]
  action             = "allow"

  depends_on = [
    scm_zone.workload2,
    scm_zone.public,
    scm_address.rfc1918_10,
  ]
}

# ---------------------------------------------------------------------------
# NAT rule - interface SNAT on untrust
# ---------------------------------------------------------------------------

resource "scm_nat_rule" "workload_egress_snat" {
  count  = var.enable_scm ? 1 : 0
  name   = "workload-egress-snat"
  folder = local.folder

  from        = [var.panos_zone_vpc1, var.panos_zone_vpc2]
  to          = [var.panos_zone_untrust]
  source      = ["10.0.0.0_8"]
  destination = ["any"]
  service     = "any"

  source_translation = {
    dynamic_ip_and_port = {
      interface_address = {
        interface = "$eth-public"
      }
    }
  }

  depends_on = [
    scm_zone.workload1,
    scm_zone.workload2,
    scm_zone.public,
    scm_ethernet_interface.trust,
    scm_ethernet_interface.untrust,
    scm_address.rfc1918_10,
  ]
}
