# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

# ── Load Balancer ──────────────────────────────────────────────────────────────

output "lb_public_ip" {
  description = "Public IP address of the OCI Load Balancer. Configure this as the Kentik Firehose destination."
  value = one([
    for ip in oci_load_balancer_load_balancer.main.ip_address_details :
    ip.ip_address if ip.is_public == true
  ])
}

output "firehose_endpoint" {
  description = "Base HTTPS URL to configure in Kentik Firehose. The sender appends /chf automatically."
  value = "https://${one([
    for ip in oci_load_balancer_load_balancer.main.ip_address_details :
    ip.ip_address if ip.is_public == true
  ])}"
}

output "lb_ocid" {
  description = "OCID of the Load Balancer."
  value       = oci_load_balancer_load_balancer.main.id
}

# ── ktranslate Instances ───────────────────────────────────────────────────────

output "ktranslate_instance_private_ips" {
  description = "Private IP addresses of the ktranslate compute instances."
  value       = oci_core_instance.ktranslate[*].private_ip
}

output "ktranslate_instance_ocids" {
  description = "OCIDs of the ktranslate compute instances."
  value       = oci_core_instance.ktranslate[*].id
}

# ── OCI Streaming ─────────────────────────────────────────────────────────────

output "streaming_stream_ocid" {
  description = "OCID of the OCI Streaming stream (ktranslate-firehose)."
  value       = oci_streaming_stream.ktranslate_firehose.id
}

output "streaming_stream_pool_ocid" {
  description = "OCID of the OCI Streaming stream pool."
  value       = oci_streaming_stream_pool.ktranslate.id
}

output "streaming_bootstrap_servers" {
  description = "Kafka bootstrap endpoint for OCI Streaming."
  value       = local.kafka_bootstrap_servers
}

output "streaming_kafka_topic" {
  description = "Kafka topic name (= OCI Stream name) used by ktranslate."
  value       = local.kafka_topic
}

output "streaming_kafka_sasl_username" {
  description = "SASL username for Kafka authentication to OCI Streaming (tenancy/user/streamPoolId)."
  value       = local.kafka_sasl_username
  sensitive   = true
}

# ── IAM & Vault ───────────────────────────────────────────────────────────────

output "kafka_auth_token_secret_ocid" {
  description = "OCID of the OCI Vault secret storing the Kafka auth token."
  value       = oci_vault_secret.kafka_auth_token.id
}

output "vault_ocid" {
  description = "OCID of the OCI Vault."
  value       = oci_kms_vault.ktranslate.id
}

output "streaming_user_name" {
  description = "Name of the OCI IAM user created for Kafka authentication."
  value       = oci_identity_user.ktranslate_streaming.name
}

# ── Networking ────────────────────────────────────────────────────────────────

output "vcn_ocid" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.main.id
}

output "public_subnet_ocid" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "private_subnet_ocid" {
  description = "OCID of the private subnet."
  value       = oci_core_subnet.private.id
}
