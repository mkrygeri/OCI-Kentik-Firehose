# ─────────────────────────────────────────────────────────────────────────────
# OCI Streaming — Kafka-compatible managed stream
#
# ktranslate uses the -sinks kafka flag and connects to OCI Streaming over
# SASL_SSL on port 9092.  One stream pool groups the stream and controls
# the Kafka endpoint and authentication.
# ─────────────────────────────────────────────────────────────────────────────

# ── Stream Pool ───────────────────────────────────────────────────────────────
# A stream pool is the Kafka "cluster" equivalent in OCI Streaming.
# The pool exposes a single regional bootstrap endpoint.

resource "oci_streaming_stream_pool" "ktranslate" {
  compartment_id = var.compartment_ocid
  name           = "ktranslate-pool"
  freeform_tags  = var.freeform_tags

  kafka_settings {
    # Bootstrap port is always 9092 for OCI Streaming
    bootstrap_servers = null # read-only; exposed via attribute after creation
    # Auto-create topics is disabled — we manage the stream explicitly
    auto_create_topics_enable = false
    # Number of partitions exposed at the pool level
    num_partitions = var.stream_partition_count
  }

  # Encryption: use a customer-managed key from the ktranslate Vault
  custom_encryption_key {
    kms_key_id = oci_kms_key.ktranslate.id
  }
}

# ── Stream ────────────────────────────────────────────────────────────────────
# A stream maps to a Kafka topic.  ktranslate will produce to this topic.

resource "oci_streaming_stream" "ktranslate_firehose" {
  # compartment_id is inherited from the stream pool when stream_pool_id is set
  name               = var.stream_name
  partitions         = var.stream_partition_count
  retention_in_hours = var.stream_retention_hours
  stream_pool_id     = oci_streaming_stream_pool.ktranslate.id
  freeform_tags      = var.freeform_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Locals: assemble the OCI Streaming Kafka connection details
#
# These are consumed by compute.tf to render the ktranslate startup command
# inside cloud-init.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Bootstrap servers for ktranslate -bootstrap.servers flag
  kafka_bootstrap_servers = "streaming.${var.region}.oci.oraclecloud.com:9092"

  # SASL username format required by OCI Streaming:
  #   <tenancyName>/<username>/<streamPoolId>
  # tenancyName is the short name (not OCID), fetched via data source below.
  kafka_sasl_username = "${data.oci_identity_tenancy.current.name}/${oci_identity_user.ktranslate_streaming.name}/${oci_streaming_stream_pool.ktranslate.id}"

  # Kafka topic name = OCI Stream name
  kafka_topic = oci_streaming_stream.ktranslate_firehose.name
}

data "oci_identity_tenancy" "current" {
  tenancy_id = var.tenancy_ocid
}
