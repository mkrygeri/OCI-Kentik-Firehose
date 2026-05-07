# OCI-Kentik-Firehose

Terraform infrastructure for deploying a highly available **Kentik Firehose** receiver on Oracle Cloud Infrastructure (OCI).

The stack ingests enriched network flow data from Kentik's cloud export service, routes it through a pool of [ktranslate](https://github.com/kentik/ktranslate) collector instances, and delivers it to **OCI Streaming** (a managed Kafka-compatible service) for downstream consumption.

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │                   OCI VCN                   │
                        │                                             │
  Kentik Firehose  ────►│  Public LB (:443 HTTPS)                    │
  (HTTPS POST /chf)     │       │                                     │
                        │       │ HTTP :8081                          │
                        │       ▼                                     │
                        │  ┌──────────────────────────────────┐       │
                        │  │  Private Subnet                  │       │
                        │  │  ktranslate-1 (AD-1)             │       │
                        │  │  ktranslate-2 (AD-2)  ──────────────►  OCI Streaming │
                        │  │  ktranslate-3 (AD-3)             │       │  (Kafka)   │
                        │  └──────────────────────────────────┘       │
                        │       │                                     │
                        │  NAT GW / Service GW (outbound)             │
                        └─────────────────────────────────────────────┘
```

| Component | OCI Resource |
|-----------|-------------|
| Ingress endpoint | Flexible public Load Balancer (HTTPS :443) |
| Flow collectors | 3 × `VM.Standard.E4.Flex` VMs running ktranslate in Docker, spread across Availability Domains |
| Stream destination | OCI Streaming Stream Pool + Stream (Kafka API, SASL/SSL) |
| Auth | Dedicated IAM user + auth token, stored in OCI Vault |
| Networking | VCN with public subnet (LB), private subnet (VMs), NAT GW, Service GW |

---

## Prerequisites

| Tool | Minimum version |
|------|-----------------|
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | 1.5.0 |
| [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) (optional, for state inspection) | any |
| OCI API key for your Terraform user | — |

You also need:
- An OCI tenancy with sufficient service limits for compute, networking, and streaming.
- A compartment OCID where all resources will be created.
- An SSH public key for instance access (emergency use; ktranslate is fully automated via cloud-init).

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/mkrygeri/OCI-Kentik-Firehose.git
cd OCI-Kentik-Firehose
```

### 2. Configure credentials

Ensure your OCI API key is in place (default path: `~/.oci/oci_api_key.pem`) and matches the fingerprint you will supply in `terraform.tfvars`.

See [OCI documentation — Required Keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm) for key generation steps.

### 3. Create your variables file

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` and fill in every value. See [Variable Reference](#variable-reference) below.

> **Security note:** `terraform.tfvars` is listed in `.gitignore` and must **never** be committed — it contains your OCI credentials.

### 4. Deploy

```bash
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Terraform will output the Load Balancer public IP and the ready-to-use Firehose endpoint URL on completion.

### 5. Configure Kentik Firehose

In the Kentik portal, create a Firehose export and point it at the `firehose_endpoint` output:

```
https://<lb_public_ip>
```

Kentik appends `/chf` automatically when posting flow data.

---

## Variable Reference

All variables are defined in [`terraform/variables.tf`](terraform/variables.tf). The table below covers the most commonly changed values. See the file for the complete list with types, defaults, and descriptions.

### OCI Provider Identity

| Variable | Description | Example |
|----------|-------------|---------|
| `tenancy_ocid` | OCID of your OCI tenancy | `ocid1.tenancy.oc1..aaaa…` |
| `user_ocid` | OCID of the Terraform API user | `ocid1.user.oc1..aaaa…` |
| `fingerprint` | API key fingerprint | `aa:bb:cc:…` |
| `private_key_path` | Path to the PEM private key | `~/.oci/oci_api_key.pem` |
| `region` | OCI region identifier | `us-ashburn-1` |

### Compartment

| Variable | Description |
|----------|-------------|
| `compartment_ocid` | OCID of the compartment for all resources |

### Networking

| Variable | Default | Description |
|----------|---------|-------------|
| `vcn_cidr` | `10.0.0.0/16` | VCN CIDR block |
| `public_subnet_cidr` | `10.0.1.0/24` | Public subnet (Load Balancer) |
| `private_subnet_cidr` | `10.0.2.0/24` | Private subnet (ktranslate VMs) |

### Compute

| Variable | Default | Description |
|----------|---------|-------------|
| `ssh_public_key` | — | SSH public key for VM access |
| `instance_shape` | `VM.Standard.E4.Flex` | OCI compute shape |
| `instance_ocpus` | `2` | OCPUs per instance |
| `instance_memory_gb` | `16` | Memory per instance (GB) |
| `instance_count` | `3` | Number of ktranslate instances |
| `instance_image_ocid` | Oracle Linux 8 (Ashburn) | Base OS image OCID — **update for your region** |

Find the correct Oracle Linux 8 image OCID for your region at:  
https://docs.oracle.com/en-us/iaas/images/

### Load Balancer

| Variable | Default | Description |
|----------|---------|-------------|
| `lb_min_bandwidth_mbps` | `10` | Minimum LB bandwidth |
| `lb_max_bandwidth_mbps` | `100` | Maximum LB bandwidth |
| `lb_certificate_ocid` | `""` | OCI Certificates Service OCID. Leave empty to auto-generate a self-signed cert (dev/test only). |
| `lb_https_port` | `443` | HTTPS listener port |
| `ktranslate_http_port` | `8081` | ktranslate backend port |

### OCI Streaming

| Variable | Default | Description |
|----------|---------|-------------|
| `stream_name` | `ktranslate-firehose` | OCI Stream / Kafka topic name |
| `stream_partition_count` | `3` | Number of stream partitions |
| `stream_retention_hours` | `24` | Message retention period |

### ktranslate

| Variable | Default | Description |
|----------|---------|-------------|
| `ktranslate_image` | `kentik/ktranslate:v2` | Docker image |
| `ktranslate_format` | `flat_json` | Output format |
| `ktranslate_compression` | `gzip` | Compression codec |
| `ktranslate_max_flows_per_message` | `10000` | Max flows batched per Kafka message |
| `ktranslate_log_level` | `info` | Log verbosity |

### Tagging

| Variable | Default | Description |
|----------|---------|-------------|
| `freeform_tags` | `{project="ktranslate-firehose"}` | OCI freeform tags applied to all resources |
| `iam_user_email` | — | Email address for the Streaming IAM user |

---

## Outputs

After a successful `terraform apply`, the following values are printed:

| Output | Description |
|--------|-------------|
| `firehose_endpoint` | HTTPS URL to enter in Kentik Firehose configuration |
| `lb_public_ip` | Raw public IP of the Load Balancer |
| `lb_ocid` | Load Balancer OCID |
| `ktranslate_instance_private_ips` | Private IPs of the ktranslate VMs |
| `ktranslate_instance_ocids` | OCIDs of the ktranslate VMs |
| `streaming_stream_ocid` | OCID of the OCI Stream |
| `streaming_bootstrap_servers` | Kafka bootstrap endpoint |
| `streaming_kafka_topic` | Kafka topic name |
| `streaming_kafka_sasl_username` | SASL username (sensitive) |
| `kafka_auth_token_secret_ocid` | OCID of the Vault secret holding the Kafka auth token |
| `vault_ocid` | OCID of the KMS Vault |
| `vcn_ocid` | OCID of the VCN |

---

## Repository Layout

```
.
├── cloud-init/
│   └── ktranslate.yaml          # cloud-init template rendered by Terraform
└── terraform/
    ├── main.tf                  # Provider config, data sources, locals
    ├── variables.tf             # All input variable declarations
    ├── outputs.tf               # Stack outputs
    ├── networking.tf            # VCN, subnets, gateways, NSGs
    ├── compute.tf               # ktranslate VM instances + cloud-init rendering
    ├── load_balancer.tf         # Public OCI Load Balancer + TLS
    ├── streaming.tf             # OCI Streaming pool and stream
    ├── iam.tf                   # IAM user, group, policy, auth token, KMS Vault
    └── terraform.tfvars.example # Example variable values (safe to commit)
```

---

## Security Notes

- **State file** — Terraform state contains the IAM auth token in plaintext. Use a remote, encrypted backend (e.g. OCI Object Storage with SSE) for any environment beyond local testing.  
  Uncomment the `backend "http" {}` block in `main.tf` and configure it for your bucket.
- **TLS certificate** — The default self-signed certificate is generated locally by Terraform. For production, provision a certificate in [OCI Certificates Service](https://docs.oracle.com/en-us/iaas/Content/certificates/overview.htm) and supply its OCID via `lb_certificate_ocid`.
- **Credential rotation** — The Kafka auth token (`oci_identity_auth_token.ktranslate_streaming`) cannot be updated in-place. Rotate by running `terraform taint oci_identity_auth_token.ktranslate_streaming && terraform apply`.
- **Network Security Groups** — ktranslate VMs are in a private subnet with no public IP. Inbound flow traffic is accepted only from the Load Balancer NSG; all other ingress is denied.

---

## Destroying the Stack

```bash
cd terraform
terraform destroy
```

> **Note:** OCI Vault keys enter a pending-deletion state (minimum 7 days) when destroyed via Terraform. This is an OCI platform control and cannot be bypassed.

---

## License

MIT
