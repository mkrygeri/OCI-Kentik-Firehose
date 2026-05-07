# ─────────────────────────────────────────────────────────────────────────────
# OCI Load Balancer
#
# A public, flexible-shape Load Balancer sits in the public subnet.
# It terminates TLS on :443 and proxies HTTP to ktranslate on :8081.
# ─────────────────────────────────────────────────────────────────────────────

# ── Self-signed certificate (development / no cert OCID provided) ─────────────
# When var.lb_certificate_ocid is empty, a TLS keypair is generated locally
# and uploaded to the Load Balancer.  For production, provide a cert OCID
# from OCI Certificates Service and the self-signed resource is ignored.

resource "tls_private_key" "lb_selfsigned" {
  count     = var.lb_certificate_ocid == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "lb_selfsigned" {
  count           = var.lb_certificate_ocid == "" ? 1 : 0
  private_key_pem = tls_private_key.lb_selfsigned[0].private_key_pem

  validity_period_hours = 8760 # 1 year

  subject {
    common_name  = "ktranslate-lb.local"
    organization = "ktranslate"
  }

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "oci_load_balancer_certificate" "lb_selfsigned" {
  count            = var.lb_certificate_ocid == "" ? 1 : 0
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  certificate_name = "ktranslate-selfsigned"

  public_certificate = tls_self_signed_cert.lb_selfsigned[0].cert_pem
  private_key        = tls_private_key.lb_selfsigned[0].private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

# ── Load Balancer ─────────────────────────────────────────────────────────────

resource "oci_load_balancer_load_balancer" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "ktranslate-lb"
  shape          = "flexible"
  is_private     = false
  freeform_tags  = var.freeform_tags

  subnet_ids = [oci_core_subnet.public.id]

  network_security_group_ids = [oci_core_network_security_group.lb.id]

  shape_details {
    minimum_bandwidth_in_mbps = var.lb_min_bandwidth_mbps
    maximum_bandwidth_in_mbps = var.lb_max_bandwidth_mbps
  }

  ip_mode = "IPV4"

  is_delete_protection_enabled = false
}

# ── Backend Set ───────────────────────────────────────────────────────────────
# Round-robin policy across the three ktranslate instances.
# Health check: HTTP GET / on the ktranslate port; ktranslate returns 200.

resource "oci_load_balancer_backend_set" "ktranslate" {
  name             = "ktranslate-backends"
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "TCP"
    port              = var.ktranslate_http_port
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
}

# ── Backends (one per instance) ───────────────────────────────────────────────

resource "oci_load_balancer_backend" "ktranslate" {
  count            = var.instance_count
  load_balancer_id = oci_load_balancer_load_balancer.main.id
  backendset_name  = oci_load_balancer_backend_set.ktranslate.name
  ip_address       = oci_core_instance.ktranslate[count.index].private_ip
  port             = var.ktranslate_http_port
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}

# ── HTTPS Listener ────────────────────────────────────────────────────────────
# Terminates TLS using either the provided cert OCID or the self-signed cert.

locals {
  # Name of the certificate to attach to the listener
  lb_cert_name = var.lb_certificate_ocid == "" ? (
    length(oci_load_balancer_certificate.lb_selfsigned) > 0 ?
    oci_load_balancer_certificate.lb_selfsigned[0].certificate_name : ""
  ) : "managed-cert"
}

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.main.id
  name                     = "ktranslate-https-listener"
  default_backend_set_name = oci_load_balancer_backend_set.ktranslate.name
  port                     = var.lb_https_port
  protocol                 = "HTTP"

  ssl_configuration {
    # Use the managed certificate OCID if provided, otherwise use the
    # self-signed certificate uploaded above.
    certificate_ids = var.lb_certificate_ocid != "" ? [var.lb_certificate_ocid] : null
    certificate_name = var.lb_certificate_ocid == "" ? local.lb_cert_name : null

    verify_peer_certificate = false
    cipher_suite_name       = "oci-default-ssl-cipher-suite-v1"

    protocols = ["TLSv1.2", "TLSv1.3"]
  }

  connection_configuration {
    idle_timeout_in_seconds = 60
  }

  depends_on = [
    oci_load_balancer_certificate.lb_selfsigned,
    oci_load_balancer_backend_set.ktranslate,
  ]
}
