# ─────────────────────────────────────────────────────────────────────────────
# VCN
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "ktranslate-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "ktranslate"
  freeform_tags  = var.freeform_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Gateways
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ktranslate-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ktranslate-nat-gw"
  block_traffic  = false
  freeform_tags  = var.freeform_tags
}

resource "oci_core_service_gateway" "svc" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ktranslate-svc-gw"
  freeform_tags  = var.freeform_tags

  services {
    service_id = local.oci_services_id
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Route Tables
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ktranslate-public-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    network_entity_id = oci_core_internet_gateway.igw.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    description       = "Default route via Internet Gateway"
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "ktranslate-private-rt"
  freeform_tags  = var.freeform_tags

  route_rules {
    network_entity_id = oci_core_nat_gateway.nat.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    description       = "Default route via NAT Gateway (Docker Hub, Kentik API)"
  }

  route_rules {
    network_entity_id = oci_core_service_gateway.svc.id
    destination       = local.oci_services_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    description       = "OCI Services Network via Service Gateway (OCI Streaming)"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Network Security Groups
# ─────────────────────────────────────────────────────────────────────────────

# ── lb-nsg: attached to the Load Balancer ──────────────────────────────────

resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "lb-nsg"
  freeform_tags  = var.freeform_tags
}

# Ingress: HTTPS from internet
resource "oci_core_network_security_group_security_rule" "lb_ingress_https" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "Allow HTTPS from internet (Kentik Firehose)"

  tcp_options {
    destination_port_range {
      min = var.lb_https_port
      max = var.lb_https_port
    }
  }
}

# Egress: HTTP to compute-nsg on ktranslate port
resource "oci_core_network_security_group_security_rule" "lb_egress_compute" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = oci_core_network_security_group.compute.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  stateless                 = false
  description               = "Allow HTTP to ktranslate instances"

  tcp_options {
    destination_port_range {
      min = var.ktranslate_http_port
      max = var.ktranslate_http_port
    }
  }
}

# ── compute-nsg: attached to each ktranslate VM ────────────────────────────

resource "oci_core_network_security_group" "compute" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "compute-nsg"
  freeform_tags  = var.freeform_tags
}

# Ingress: HTTP from lb-nsg
resource "oci_core_network_security_group_security_rule" "compute_ingress_lb" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.lb.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false
  description               = "Allow HTTP from Load Balancer"

  tcp_options {
    destination_port_range {
      min = var.ktranslate_http_port
      max = var.ktranslate_http_port
    }
  }
}

# Egress: SASL_SSL to OCI Streaming via Service Gateway
resource "oci_core_network_security_group_security_rule" "compute_egress_streaming" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = local.oci_services_cidr
  destination_type          = "SERVICE_CIDR_BLOCK"
  stateless                 = false
  description               = "Allow Kafka SASL_SSL to OCI Streaming (Service Gateway)"

  tcp_options {
    destination_port_range {
      min = 9092
      max = 9092
    }
  }
}

# Egress: HTTPS to internet (Docker Hub image pulls, Kentik API, MaxMind)
resource "oci_core_network_security_group_security_rule" "compute_egress_internet_https" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  description               = "Allow HTTPS to internet (Docker Hub, Kentik API)"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Subnets
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  display_name               = "ktranslate-public-subnet"
  cidr_block                 = var.public_subnet_cidr
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id

  # Security list is intentionally left as VCN default; NSGs are used for
  # fine-grained control.  The default security list allows SSH from VCN CIDR
  # which is acceptable for this subnet (LB only, no SSH needed).
  security_list_ids = [oci_core_vcn.main.default_security_list_id]

  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  display_name               = "ktranslate-private-subnet"
  cidr_block                 = var.private_subnet_cidr
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = var.freeform_tags
}
