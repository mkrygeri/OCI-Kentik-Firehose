# ─────────────────────────────────────────────────────────────────────────────
# IAM: dedicated user for OCI Streaming Kafka authentication
#
# OCI Streaming's Kafka compatibility layer uses SASL/PLAIN with an auth token.
# We create a dedicated IAM user so that credentials are narrowly scoped and
# can be rotated without affecting any other principal.
#
# IMPORTANT: The auth token value is a sensitive credential that Terraform
# stores in state.  Protect your state file (use a remote, encrypted backend).
# ─────────────────────────────────────────────────────────────────────────────

# ── User ──────────────────────────────────────────────────────────────────────

resource "oci_identity_user" "ktranslate_streaming" {
  compartment_id = var.tenancy_ocid   # IAM users always live in the tenancy root
  name           = "ktranslate-streaming-user"
  description    = "Service account used by ktranslate instances to produce to OCI Streaming via the Kafka API."
  email          = var.iam_user_email
  freeform_tags  = var.freeform_tags
}

# ── Group ─────────────────────────────────────────────────────────────────────

resource "oci_identity_group" "ktranslate_streaming" {
  compartment_id = var.tenancy_ocid
  name           = "ktranslate-streaming-group"
  description    = "Group for ktranslate Kafka producers."
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_user_group_membership" "ktranslate_streaming" {
  user_id  = oci_identity_user.ktranslate_streaming.id
  group_id = oci_identity_group.ktranslate_streaming.id
}

# ── IAM Policy ────────────────────────────────────────────────────────────────
# Grants the group permission to use streams in the target compartment.
# "manage streams" allows produce, consume, and describe — sufficient for
# ktranslate as a Kafka producer.

resource "oci_identity_policy" "ktranslate_streaming" {
  compartment_id = var.compartment_ocid
  name           = "ktranslate-streaming-policy"
  description    = "Allows ktranslate-streaming-group to manage OCI Streaming streams."
  freeform_tags  = var.freeform_tags

  statements = [
    "Allow group ${oci_identity_group.ktranslate_streaming.name} to manage streams in compartment id ${var.compartment_ocid}",
    "Allow group ${oci_identity_group.ktranslate_streaming.name} to manage stream-family in compartment id ${var.compartment_ocid}",
  ]
}

# ── Auth Token ────────────────────────────────────────────────────────────────
# This token is used as the Kafka SASL password.  It is generated once and
# stored in OCI Vault.  The token value is sensitive; Terraform marks it as such.

resource "oci_identity_auth_token" "ktranslate_streaming" {
  user_id     = oci_identity_user.ktranslate_streaming.id
  description = "Kafka SASL auth token for ktranslate OCI Streaming producer"

  # Auth tokens cannot be updated in place; destroy and recreate to rotate.
  lifecycle {
    ignore_changes = [description]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# OCI Vault: store the auth token as a secret so instances can fetch it
# securely at boot without the value appearing in user-data plaintext.
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_kms_vault" "ktranslate" {
  compartment_id = var.compartment_ocid
  display_name   = "ktranslate-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "ktranslate" {
  compartment_id      = var.compartment_ocid
  display_name        = "ktranslate-vault-key"
  management_endpoint = oci_kms_vault.ktranslate.management_endpoint
  freeform_tags       = var.freeform_tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

resource "oci_vault_secret" "kafka_auth_token" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.ktranslate.id
  key_id         = oci_kms_key.ktranslate.id
  secret_name    = "ktranslate-kafka-auth-token"
  description    = "OCI Streaming SASL/PLAIN auth token for ktranslate"
  freeform_tags  = var.freeform_tags

  secret_content {
    content_type = "BASE64"
    # Base64-encode the token value for the Vault API
    content  = base64encode(oci_identity_auth_token.ktranslate_streaming.token)
    stage    = "CURRENT"
  }

  lifecycle {
    # Re-create the secret version when the token changes (e.g. rotation)
    replace_triggered_by = [oci_identity_auth_token.ktranslate_streaming]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Instance Principal IAM policy
#
# Allows the ktranslate compute instances (identified by their compartment)
# to read secrets from the Vault without embedding any API credentials in
# the instance.  This uses OCI's dynamic group + instance principal mechanism.
# ─────────────────────────────────────────────────────────────────────────────

resource "oci_identity_dynamic_group" "ktranslate_instances" {
  compartment_id = var.tenancy_ocid
  name           = "ktranslate-instances-dg"
  description    = "Dynamic group matching all ktranslate compute instances in the deployment compartment."
  matching_rule  = "All {instance.compartment.id = '${var.compartment_ocid}'}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "ktranslate_instance_vault" {
  compartment_id = var.compartment_ocid
  name           = "ktranslate-instance-vault-policy"
  description    = "Allows ktranslate instances to read Vault secrets (Kafka auth token)."
  freeform_tags  = var.freeform_tags

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.ktranslate_instances.name} to read secret-bundles in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.ktranslate_instances.name} to read vaults in compartment id ${var.compartment_ocid}",
  ]
}
