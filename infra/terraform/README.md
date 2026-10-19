# infra/terraform

Creates SkyBook's Oracle Cloud footprint. Everything stays inside **OCI Always Free**:

| Resource | Notes |
|---|---|
| Compartment `skybook` | Holds everything below; `terraform destroy` removes it |
| VCN `10.0.0.0/16` + public subnet `10.0.1.0/24` | Internet gateway, route table |
| Security list | **The** firewall: 22 + 6443 from `admin_cidr` only; 80 + 443 from anywhere; ICMP for path MTU |
| `VM.Standard.A1.Flex` | 2 OCPU / 12 GB (the whole A1 allowance since June 2026), Ubuntu 24.04 aarch64, 100 GB boot volume (of 200 GB free) |
| Budget + alert | Emails `budget_alert_email` at the first cent of real spend |
| `../ansible/inventory/hosts.ini` | Written for Ansible |

There is no OCI load balancer (an easy way to get billed): ports 80/443 go straight to the VM,
where k3s's Traefik listens.

State is stored in OCI Object Storage with Terraform's native `oci` backend, which also locks it.

## Prerequisites

- Terraform >= 1.12 and the OCI CLI (`scripts/bootstrap-wsl.sh` installs both).
- An OCI API key:
  ```bash
  oci setup config            # writes ~/.oci/config and generates a key pair
  ```
  Upload the public key (`~/.oci/oci_api_key_public.pem`): Console > My profile > API keys >
  Add API key. Check it with `oci iam region list --output table`.
- An SSH key pair at `~/.ssh/id_ed25519` (`ssh-keygen -t ed25519`).
- The state bucket, created once:
  ```bash
  oci os ns get                                   # prints your Object Storage namespace
  oci os bucket create --name skybook-tfstate \
    --compartment-id <tenancy_ocid> --versioning Enabled
  ```

## Usage

```bash
cd infra/terraform
cp backend.hcl.example backend.hcl                # namespace + home region
cp terraform.tfvars.example terraform.tfvars      # tenancy, region, admin_cidr, email
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`terraform output` shows the public IP, the SSH command and the next steps (Ansible).

- **Your IP changed?** SSH and kubectl stop working. Update `admin_cidr` and run `terraform apply`;
  only the security list changes.
- **New Ubuntu images** don't replace the VM (`ignore_changes` on the image). Ansible and
  unattended-upgrades keep the OS patched.
- **Teardown:** `terraform destroy`. Compartment deletion runs in the background on OCI and can
  take a while. The state bucket is not managed here; delete it in the Console if you want.

## "Out of host capacity"

The Arm (A1) hosts in your region are full right now. It's not a mistake in your config.
Run `terraform apply` again later; capacity comes and goes, and early morning often works. Your
**home region** decides how much capacity you get, and Always Free instances can only be created
there. In regions with several availability domains, `availability_domain_index = 1` (or `2`)
may have room.

If the first apply fails with `NotAuthorizedOrNotFound` right after the compartment is created,
OCI's IAM hadn't caught up yet. Run `terraform apply` again.
