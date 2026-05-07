terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }

  # Uncomment to use OCI Object Storage as a remote backend:
  # backend "http" {}
  #
  # Or for local state (default):
  # backend "local" {}
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# ─────────────────────────────────────────────────────────────────────────────
# Data sources
# ─────────────────────────────────────────────────────────────────────────────

# Fetch the list of Availability Domains in the region.
# ktranslate instances are distributed across ADs in a round-robin fashion.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Resolve the OCI Services Network CIDR for the Service Gateway route rule.
data "oci_core_services" "all_services" {}

locals {
  # Pick the "All ... Services In Oracle Services Network" entry.
  # OCI uses a short region code in the CIDR block name (e.g. "iad" for
  # us-ashburn-1), not the full region slug, so we match by prefix/suffix
  # rather than constructing the name from var.region.
  _all_services_entry = one([
    for s in data.oci_core_services.all_services.services :
    s if(
      startswith(s.cidr_block, "all-") &&
      endswith(s.cidr_block, "-services-in-oracle-services-network")
    )
  ])

  oci_services_cidr = local._all_services_entry.cidr_block
  oci_services_id   = local._all_services_entry.id

  # OCI Streaming Kafka bootstrap endpoint for this region
  streaming_bootstrap = "streaming.${var.region}.oci.oraclecloud.com:9092"
}
