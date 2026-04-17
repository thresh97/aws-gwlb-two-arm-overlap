region = "us-east-1"
az     = "us-east-1a"
prefix = "gwlb-demo"

ssh_public_key = "ssh-rsa AAAA... user@host"
instance_type = "m5.xlarge"

# VM-Series AMI — leave null to auto-lookup latest BYOL for vm_series_version
vm_series_version = "11.1"
# vm_series_ami_id = "ami-xxxxxxxxxxxxxxxxx"

# SCM / Panorama bootstrap
panorama_server = "cloud"
dgname          = "my-device-group"
pin_id          = "your-pin-id"
pin_value       = "your-pin-value"
authcodes       = "YOUR-AUTHCODE"

# Management access — used for SG rules and backdoor routes in workload VPCs
mgmt_cidrs = ["203.0.113.0/24"]

workload_instance_type = "t3.micro"
