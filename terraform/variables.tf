# ─────────────────────────────────────────────────────────────────────────────
# OCI Provider identity
# ─────────────────────────────────────────────────────────────────────────────

variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user for Terraform API authentication."
  type        = string
}

variable "fingerprint" {
  description = "API key fingerprint for the Terraform OCI user."
  type        = string
}

variable "private_key_path" {
  description = "Path to the PEM-format private key for the Terraform OCI user."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region identifier (e.g. us-ashburn-1)."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Compartment
# ─────────────────────────────────────────────────────────────────────────────

variable "compartment_ocid" {
  description = "OCID of the compartment in which all resources will be created."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Networking
# ─────────────────────────────────────────────────────────────────────────────

variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (Load Balancer)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (ktranslate VMs)."
  type        = string
  default     = "10.0.2.0/24"
}

# ─────────────────────────────────────────────────────────────────────────────
# Compute
# ─────────────────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key for the ktranslate instances (authorized_keys)."
  type        = string
}

variable "instance_shape" {
  description = "OCI compute shape for ktranslate instances."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs per ktranslate instance."
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory in GB per ktranslate instance."
  type        = number
  default     = 16
}

variable "instance_count" {
  description = "Number of ktranslate backend instances."
  type        = number
  default     = 3
}

variable "instance_image_ocid" {
  description = "OCID of the base image for ktranslate instances (Oracle Linux 8 recommended). Override per-region."
  type        = string
  # Default is Oracle Linux 8 in us-ashburn-1. Update for your region:
  # https://docs.oracle.com/en-us/iaas/images/
  default     = "ocid1.image.oc1.iad.aaaaaaaa2bhou7ffonhfkrzw7l6yfz3xidlxr7e6a5xbr7hxqxz3slbqkhba"
}

# ─────────────────────────────────────────────────────────────────────────────
# Load Balancer
# ─────────────────────────────────────────────────────────────────────────────

variable "lb_min_bandwidth_mbps" {
  description = "Minimum bandwidth in Mbps for the flexible Load Balancer shape."
  type        = number
  default     = 10
}

variable "lb_max_bandwidth_mbps" {
  description = "Maximum bandwidth in Mbps for the flexible Load Balancer shape."
  type        = number
  default     = 100
}

variable "lb_certificate_ocid" {
  description = <<-EOT
    OCID of the TLS certificate stored in OCI Certificates Service.
    The certificate must already exist before Terraform is applied.
    Used to terminate HTTPS on the Load Balancer listener (:443).
    Leave empty to use the self-signed certificate created by this module (dev only).
  EOT
  type        = string
  default     = ""
}

variable "lb_https_port" {
  description = "TCP port the Load Balancer HTTPS listener will bind on."
  type        = number
  default     = 443
}

variable "ktranslate_http_port" {
  description = "Port ktranslate listens on for incoming HTTP (Firehose) data."
  type        = number
  default     = 8081
}

# ─────────────────────────────────────────────────────────────────────────────
# OCI Streaming (Kafka)
# ─────────────────────────────────────────────────────────────────────────────

variable "stream_name" {
  description = "Name for the OCI Streaming stream."
  type        = string
  default     = "ktranslate-firehose"
}

variable "stream_partition_count" {
  description = "Number of Kafka partitions for the stream. Minimum = instance_count."
  type        = number
  default     = 3
}

variable "stream_retention_hours" {
  description = "Message retention period for the stream in hours (max 168 = 7 days)."
  type        = number
  default     = 24
}

# ─────────────────────────────────────────────────────────────────────────────
# ktranslate configuration
# ─────────────────────────────────────────────────────────────────────────────

variable "ktranslate_format" {
  description = "Output format for ktranslate messages sent to Kafka. Options: flat_json|json|avro."
  type        = string
  default     = "flat_json"

  validation {
    condition     = contains(["flat_json", "json", "avro", "new_relic"], var.ktranslate_format)
    error_message = "ktranslate_format must be one of: flat_json, json, avro, new_relic."
  }
}

variable "ktranslate_image" {
  description = "Docker image for ktranslate."
  type        = string
  default     = "kentik/ktranslate:v2"
}

variable "ktranslate_log_level" {
  description = "Logging level for ktranslate. Options: info|debug|warn|error."
  type        = string
  default     = "info"
}

variable "ktranslate_max_flows_per_message" {
  description = "Maximum number of flows to include in each Kafka message."
  type        = number
  default     = 10000
}

variable "ktranslate_compression" {
  description = "Compression algorithm for ktranslate output. Options: none|gzip|snappy."
  type        = string
  default     = "gzip"

  validation {
    condition     = contains(["none", "gzip", "snappy", "deflate"], var.ktranslate_compression)
    error_message = "ktranslate_compression must be one of: none, gzip, snappy, deflate."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Tagging
# ─────────────────────────────────────────────────────────────────────────────

variable "iam_user_email" {
  description = "Email address for the ktranslate IAM service account user (required by IDCS-enabled tenancies)."
  type        = string
}

variable "freeform_tags" {
  description = "Freeform tags to apply to all resources."
  type        = map(string)
  default = {
    project     = "kentik-firehose"
    managed_by  = "terraform"
  }
}
