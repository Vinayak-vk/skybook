data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Newest Canonical Ubuntu 24.04 aarch64 platform image for the A1 shape.
# The display_name regex excludes the "Minimal" variants.
data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-24\\.04-aarch64-.*"]
    regex  = true
  }
}

# The single k3s node: 2 OCPU / 12 GB / 100 GB, all inside Always Free.
resource "oci_core_instance" "skybook" {
  compartment_id      = oci_identity_compartment.skybook.id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "skybook"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    display_name     = "skybook-vnic"
    hostname_label   = "skybook"
    freeform_tags    = local.freeform_tags
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }

  # Delete the boot volume with the instance so nothing is left using the free storage.
  preserve_boot_volume = false

  freeform_tags = local.freeform_tags

  lifecycle {
    # A newer Ubuntu image must not replace the running VM.
    # The OS is kept up to date by Ansible and unattended-upgrades instead.
    ignore_changes = [source_details[0].source_id]

    precondition {
      condition     = var.availability_domain_index < length(data.oci_identity_availability_domains.ads.availability_domains)
      error_message = "availability_domain_index is larger than the number of availability domains in this region."
    }

    precondition {
      condition     = length(data.oci_core_images.ubuntu.images) > 0
      error_message = "No Canonical Ubuntu 24.04 aarch64 image for VM.Standard.A1.Flex was found in this region."
    }
  }
}
