# AWS VM-Series GWLB — Two-Arm Overlay Routing with Overlapping CIDRs

> **Disclaimer:** Lab and demonstration use only. Not validated for production. No warranty expressed or implied. See full disclaimer below.

Single-AZ centralized egress deployment demonstrating VM-Series inspection via AWS Gateway Load Balancer across two workload VPCs with identical CIDRs and identical workload IPs — a capability of GWLB two-arm overlay routing that traditional routing cannot achieve.

---

## Architecture

```
                              Internet
                                 │
                    ┌────────────┴────────────────────────────────┐
                    │         Security VPC 172.16.0.0/16           │
                    │                                               │
                    │  IGW ◄──► ENI2/ethernet1/2 (untrust, EIP)   │
                    │                    │                          │
                    │              VM-Series                        │
                    │                    │                          │
                    │           ENI0/ethernet1/1 (trust)           │
                    │                    │                          │
                    │                 [GWLB]                        │
                    │                                               │
                    │  ENI1/mgmt (EIP) ◄── SSH                     │
                    └────────────────────┬──────────────────────────┘
                                         │ GWLB Endpoint Service
                          ┌──────────────┴──────────────┐
                          │                             │
             ┌────────────▼──────────┐   ┌─────────────▼─────────┐
             │ Workload VPC 1        │   │ Workload VPC 2         │
             │ 10.0.0.0/16           │   │ 10.0.0.0/16            │
             │ [GWLBE] 10.0.2.0/24   │   │ [GWLBE] 10.0.2.0/24   │
             │ VM: 10.0.1.10 (EIP)   │   │ VM: 10.0.1.10 (EIP)   │
             │ RT: 0/0 → GWLBE       │   │ RT: 0/0 → GWLBE        │
             │ RT: mgmt → IGW        │   │ RT: mgmt → IGW          │
             └───────────────────────┘   └────────────────────────┘
```

**Egress traffic path (C2S):**
1. Workload VM → RT `0/0 → GWLBE` → GWLB (GENEVE/UDP 6081) → ENI0 (`ethernet1/1`)
2. VM-Series decaps GENEVE, performs route lookup on inner destination IP (`aws-gwlb-overlay-routing:enable`); GWLB endpoint ID in GENEVE header disambiguates which VPC the packet came from despite identical source IPs
3. Policy allows → interface NAT SNATs to `ethernet1/2` → exits ENI2 → IGW EIP NAT → Internet

**Return path (S2C):**
Internet → IGW EIP NAT → ENI2 (`ethernet1/2`) → reverse SNAT → `ethernet1/1` → GWLB (GENEVE with original endpoint ID) → GWLBE → Workload VM

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
| `dgname` | SCM folder name — must exist in SCM before apply |
| `pin_id` / `pin_value` | VM-Series auto-registration PIN |
| `authcodes` | BYOL license authcode(s) |
| `mgmt_cidrs` | CIDRs for management access — SG rules AND workload backdoor routes |
| `scm_client_id` | SCM service account OAuth2 client ID |
| `scm_client_secret` | SCM service account OAuth2 client secret |
| `scm_scope` | SCM OAuth2 scope (`tsg_id:XXXXXXXXXX`) |

---

## Prerequisites

1. **SCM folder** — create a folder in SCM matching `dgname` before running `terraform apply`. The Terraform SCM provider cannot create folders.
2. **SCM service account** — create a service account in SCM with sufficient permissions and note the `client_id`, `client_secret`, and `scope`.
3. **VM-Series Marketplace** — accept the BYOL terms in your AWS account.

---

## Usage

```bash
cp example.tfvars terraform.tfvars
# edit terraform.tfvars

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

`terraform apply` will:
1. Create all AWS infrastructure (VPCs, GWLB, GWLBEs, VM-Series instance)
2. Configure the SCM folder with the full PAN-OS policy stack via the SCM Terraform provider
3. Commit the SCM candidate config before the VM-Series instance is created
4. The VM-Series bootstraps via user-data, registers with SCM, and pulls the committed config

---

## Bootstrap (user-data)

The VM-Series is bootstrapped via EC2 user-data:

```
mgmt-interface-swap=enable
panorama-server=cloud
dgname=<var.dgname>
vm-series-auto-registration-pin-id=<var.pin_id>
vm-series-auto-registration-pin-value=<var.pin_value>
authcodes=<var.authcodes>
plugin-op-commands=advance-routing:enable,aws-gwlb-inspect:enable,aws-gwlb-overlay-routing:enable,aws-gwlb-associate-vpce:<wl1-gwlbe-id>@ethernet1/1.1,aws-gwlb-associate-vpce:<wl2-gwlbe-id>@ethernet1/1.2
```

GWLBE IDs are interpolated from Terraform at apply time. VPCE-to-sub-interface associations have no PAN-OS configuration schema equivalent and must be set via `plugin-op-commands` in user-data.

---

## PAN-OS Configuration Options

Three options for applying PAN-OS configuration — choose one:

| Option | How | File |
|---|---|---|
| **SCM Terraform provider** (default) | `enable_scm = true` — resources created in SCM folder, committed before VM-Series boots | `scm.tf` |
| **PAN-OS Terraform provider** | Stub available — uncomment and populate after VM-Series is reachable | `panos.tf` |
| **Manual set commands** | `terraform output -raw panos_set_commands` — paste in configure mode | `main.tf` output |

---

## SCM Configuration

Set `enable_scm = true` (default). The following is managed by the SCM Terraform provider (`scm.tf`) and committed before the VM-Series instance is created:

| Resource | SCM Type |
|---|---|
| Interface management profile (GWLB health check) | `scm_interface_management_profile` |
| ethernet1/1 (`$eth-data`, DHCP, no default route) | `scm_ethernet_interface` |
| ethernet1/2 (`$eth-public`, DHCP, default route) | `scm_ethernet_interface` |
| ethernet1/1.1 / ethernet1/1.2 (tagged sub-interfaces) | `scm_layer3_subinterface` |
| Zones: trust, workload1, workload2, public | `scm_zone` |
| Logical router LR_default / VRF default | `scm_logical_router` |
| Static routes: 10/8 and GWLB subnet via ethernet1/1 | `scm_logical_router` |
| Address object 10.0.0.0/8 | `scm_address` |
| Security rules: workload1-to-internet, workload2-to-internet | `scm_security_rule` |
| NAT rule: interface SNAT on ethernet1/2 | `scm_nat_rule` |

Separate security rules per workload zone (`workload1-to-internet`, `workload2-to-internet`) enable differentiated policy for each workload despite identical source IPs — the key demonstration of GWLB overlay routing.

---

## Manual Set Commands

Set `enable_scm = false` and apply config manually. Generate device-specific commands after apply (GWLBE IDs interpolated):

```bash
terraform output -raw panos_set_commands
```

Or use the pre-rendered commands below (default variable values). Paste in configure mode, then commit.

```
# --- Interfaces ---
set network interface ethernet ethernet1/1 layer3 dhcp-client enable yes
set network interface ethernet ethernet1/1 layer3 dhcp-client send-hostname enable no
set network interface ethernet ethernet1/1 layer3 dhcp-client create-default-route no

# Sub-interface for Workload VPC 1
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 sdwan-link-settings upstream-nat enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 sdwan-link-settings upstream-nat static-ip
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 sdwan-link-settings enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 sdwan-link-settings ipv6-enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 ndp-proxy enabled no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 adjust-tcp-mss enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 tag 1
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.1 dhcp-client create-default-route no

# Sub-interface for Workload VPC 2
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 sdwan-link-settings upstream-nat enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 sdwan-link-settings upstream-nat static-ip
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 sdwan-link-settings enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 sdwan-link-settings ipv6-enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 ndp-proxy enabled no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 adjust-tcp-mss enable no
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 tag 2
set network interface ethernet ethernet1/1 layer3 units ethernet1/1.2 dhcp-client create-default-route no

# Public/untrust (ENI2): DHCP, learns default route
set network interface ethernet ethernet1/2 layer3 dhcp-client create-default-route yes
set network interface ethernet ethernet1/2 layer3 dhcp-client enable yes

# --- Interface management profile - GWLB health check ---
set network profiles interface-management-profile gwlb http yes
set network profiles interface-management-profile gwlb permitted-ip 172.16.4.0/24
set network interface ethernet ethernet1/1 layer3 interface-management-profile gwlb

# --- Security zones ---
set zone trust network layer3 ethernet1/1
set zone workload1 network layer3 ethernet1/1.1
set zone workload2 network layer3 ethernet1/1.2
set zone public network layer3 ethernet1/2

# --- Logical router ---
set network logical-router LR_default vrf default interface [ ethernet1/1 ethernet1/1.1 ethernet1/1.2 ethernet1/2 ]

# --- Static routes ---
set network logical-router LR_default vrf default routing-table ip static-route 10_8 destination 10.0.0.0/8 interface ethernet1/1 nexthop ip-address 172.16.2.1
set network logical-router LR_default vrf default routing-table ip static-route gwlb_subnet destination 172.16.4.0/24 interface ethernet1/1 nexthop ip-address 172.16.2.1

# --- Security policies ---
set rulebase security rules workload1-to-internet from workload1
set rulebase security rules workload1-to-internet to public
set rulebase security rules workload1-to-internet source 10.0.0.0/8
set rulebase security rules workload1-to-internet destination 10.0.0.0/8
set rulebase security rules workload1-to-internet negate-destination yes
set rulebase security rules workload1-to-internet application any
set rulebase security rules workload1-to-internet service any
set rulebase security rules workload1-to-internet action allow

set rulebase security rules workload2-to-internet from workload2
set rulebase security rules workload2-to-internet to public
set rulebase security rules workload2-to-internet source 10.0.0.0/8
set rulebase security rules workload2-to-internet destination 10.0.0.0/8
set rulebase security rules workload2-to-internet negate-destination yes
set rulebase security rules workload2-to-internet application any
set rulebase security rules workload2-to-internet service any
set rulebase security rules workload2-to-internet action allow

# --- NAT policy - interface SNAT ---
set rulebase nat rules workload-egress-snat from [ workload1 workload2 ]
set rulebase nat rules workload-egress-snat to public
set rulebase nat rules workload-egress-snat source 10.0.0.0/8
set rulebase nat rules workload-egress-snat destination any
set rulebase nat rules workload-egress-snat service any
set rulebase nat rules workload-egress-snat source-translation dynamic-ip-and-port interface-address interface ethernet1/2
```

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
- Permitted source: GWLB subnet (172.16.4.0/24)

Managed automatically via `scm_interface_management_profile` assigned to ethernet1/1.

---

## Overlapping CIDRs

Both workload VPCs use `10.0.0.0/16`, and both workload VMs are statically assigned `10.0.1.10`. This is intentional — GWLB uses GENEVE encapsulation with the endpoint ID embedded in the header, allowing VM-Series to distinguish traffic from each VPC regardless of identical source IPs. This is the core capability validated by `aws-gwlb-overlay-routing:enable`.

---

## Disclaimer

> **This repository is provided for lab and demonstration purposes only.**

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, OR NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

**This deployment:**
- Is not validated for production use
- Has not undergone security review
- Deploys permissive security rules intended only for traffic flow validation
- May incur AWS costs — VM-Series (m5.xlarge) and GWLB are not free-tier resources; destroy when not in use
- Requires acceptance of Palo Alto Networks VM-Series Marketplace terms in your AWS account

MIT License — Copyright (c) 2026
