region = "us-east-1"
az     = "us-east-1a"
prefix = "gwlb-demo"

ssh_public_key = "ssh-rsa AAAA... user@host"
instance_type = "m5.xlarge"

# VM-Series AMI — leave null to auto-lookup latest BYOL for vm_series_version
vm_series_version = "11.1"
# vm_series_ami_id = "ami-xxxxxxxxxxxxxxxxx"

# SCM / Panorama bootstrap (panorama-server=cloud is hardcoded in user-data)
dgname          = "my-device-group"
pin_id          = "your-pin-id"
pin_value       = "your-pin-value"
authcodes       = "YOUR-AUTHCODE"

# Management access — used for SG rules and backdoor routes in workload VPCs
mgmt_cidrs = ["203.0.113.0/24"]

workload_instance_type = "t3.micro"

# Optional PAN-OS set command generation
# Set generate_panos_config = true, then: terraform output -raw panos_set_commands
# panos_router_type: virtual-router (default) or logical-router
# panos_zone_vpc1/vpc2: zone names based on workload VPC identity
generate_panos_config = false
panos_router_type     = "logical-router"
panos_vr              = "default"
panos_trust_iface     = "ethernet1/1"
panos_untrust_iface   = "ethernet1/2"
panos_subif_vpc1      = "ethernet1/1.1"
panos_subif_vpc2      = "ethernet1/1.2"
panos_zone_untrust    = "untrust"
panos_zone_vpc1       = "workload-vpc-1"
panos_zone_vpc2       = "workload-vpc-2"
