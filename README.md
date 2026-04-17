# AWS VM-Series GWLB — Two-Arm Overlay Routing with Overlapping CIDRs

Single-AZ centralized egress deployment demonstrating VM-Series inspection via AWS Gateway Load Balancer across two workload VPCs with identical CIDRs and identical workload IPs — a capability of GWLB two-arm overlay routing that traditional routing cannot achieve.

---

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │         Security VPC 172.16.0.0/16       │
                    │                                           │
  Internet ─────── IGW ──► untrust subnet (ENI2, EIP)         │
                    │       mgmt subnet   (ENI1, EIP) ◄── SSH  │
                    │       trust subnet  (ENI0) ──┐            │
                    │       gwlb subnet   [GWLB] ◄─┘            │
                    │       gwlbe-reserved subnet (empty)        │
                    └──────────────┬──────────────────────────┘
                                   │ GWLB Endpoint Service
                     ┌─────────────┴──────────────┐
                     │                            │
        ┌────────────▼──────────┐    ┌────────────▼──────────┐
        │ Workload VPC 1        │    │ Workload VPC 2        │
        │ 10.0.0.0/16           │    │ 10.0.0.0/16 ← overlap │
        │                       │    │                       │
        │ workload subnet       │    │ workload subnet       │
        │   10.0.1.10 (EIP)    │    │   10.0.1.10 (EIP)    │
        │   RT: 0/0 → GWLBE     │    │   RT: 0/0 → GWLBE    │
        │   RT: mgmt → IGW ─────┼────┼──────────────────────┼── backdoor
        │ gwlbe subnet          │    │ gwlbe subnet          │
        │   10.0.2.0/24 [GWLBE] │    │   10.0.2.0/24 [GWLBE]│
        └───────────────────────┘    └───────────────────────┘
```

**Traffic path:** Workload VM → GWLBE → GWLB (GENEVE/UDP 6081) → VM-Series trust (ENI0) → inspect → return via GWLB

**VM-Series interface mapping** (`mgmt-interface-swap=enable`):

| AWS ENI | PAN-OS Interface | Function | EIP |
|---|---|---|---|
| ENI0 (eth0, primary) | ethernet1/1 | Trust / GWLB data plane | — |
| ENI1 (eth1) | Management | Out-of-band mgmt | ✅ |
| ENI2 (eth2) | ethernet1/2 | Untrust | ✅ |

**Sub-interface GWLB associations:**
- `ethernet1/1.1` → Workload VPC 1 GWLBE
- `ethernet1/1.2` → Workload VPC 2 GWLBE

---

## Key Variables

| Variable | Description |
|---|---|
| `region` / `az` | AWS region and single AZ |
| `ssh_public_key` | SSH public key content — a `aws_key_pair` is created from this |
| `instance_type` | VM-Series instance type (default: m5.xlarge) |
| `vm_series_version` | PAN-OS version prefix for AMI lookup (e.g. `11.1`) |
| `vm_series_ami_id` | Optional AMI override (skips marketplace lookup) |
| `dgname` | SCM/Panorama device group name |
| `pin_id` / `pin_value` | VM-Series auto-registration PIN |
| `authcodes` | BYOL license authcode(s) |
| `mgmt_cidrs` | CIDRs for management access — SG rules AND workload backdoor routes |

---

## Usage

```bash
cp example.tfvars terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

---

## Bootstrap (user-data)

The VM-Series is bootstrapped via EC2 user-data with SCM-managed configuration:

```
mgmt-interface-swap=enable
panorama-server=cloud
dgname=<var.dgname>
vm-series-auto-registration-pin-id=<var.pin_id>
vm-series-auto-registration-pin-value=<var.pin_value>
authcodes=<var.authcodes>
plugin-op-commands=aws-gwlb-inspect:enable,
                   aws-gwlb-overlay-routing:enable,
                   aws-gwlb-associate-vpce:<wl1-gwlbe-id>@ethernet1/1.1,
                   aws-gwlb-associate-vpce:<wl2-gwlbe-id>@ethernet1/1.2
```

GWLBE IDs are interpolated from Terraform outputs at apply time — the VM-Series instance depends on both GWLBEs being created first.

---

## Backdoor Management Route

Each workload VPC's workload subnet route table has:
- `0.0.0.0/0` → GWLBE (all internet traffic inspected by VM-Series)
- `<each mgmt_cidr>` → IGW (direct path bypassing GWLB for management SSH)

This allows SSH from `mgmt_cidrs` to reach workload VMs directly via their EIPs without going through the firewall — useful for validation and troubleshooting.

---

## GWLB Health Check

- Protocol: HTTP
- Port: 80
- Path: `/unauth/php/health.php`
- Interval: 10s, threshold: 2

VM-Series must be configured in SCM to respond to health checks on the trust interface (ethernet1/1).

---

## Overlapping CIDRs

Both workload VPCs use `10.0.0.0/16`, and both workload VMs are statically assigned `10.0.1.10`. This is intentional — GWLB uses GENEVE encapsulation with the endpoint ID embedded in the header, allowing VM-Series to distinguish traffic from each VPC regardless of identical source IPs. This is validated by `aws-gwlb-overlay-routing:enable`.

---

## Disclaimer

Lab/demo use only. Not validated for production.
