# Everything SkyBook creates lives in its own compartment: easy to find, easy to
# budget, easy to delete. enable_delete lets `terraform destroy` remove it
# (compartment deletion is asynchronous on the OCI side and can take a while).
resource "oci_identity_compartment" "skybook" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "SkyBook portfolio project (managed by Terraform)"
  enable_delete  = true
  freeform_tags  = local.freeform_tags
}
