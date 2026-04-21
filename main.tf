# =============================================================================
# AWS VM-Series + GWLB - Art of the Possible Validation
#
# Architecture (single AZ):
#   Security VPC (172.16.0.0/16)
#     - VM-Series: ENI0=trust (ethernet1/1), ENI1=mgmt (EIP), ENI2=untrust (EIP)
#     - mgmt-interface-swap=enable
#     - GWLB in gwlb subnet targets VM-Series trust ENI (ENI0)
#     - GWLB Endpoint Service (auto-accept)
#     - GWLBE reserved subnet (created, no endpoint deployed)
#
#   Workload VPC 1 & 2 (both 10.0.0.0/16 - intentionally overlapping)
#     - GWLBE in gwlbe subnet connects to GWLB Endpoint Service
#     - Workload subnet: 0/0 → GWLBE, mgmt_cidrs → IGW (backdoor)
#     - Workload EC2 with EIP
#
# Traffic path: Workload → GWLBE → GWLB (GENEVE/UDP6081) → VM-Series → GWLBE → Workload
# SCM bootstrap: panorama-server=cloud, dgname, pin, authcodes
# =============================================================================

terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "az" {
  type        = string
  default     = "us-east-1a"
  description = "Single availability zone for all resources"
}

variable "prefix" {
  type        = string
  default     = "gwlb-demo"
  description = "Naming prefix"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content for EC2 key pair (e.g. 'ssh-rsa AAAA...')"
}

variable "instance_type" {
  type        = string
  default     = "m5.xlarge"
  description = "VM-Series instance type"
}

variable "vm_series_version" {
  type        = string
  default     = "11.1"
  description = "VM-Series PAN-OS version prefix for AMI lookup (e.g. '11.1')"
}

variable "vm_series_ami_id" {
  type        = string
  default     = null
  description = "Explicit VM-Series AMI ID override. If null, latest BYOL AMI matching vm_series_version is used."
}

variable "dgname" {
  type        = string
  description = "Panorama/SCM Device Group name"
}

variable "pin_id" {
  type        = string
  description = "VM-Series auto-registration PIN ID"
}

variable "pin_value" {
  type        = string
  sensitive   = true
  description = "VM-Series auto-registration PIN value"
}

variable "authcodes" {
  type        = string
  sensitive   = true
  description = "BYOL authcode(s) for VM-Series licensing"
}

variable "mgmt_cidrs" {
  type        = list(string)
  description = "CIDRs allowed management access (SSH, ICMP, HTTP, HTTPS). Also used as backdoor routes in workload VPCs."
}

variable "workload_instance_type" {
  type        = string
  default     = "t3.micro"
  description = "Instance type for workload test VMs"
}

# ---------------------------------------------------------------------------
# PAN-OS config generation (optional)
# ---------------------------------------------------------------------------

variable "generate_panos_config" {
  type        = bool
  default     = false
  description = "Render panos_set_commands output with VM-Series configure-mode set CLI"
}

variable "panos_router_type" {
  type        = string
  default     = "logical-router"
  description = "PAN-OS router type: virtual-router or logical-router"

  validation {
    condition     = contains(["virtual-router", "logical-router"], var.panos_router_type)
    error_message = "Must be virtual-router or logical-router."
  }
}

variable "panos_vr" {
  type        = string
  default     = "default"
  description = "PAN-OS virtual/logical router name"
}

variable "panos_trust_iface" {
  type        = string
  default     = "ethernet1/1"
  description = "PAN-OS trust/private interface (ENI0 with mgmt-interface-swap)"
}

variable "panos_untrust_iface" {
  type        = string
  default     = "ethernet1/2"
  description = "PAN-OS untrust/public interface (ENI2 with mgmt-interface-swap)"
}

variable "panos_subif_vpc1" {
  type        = string
  default     = "ethernet1/1.1"
  description = "PAN-OS sub-interface for Workload VPC 1 GWLBE association"
}

variable "panos_subif_vpc2" {
  type        = string
  default     = "ethernet1/1.2"
  description = "PAN-OS sub-interface for Workload VPC 2 GWLBE association"
}

variable "panos_zone_trust" {
  type        = string
  default     = "trust"
  description = "PAN-OS trust security zone (ethernet1/1 parent interface)"
}

variable "panos_zone_untrust" {
  type        = string
  default     = "public"
  description = "PAN-OS untrust/public security zone"
}

variable "panos_zone_vpc1" {
  type        = string
  default     = "workload1"
  description = "PAN-OS security zone for Workload VPC 1 traffic (ethernet1/1.1)"
}

variable "panos_zone_vpc2" {
  type        = string
  default     = "workload2"
  description = "PAN-OS security zone for Workload VPC 2 traffic (ethernet1/1.2)"
}

# ---------------------------------------------------------------------------
# AMI Lookup - VM-Series BYOL
# ---------------------------------------------------------------------------

data "aws_ami" "vmseries" {
  count       = var.vm_series_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = ["6njl1pau431dv1qxipg63mvah"] # BYOL x86
  }

  filter {
    name   = "name"
    values = ["PA-VM-AWS-${var.vm_series_version}*"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_key_pair" "main" {
  key_name   = "${var.prefix}-key"
  public_key = var.ssh_public_key
  tags       = { Name = "${var.prefix}-key" }
}

locals {
  vmseries_ami = var.vm_series_ami_id != null ? var.vm_series_ami_id : data.aws_ami.vmseries[0].id
}

# ===========================================================================
# SECURITY VPC
# ===========================================================================

resource "aws_vpc" "security" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-security-vpc" }
}

resource "aws_internet_gateway" "security" {
  vpc_id = aws_vpc.security.id
  tags   = { Name = "${var.prefix}-security-igw" }
}

# ---------------------------------------------------------------------------
# Security VPC subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "mgmt" {
  vpc_id            = aws_vpc.security.id
  cidr_block        = "172.16.1.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-mgmt-subnet" }
}

resource "aws_subnet" "trust" {
  vpc_id            = aws_vpc.security.id
  cidr_block        = "172.16.2.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-trust-subnet" }
}

resource "aws_subnet" "untrust" {
  vpc_id            = aws_vpc.security.id
  cidr_block        = "172.16.3.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-untrust-subnet" }
}

resource "aws_subnet" "gwlb" {
  vpc_id            = aws_vpc.security.id
  cidr_block        = "172.16.4.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-gwlb-subnet" }
}

# Reserved - no endpoint deployed, available for future use
resource "aws_subnet" "gwlbe_reserved" {
  vpc_id            = aws_vpc.security.id
  cidr_block        = "172.16.5.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-gwlbe-reserved-subnet" }
}

# ---------------------------------------------------------------------------
# Security VPC route tables
# ---------------------------------------------------------------------------

resource "aws_route_table" "mgmt" {
  vpc_id = aws_vpc.security.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.security.id
  }
  tags = { Name = "${var.prefix}-mgmt-rt" }
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.mgmt.id
}

resource "aws_route_table" "untrust" {
  vpc_id = aws_vpc.security.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.security.id
  }
  tags = { Name = "${var.prefix}-untrust-rt" }
}

resource "aws_route_table_association" "untrust" {
  subnet_id      = aws_subnet.untrust.id
  route_table_id = aws_route_table.untrust.id
}

resource "aws_route_table" "trust" {
  vpc_id = aws_vpc.security.id
  tags   = { Name = "${var.prefix}-trust-rt" }
}

resource "aws_route_table_association" "trust" {
  subnet_id      = aws_subnet.trust.id
  route_table_id = aws_route_table.trust.id
}

resource "aws_route_table" "gwlb" {
  vpc_id = aws_vpc.security.id
  tags   = { Name = "${var.prefix}-gwlb-rt" }
}

resource "aws_route_table_association" "gwlb" {
  subnet_id      = aws_subnet.gwlb.id
  route_table_id = aws_route_table.gwlb.id
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# Management - SSH, ICMP, HTTP, HTTPS from mgmt_cidrs
resource "aws_security_group" "mgmt" {
  name        = "${var.prefix}-vmseries-mgmt-sg"
  description = "VM-Series management interface"
  vpc_id      = aws_vpc.security.id

  dynamic "ingress" {
    for_each = toset(["22", "80", "443"])
    content {
      from_port   = tonumber(ingress.value)
      to_port     = tonumber(ingress.value)
      protocol    = "tcp"
      cidr_blocks = var.mgmt_cidrs
    }
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.mgmt_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-vmseries-mgmt-sg" }
}

# Trust - allow GENEVE (UDP 6081) from GWLB + all return traffic
resource "aws_security_group" "trust" {
  name        = "${var.prefix}-vmseries-trust-sg"
  description = "VM-Series trust interface - GWLB GENEVE traffic"
  vpc_id      = aws_vpc.security.id

  ingress {
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = ["172.16.4.0/24"]
    description = "GWLB GENEVE from gwlb subnet"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["172.16.4.0/24"]
    description = "GWLB health check"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-vmseries-trust-sg" }
}

# Untrust - internet-facing data plane
resource "aws_security_group" "untrust" {
  name        = "${var.prefix}-vmseries-untrust-sg"
  description = "VM-Series untrust interface"
  vpc_id      = aws_vpc.security.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-vmseries-untrust-sg" }
}

# ---------------------------------------------------------------------------
# VM-Series ENIs
# mgmt-interface-swap=enable: ENI0=trust(eth0), ENI1=mgmt(eth1), ENI2=untrust(eth2)
# ---------------------------------------------------------------------------

# ENI0 - Trust (primary, eth0 with mgmt-interface-swap)
resource "aws_network_interface" "trust" {
  subnet_id         = aws_subnet.trust.id
  security_groups   = [aws_security_group.trust.id]
  source_dest_check = false # required for firewall data plane
  tags              = { Name = "${var.prefix}-vmseries-trust-eni" }
}

# ENI1 - Management (eth1 with mgmt-interface-swap), gets EIP
resource "aws_network_interface" "mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.mgmt.id]
  tags            = { Name = "${var.prefix}-vmseries-mgmt-eni" }
}

resource "aws_eip" "mgmt" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-vmseries-mgmt-eip" }
}

resource "aws_eip_association" "mgmt" {
  allocation_id        = aws_eip.mgmt.id
  network_interface_id = aws_network_interface.mgmt.id
}

# ENI2 - Untrust (eth2 with mgmt-interface-swap), gets EIP
resource "aws_network_interface" "untrust" {
  subnet_id         = aws_subnet.untrust.id
  security_groups   = [aws_security_group.untrust.id]
  source_dest_check = false
  tags              = { Name = "${var.prefix}-vmseries-untrust-eni" }
}

resource "aws_eip" "untrust" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-vmseries-untrust-eip" }
}

resource "aws_eip_association" "untrust" {
  allocation_id        = aws_eip.untrust.id
  network_interface_id = aws_network_interface.untrust.id
}

# ---------------------------------------------------------------------------
# GWLB + Target Group
# ---------------------------------------------------------------------------

resource "aws_lb" "gwlb" {
  name               = "${var.prefix}-gwlb"
  load_balancer_type = "gateway"
  subnets            = [aws_subnet.gwlb.id]
  tags               = { Name = "${var.prefix}-gwlb" }
}

resource "aws_lb_target_group" "vmseries" {
  name        = "${var.prefix}-vmseries-tg"
  port        = 6081
  protocol    = "GENEVE"
  vpc_id      = aws_vpc.security.id
  target_type = "instance"

  health_check {
    protocol            = "HTTP"
    port                = 80
    path                = "/unauth/php/health.php"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.prefix}-vmseries-tg" }
}

resource "aws_lb_listener" "gwlb" {
  load_balancer_arn = aws_lb.gwlb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vmseries.arn
  }
}

resource "aws_lb_target_group_attachment" "vmseries" {
  target_group_arn = aws_lb_target_group.vmseries.arn
  target_id        = aws_instance.vmseries.id

  depends_on = [aws_instance.vmseries]
}

# ---------------------------------------------------------------------------
# GWLB Endpoint Service
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint_service" "gwlb" {
  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]
  tags                       = { Name = "${var.prefix}-gwlb-endpoint-service" }
}

# ---------------------------------------------------------------------------
# VM-Series Instance
# ENI attachment order: ENI0 (trust) at launch, ENI1 (mgmt) and ENI2 (untrust) attached
# ---------------------------------------------------------------------------

resource "aws_instance" "vmseries" {
  ami           = local.vmseries_ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.main.key_name

  # ENI0 - trust interface (primary with mgmt-interface-swap)
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.trust.id
  }

  # ENI1 - management
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.mgmt.id
  }

  # ENI2 - untrust
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.untrust.id
  }

  user_data = base64encode(<<-EOF
    mgmt-interface-swap=enable
    panorama-server=cloud
    dgname=${var.dgname}
    vm-series-auto-registration-pin-id=${var.pin_id}
    vm-series-auto-registration-pin-value=${var.pin_value}
    authcodes=${var.authcodes}
    plugin-op-commands=advance-routing:enable,aws-gwlb-inspect:enable,aws-gwlb-overlay-routing:enable,aws-gwlb-associate-vpce:${aws_vpc_endpoint.workload1_gwlbe.id}@ethernet1/1.1,aws-gwlb-associate-vpce:${aws_vpc_endpoint.workload2_gwlbe.id}@ethernet1/1.2
  EOF
  )

  root_block_device {
    volume_type = "gp3"
  }

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = { Name = "${var.prefix}-vmseries" }

  depends_on = [
    aws_vpc_endpoint.workload1_gwlbe,
    aws_vpc_endpoint.workload2_gwlbe,
  ]
}

# ===========================================================================
# WORKLOAD VPC 1
# CIDR 10.0.0.0/16 - intentionally same as Workload VPC 2 (overlapping)
# ===========================================================================

resource "aws_vpc" "workload1" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-workload1-vpc" }
}

resource "aws_internet_gateway" "workload1" {
  vpc_id = aws_vpc.workload1.id
  tags   = { Name = "${var.prefix}-workload1-igw" }
}

resource "aws_subnet" "workload1_workload" {
  vpc_id            = aws_vpc.workload1.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-workload1-workload-subnet" }
}

resource "aws_subnet" "workload1_gwlbe" {
  vpc_id            = aws_vpc.workload1.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-workload1-gwlbe-subnet" }
}

# GWLBE in Workload VPC 1
resource "aws_vpc_endpoint" "workload1_gwlbe" {
  vpc_id            = aws_vpc.workload1.id
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.workload1_gwlbe.id]
  tags              = { Name = "${var.prefix}-workload1-gwlbe" }
}

# Workload VPC 1 route tables
resource "aws_route_table" "workload1_workload" {
  vpc_id = aws_vpc.workload1.id

  # All traffic → GWLBE (inspected by VM-Series)
  route {
    cidr_block      = "0.0.0.0/0"
    vpc_endpoint_id = aws_vpc_endpoint.workload1_gwlbe.id
  }

  # Backdoor: mgmt CIDRs → IGW directly (bypass firewall for management access)
  dynamic "route" {
    for_each = var.mgmt_cidrs
    content {
      cidr_block = route.value
      gateway_id = aws_internet_gateway.workload1.id
    }
  }

  tags = { Name = "${var.prefix}-workload1-workload-rt" }
}

resource "aws_route_table_association" "workload1_workload" {
  subnet_id      = aws_subnet.workload1_workload.id
  route_table_id = aws_route_table.workload1_workload.id
}

resource "aws_route_table" "workload1_gwlbe" {
  vpc_id = aws_vpc.workload1.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workload1.id
  }
  tags = { Name = "${var.prefix}-workload1-gwlbe-rt" }
}

resource "aws_route_table_association" "workload1_gwlbe" {
  subnet_id      = aws_subnet.workload1_gwlbe.id
  route_table_id = aws_route_table.workload1_gwlbe.id
}

# Workload VM 1
resource "aws_security_group" "workload1" {
  name        = "${var.prefix}-workload1-sg"
  description = "Workload 1 VM - management access"
  vpc_id      = aws_vpc.workload1.id

  dynamic "ingress" {
    for_each = toset(["22", "80", "443"])
    content {
      from_port   = tonumber(ingress.value)
      to_port     = tonumber(ingress.value)
      protocol    = "tcp"
      cidr_blocks = var.mgmt_cidrs
    }
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.mgmt_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-workload1-sg" }
}

resource "aws_instance" "workload1" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.workload_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.workload1_workload.id
  private_ip             = "10.0.1.10"
  vpc_security_group_ids = [aws_security_group.workload1.id]

  root_block_device {
    volume_type = "gp3"
  }

  tags = { Name = "${var.prefix}-workload1-vm" }
}

resource "aws_eip" "workload1" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-workload1-eip" }
}

resource "aws_eip_association" "workload1" {
  allocation_id = aws_eip.workload1.id
  instance_id   = aws_instance.workload1.id
}

# ===========================================================================
# WORKLOAD VPC 2
# CIDR 10.0.0.0/16 - same as Workload VPC 1 (intentionally overlapping)
# ===========================================================================

resource "aws_vpc" "workload2" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-workload2-vpc" }
}

resource "aws_internet_gateway" "workload2" {
  vpc_id = aws_vpc.workload2.id
  tags   = { Name = "${var.prefix}-workload2-igw" }
}

resource "aws_subnet" "workload2_workload" {
  vpc_id            = aws_vpc.workload2.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-workload2-workload-subnet" }
}

resource "aws_subnet" "workload2_gwlbe" {
  vpc_id            = aws_vpc.workload2.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.az
  tags              = { Name = "${var.prefix}-workload2-gwlbe-subnet" }
}

# GWLBE in Workload VPC 2
resource "aws_vpc_endpoint" "workload2_gwlbe" {
  vpc_id            = aws_vpc.workload2.id
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.workload2_gwlbe.id]
  tags              = { Name = "${var.prefix}-workload2-gwlbe" }
}

# Workload VPC 2 route tables
resource "aws_route_table" "workload2_workload" {
  vpc_id = aws_vpc.workload2.id

  route {
    cidr_block      = "0.0.0.0/0"
    vpc_endpoint_id = aws_vpc_endpoint.workload2_gwlbe.id
  }

  dynamic "route" {
    for_each = var.mgmt_cidrs
    content {
      cidr_block = route.value
      gateway_id = aws_internet_gateway.workload2.id
    }
  }

  tags = { Name = "${var.prefix}-workload2-workload-rt" }
}

resource "aws_route_table_association" "workload2_workload" {
  subnet_id      = aws_subnet.workload2_workload.id
  route_table_id = aws_route_table.workload2_workload.id
}

resource "aws_route_table" "workload2_gwlbe" {
  vpc_id = aws_vpc.workload2.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workload2.id
  }
  tags = { Name = "${var.prefix}-workload2-gwlbe-rt" }
}

resource "aws_route_table_association" "workload2_gwlbe" {
  subnet_id      = aws_subnet.workload2_gwlbe.id
  route_table_id = aws_route_table.workload2_gwlbe.id
}

# Workload VM 2
resource "aws_security_group" "workload2" {
  name        = "${var.prefix}-workload2-sg"
  description = "Workload 2 VM - management access"
  vpc_id      = aws_vpc.workload2.id

  dynamic "ingress" {
    for_each = toset(["22", "80", "443"])
    content {
      from_port   = tonumber(ingress.value)
      to_port     = tonumber(ingress.value)
      protocol    = "tcp"
      cidr_blocks = var.mgmt_cidrs
    }
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.mgmt_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-workload2-sg" }
}

resource "aws_instance" "workload2" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.workload_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.workload2_workload.id
  private_ip             = "10.0.1.10"
  vpc_security_group_ids = [aws_security_group.workload2.id]

  root_block_device {
    volume_type = "gp3"
  }

  tags = { Name = "${var.prefix}-workload2-vm" }
}

resource "aws_eip" "workload2" {
  domain = "vpc"
  tags   = { Name = "${var.prefix}-workload2-eip" }
}

resource "aws_eip_association" "workload2" {
  allocation_id = aws_eip.workload2.id
  instance_id   = aws_instance.workload2.id
}

# ===========================================================================
# Outputs
# ===========================================================================

output "vmseries_mgmt_eip" {
  description = "VM-Series management EIP - SSH target for PAN-OS CLI"
  value       = aws_eip.mgmt.public_ip
}

output "vmseries_untrust_eip" {
  description = "VM-Series untrust EIP"
  value       = aws_eip.untrust.public_ip
}

output "gwlb_endpoint_service_name" {
  description = "GWLB Endpoint Service name"
  value       = aws_vpc_endpoint_service.gwlb.service_name
}

output "workload1_gwlbe_id" {
  description = "Workload VPC 1 GWLBE ID (used in VM-Series user-data)"
  value       = aws_vpc_endpoint.workload1_gwlbe.id
}

output "workload2_gwlbe_id" {
  description = "Workload VPC 2 GWLBE ID (used in VM-Series user-data)"
  value       = aws_vpc_endpoint.workload2_gwlbe.id
}

output "workload1_vm_eip" {
  description = "Workload VPC 1 test VM public IP"
  value       = aws_eip.workload1.public_ip
}

output "workload2_vm_eip" {
  description = "Workload VPC 2 test VM public IP"
  value       = aws_eip.workload2.public_ip
}

# ---------------------------------------------------------------------------
# Optional PAN-OS set command macro
# Set generate_panos_config = true to populate
# terraform output -raw panos_set_commands
# ---------------------------------------------------------------------------

output "panos_set_commands" {
  description = "VM-Series configure-mode set commands for GWLB two-arm overlay routing"
  value = !var.generate_panos_config ? null : <<-EOT

    # ==========================================================
    # VM-Series - AWS GWLB Two-Arm Overlay Routing
    # Paste in configure mode, then commit
    # ==========================================================

    # --- Interfaces ---
    # Trust (ENI0): DHCP, no default route
    set network interface ethernet ${var.panos_trust_iface} layer3 dhcp-client enable yes
    set network interface ethernet ${var.panos_trust_iface} layer3 dhcp-client send-hostname enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 dhcp-client create-default-route no

    # Sub-interface for Workload VPC 1
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} sdwan-link-settings upstream-nat enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} sdwan-link-settings upstream-nat static-ip
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} sdwan-link-settings enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} sdwan-link-settings ipv6-enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} ndp-proxy enabled no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} adjust-tcp-mss enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} tag 1
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc1} dhcp-client create-default-route no

    # Sub-interface for Workload VPC 2
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} sdwan-link-settings upstream-nat enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} sdwan-link-settings upstream-nat static-ip
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} sdwan-link-settings enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} sdwan-link-settings ipv6-enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} ndp-proxy enabled no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} adjust-tcp-mss enable no
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} tag 2
    set network interface ethernet ${var.panos_trust_iface} layer3 units ${var.panos_subif_vpc2} dhcp-client create-default-route no

    # Public/untrust (ENI2): DHCP, learns default route
    set network interface ethernet ${var.panos_untrust_iface} layer3 dhcp-client create-default-route yes
    set network interface ethernet ${var.panos_untrust_iface} layer3 dhcp-client enable yes

    # --- Interface management profile - GWLB health check ---
    set network profiles interface-management-profile gwlb http yes
    set network profiles interface-management-profile gwlb permitted-ip ${aws_subnet.gwlb.cidr_block}
    set network interface ethernet ${var.panos_trust_iface} layer3 interface-management-profile gwlb

    # --- Security zones ---
    set zone ${var.panos_zone_trust} network layer3 ${var.panos_trust_iface}
    set zone ${var.panos_zone_vpc1} network layer3 ${var.panos_subif_vpc1}
    set zone ${var.panos_zone_vpc2} network layer3 ${var.panos_subif_vpc2}
    set zone ${var.panos_zone_untrust} network layer3 ${var.panos_untrust_iface}

    # --- Logical router ---
    set network logical-router ${var.panos_vr} vrf default interface [ ${var.panos_trust_iface} ${var.panos_subif_vpc1} ${var.panos_subif_vpc2} ${var.panos_untrust_iface} ]

    # --- Static routes ---
    set network logical-router ${var.panos_vr} vrf default routing-table ip static-route 10_8 destination 10.0.0.0/8 interface ${var.panos_trust_iface} nexthop ip-address ${cidrhost("172.16.2.0/24", 1)}
    set network logical-router ${var.panos_vr} vrf default routing-table ip static-route gwlb_subnet destination ${aws_subnet.gwlb.cidr_block} interface ${var.panos_trust_iface} nexthop ip-address ${cidrhost("172.16.2.0/24", 1)}

    # --- Security policy ---
    # Workload → internet: source 10/8, destination NOT 10/8
    set rulebase security rules workload-to-internet from [ ${var.panos_zone_vpc1} ${var.panos_zone_vpc2} ]
    set rulebase security rules workload-to-internet to ${var.panos_zone_untrust}
    set rulebase security rules workload-to-internet source 10.0.0.0/8
    set rulebase security rules workload-to-internet destination 10.0.0.0/8
    set rulebase security rules workload-to-internet negate-destination yes
    set rulebase security rules workload-to-internet application any
    set rulebase security rules workload-to-internet service any
    set rulebase security rules workload-to-internet action allow

    # --- NAT policy - interface SNAT ---
    set rulebase nat rules workload-egress-snat from [ ${var.panos_zone_vpc1} ${var.panos_zone_vpc2} ]
    set rulebase nat rules workload-egress-snat to ${var.panos_zone_untrust}
    set rulebase nat rules workload-egress-snat source 10.0.0.0/8
    set rulebase nat rules workload-egress-snat destination any
    set rulebase nat rules workload-egress-snat service any
    set rulebase nat rules workload-egress-snat source-translation dynamic-ip-and-port interface-address interface ${var.panos_untrust_iface}
  EOT
}
