# --- OCI account -------------------------------------------------------------------

variable "tenancy_ocid" {
  description = "OCID of your tenancy (the root compartment). Console: profile icon > Tenancy > OCID, or the `tenancy=` line in ~/.oci/config."
  type        = string

  validation {
    condition     = startswith(var.tenancy_ocid, "ocid1.tenancy.")
    error_message = "tenancy_ocid must look like ocid1.tenancy.oc1..aaaa..."
  }
}

variable "region" {
  description = "Your OCI HOME region, e.g. ap-hyderabad-1. Always Free resources and IAM changes (the compartment) only work there."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an OCI region identifier such as eu-frankfurt-1."
  }
}

variable "config_file_profile" {
  description = "Profile in ~/.oci/config used for API-key authentication."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_name" {
  description = "Name of the compartment created (under the tenancy root) for every SkyBook resource."
  type        = string
  default     = "skybook"
}

# --- Access ----------------------------------------------------------------------------

variable "ssh_public_key_path" {
  description = "SSH public key installed for the `ubuntu` user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"

  validation {
    condition     = fileexists(pathexpand(var.ssh_public_key_path))
    error_message = "ssh_public_key_path does not exist. Create a key pair with: ssh-keygen -t ed25519"
  }
}

variable "admin_cidr" {
  description = "Your public IP as a /32 (curl -s https://ifconfig.me). Only this CIDR can reach SSH (22) and the Kubernetes API (6443)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be an IPv4 CIDR such as 203.0.113.10/32 (and never 0.0.0.0/0)."
  }
}

# --- VM size (Always Free: 2 OCPU + 12 GB RAM of A1 in total since June 2026) -------------

variable "instance_ocpus" {
  description = "OCPUs for the VM.Standard.A1.Flex instance. The Always Free A1 allowance is 2 OCPUs in total."
  type        = number
  default     = 2

  validation {
    condition     = contains([1, 2], var.instance_ocpus)
    error_message = "instance_ocpus must be 1 or 2 to stay inside the Always Free A1 allowance."
  }
}

variable "instance_memory_gbs" {
  description = "Memory in GB for the A1 instance. The Always Free A1 allowance is 12 GB in total."
  type        = number
  default     = 12

  validation {
    condition     = var.instance_memory_gbs >= 1 && var.instance_memory_gbs <= 12
    error_message = "instance_memory_gbs must be between 1 and 12 to stay inside the Always Free A1 allowance."
  }
}

variable "boot_volume_gbs" {
  description = "Boot volume size in GB (minimum 50). Always Free includes 200 GB of block storage in total."
  type        = number
  default     = 100

  validation {
    condition     = var.boot_volume_gbs >= 50 && var.boot_volume_gbs <= 200
    error_message = "boot_volume_gbs must be between 50 and 200 (the Always Free block storage total)."
  }
}

variable "availability_domain_index" {
  description = "Availability domain to launch in (0-based). In multi-AD regions, another AD may have A1 capacity when one is full."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 2], var.availability_domain_index)
    error_message = "availability_domain_index must be 0, 1 or 2."
  }
}

# --- Cost guardrail ------------------------------------------------------------------------

variable "budget_alert_email" {
  description = "Email address that receives the budget alert."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "budget_amount" {
  description = "Monthly budget (whole number, billing currency) for the skybook compartment. The alert fires at 1% of it, i.e. on the first cent of real spend."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_amount >= 1 && floor(var.budget_amount) == var.budget_amount
    error_message = "budget_amount must be a whole number >= 1."
  }
}

# --- Shared values -------------------------------------------------------------------------

locals {
  # Applied to every resource that supports tags.
  freeform_tags = {
    "project"    = "skybook"
    "managed-by" = "terraform"
  }
}
