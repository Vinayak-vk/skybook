# API-key authentication from ~/.oci/config (created by `oci setup config`).
# The profile supplies tenancy, user, fingerprint and key_file; region is set
# explicitly so it always matches the home region used for Always Free.
provider "oci" {
  config_file_profile = var.config_file_profile
  region              = var.region
}
