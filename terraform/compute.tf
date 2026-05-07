# ─────────────────────────────────────────────────────────────────────────────
# ktranslate compute instances
#
# Three instances are deployed using count = var.instance_count (default 3).
# Instances are spread across Availability Domains in a round-robin fashion.
# Each instance runs ktranslate in Docker, configured via cloud-init.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Number of ADs available in the region (capped at instance count)
  ad_count = length(data.oci_identity_availability_domains.ads.availability_domains)
}

resource "oci_core_instance" "ktranslate" {
  count = var.instance_count

  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index % local.ad_count].name
  display_name        = "ktranslate-${count.index + 1}"
  freeform_tags       = merge(var.freeform_tags, { instance_index = tostring(count.index + 1) })

  shape = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = var.instance_image_ocid
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.private.id
    assign_public_ip       = false
    display_name           = "ktranslate-${count.index + 1}-vnic"
    hostname_label         = "ktranslate${count.index + 1}"
    nsg_ids                = [oci_core_network_security_group.compute.id]
    skip_source_dest_check = false
  }

  # user_data is the base64-encoded, gzip-compressed cloud-init config
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = data.cloudinit_config.ktranslate[count.index].rendered
  }

  lifecycle {
    # Prevent accidental instance replacement when the image OCID is updated.
    # Remove this ignore rule if you want rolling image updates.
    ignore_changes = [source_details[0].source_id]
  }

  timeouts {
    create = "20m"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# cloud-init config (rendered per instance — content is identical for all 3)
# ─────────────────────────────────────────────────────────────────────────────

data "cloudinit_config" "ktranslate" {
  count = var.instance_count

  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/../cloud-init/ktranslate.yaml", {
      region                  = var.region
      kafka_bootstrap         = local.kafka_bootstrap_servers
      kafka_sasl_username     = local.kafka_sasl_username
      kafka_sasl_password     = oci_identity_auth_token.ktranslate_streaming.token
      kafka_topic             = local.kafka_topic
      ktranslate_image        = var.ktranslate_image
      ktranslate_http_port    = var.ktranslate_http_port
      ktranslate_format       = var.ktranslate_format
      ktranslate_compression  = var.ktranslate_compression
      ktranslate_max_flows    = var.ktranslate_max_flows_per_message
      ktranslate_log_level    = var.ktranslate_log_level
    })
  }
}
