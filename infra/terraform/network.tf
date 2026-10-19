# One VCN with one public subnet. The security list below IS the firewall:
# the VM's host iptables are accept-all on purpose (see ansible/roles/firewall).
# There is no OCI load balancer (not worth the cost risk): ports 80/443 go
# straight to the VM, where k3s's bundled Traefik listens through ServiceLB.

locals {
  vcn_cidr    = "10.0.0.0/16"
  subnet_cidr = "10.0.1.0/24"

  tcp_ingress_rules = [
    { port = 22, source = var.admin_cidr, description = "SSH (admin only)" },
    { port = 6443, source = var.admin_cidr, description = "Kubernetes API (admin only)" },
    { port = 80, source = "0.0.0.0/0", description = "HTTP to Traefik (ACME HTTP-01, redirect to HTTPS)" },
    { port = 443, source = "0.0.0.0/0", description = "HTTPS to Traefik" },
  ]
}

resource "oci_core_vcn" "skybook" {
  compartment_id = oci_identity_compartment.skybook.id
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "skybook-vcn"
  dns_label      = "skybook"
  freeform_tags  = local.freeform_tags
}

resource "oci_core_internet_gateway" "skybook" {
  compartment_id = oci_identity_compartment.skybook.id
  vcn_id         = oci_core_vcn.skybook.id
  display_name   = "skybook-igw"
  enabled        = true
  freeform_tags  = local.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.skybook.id
  vcn_id         = oci_core_vcn.skybook.id
  display_name   = "skybook-public-rt"
  freeform_tags  = local.freeform_tags

  route_rules {
    description       = "Default route to the internet"
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.skybook.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = oci_identity_compartment.skybook.id
  vcn_id         = oci_core_vcn.skybook.id
  display_name   = "skybook-public-sl"
  freeform_tags  = local.freeform_tags

  egress_security_rules {
    description      = "All outbound traffic"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  dynamic "ingress_security_rules" {
    for_each = local.tcp_ingress_rules

    content {
      description = ingress_security_rules.value.description
      protocol    = "6" # TCP
      source      = ingress_security_rules.value.source
      source_type = "CIDR_BLOCK"

      tcp_options {
        min = ingress_security_rules.value.port
        max = ingress_security_rules.value.port
      }
    }
  }

  # Path MTU discovery ("fragmentation needed") from anywhere.
  ingress_security_rules {
    description = "ICMP type 3 code 4 (path MTU discovery)"
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Destination-unreachable messages from inside the VCN.
  ingress_security_rules {
    description = "ICMP type 3 from the VCN"
    protocol    = "1" # ICMP
    source      = local.vcn_cidr
    source_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = oci_identity_compartment.skybook.id
  vcn_id                     = oci_core_vcn.skybook.id
  cidr_block                 = local.subnet_cidr
  display_name               = "skybook-public"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  freeform_tags              = local.freeform_tags
}
