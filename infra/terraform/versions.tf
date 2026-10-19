terraform {
  required_version = ">= 1.12"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 9.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Terraform's native OCI Object Storage backend (state locking included).
  # Partial configuration: the settings live in backend.hcl (git-ignored, see
  # backend.hcl.example), so run:  terraform init -backend-config=backend.hcl
  backend "oci" {}
}
