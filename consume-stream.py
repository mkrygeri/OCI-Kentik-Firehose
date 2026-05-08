#!/usr/bin/env python3
"""
consume-stream.py
─────────────────
Test consumer for the ktranslate-firehose OCI Stream.

Credentials are fetched automatically from:
  • terraform output  (bootstrap, topic, SASL username)
  • OCI Vault secret  (Kafka auth token / SASL password)

Requirements (installed automatically on first run):
  pip install confluent-kafka

Usage:
  python3 consume-stream.py                   # tail from latest (live)
  python3 consume-stream.py --from-beginning  # replay all retained messages
  python3 consume-stream.py --count 50        # stop after 50 messages
  python3 consume-stream.py --raw             # print raw bytes, no JSON parse
"""

import argparse
import base64
import gzip
import json
import subprocess
import sys
import os

# ── Dependency bootstrap ──────────────────────────────────────────────────────

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VENV_DIR   = os.path.join(SCRIPT_DIR, ".consumer-venv")
VENV_PY    = os.path.join(VENV_DIR, "bin", "python3")


def ensure_confluent_kafka():
    """Install confluent-kafka into a local venv and re-exec if needed."""
    # Already inside the venv — nothing to do
    if sys.prefix == VENV_DIR:
        return

    # Venv doesn't exist yet — create it and install
    if not os.path.isfile(VENV_PY):
        print("[*] Creating local venv at .consumer-venv ...", flush=True)
        subprocess.check_call([sys.executable, "-m", "venv", VENV_DIR])
        print("[*] Installing confluent-kafka ...", flush=True)
        subprocess.check_call([VENV_PY, "-m", "pip", "install", "--quiet", "confluent-kafka"])

    # Re-exec with the venv's Python, forwarding all arguments
    os.execv(VENV_PY, [VENV_PY, __file__] + sys.argv[1:])


ensure_confluent_kafka()

from confluent_kafka import Consumer, KafkaError, KafkaException  # noqa: E402

# ── Credential helpers ────────────────────────────────────────────────────────

TERRAFORM_DIR = os.path.join(SCRIPT_DIR, "terraform")


def tf_output() -> dict:
    """Return parsed terraform output JSON from the terraform/ directory."""
    env = {**os.environ, "SUPPRESS_LABEL_WARNING": "True"}
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=TERRAFORM_DIR,
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        sys.exit(f"[!] terraform output failed:\n{result.stderr}")
    return json.loads(result.stdout)


def get_vault_secret(secret_ocid: str) -> str:
    """Retrieve and decode a Base64 secret from OCI Vault via the OCI CLI."""
    env = {**os.environ, "SUPPRESS_LABEL_WARNING": "True"}
    result = subprocess.run(
        [
            "oci", "secrets", "secret-bundle", "get",
            "--secret-id", secret_ocid,
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        sys.exit(f"[!] OCI Vault fetch failed:\n{result.stderr}")
    bundle = json.loads(result.stdout)
    b64 = bundle["data"]["secret-bundle-content"]["content"]
    return base64.b64decode(b64).decode()


# ── Message display ───────────────────────────────────────────────────────────

def decompress(data: bytes) -> bytes:
    """Decompress gzip data if the magic bytes are present, otherwise pass through."""
    if data[:2] == b'\x1f\x8b':
        return gzip.decompress(data)
    return data


def print_message(msg, raw: bool, index: int):
    print(f"\n─── message {index} "
          f"| partition={msg.partition()} offset={msg.offset()} "
          f"| {len(msg.value())} bytes ───")
    value = decompress(msg.value())
    if raw:
        print(value.decode(errors="replace"))
        return
    # ktranslate flat_json is newline-delimited records; try to parse
    text = value.decode(errors="replace")
    try:
        # May be a JSON array or newline-delimited objects
        if text.strip().startswith("["):
            records = json.loads(text)
            for rec in records[:5]:  # show first 5 records
                print(json.dumps(rec, indent=2))
            if len(records) > 5:
                print(f"  … ({len(records) - 5} more records in this message)")
        else:
            lines = [l for l in text.splitlines() if l.strip()]
            for line in lines[:5]:
                try:
                    print(json.dumps(json.loads(line), indent=2))
                except json.JSONDecodeError:
                    print(line)
            if len(lines) > 5:
                print(f"  … ({len(lines) - 5} more lines in this message)")
    except (json.JSONDecodeError, UnicodeDecodeError):
        print(text[:500])


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="OCI Streaming / ktranslate test consumer")
    parser.add_argument("--from-beginning", action="store_true",
                        help="Reset offsets and replay from the earliest retained message")
    parser.add_argument("--count", type=int, default=0,
                        help="Stop after consuming this many messages (0 = run until Ctrl+C)")
    parser.add_argument("--raw", action="store_true",
                        help="Print raw message bytes instead of pretty-printing JSON")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="Poll timeout in seconds before printing a 'waiting' notice (default 30)")
    args = parser.parse_args()

    # ── Fetch connection details ──────────────────────────────────────────────
    print("[*] Fetching Terraform outputs...", flush=True)
    outputs = tf_output()
    bootstrap    = outputs["streaming_bootstrap_servers"]["value"]
    topic        = outputs["streaming_kafka_topic"]["value"]
    sasl_user    = outputs["streaming_kafka_sasl_username"]["value"]
    secret_ocid  = outputs["kafka_auth_token_secret_ocid"]["value"]

    print(f"    bootstrap : {bootstrap}")
    print(f"    topic     : {topic}")
    print(f"    sasl_user : {sasl_user}")

    print("[*] Fetching Kafka auth token from OCI Vault...", flush=True)
    sasl_pass = get_vault_secret(secret_ocid)
    print("    auth token: [retrieved]", flush=True)

    # ── Build consumer config ─────────────────────────────────────────────────
    auto_offset = "earliest" if args.from_beginning else "latest"
    conf = {
        "bootstrap.servers":       bootstrap,
        "security.protocol":       "SASL_SSL",
        "sasl.mechanism":          "PLAIN",
        "sasl.username":           sasl_user,
        "sasl.password":           sasl_pass,
        "group.id":                "ktranslate-test-consumer",
        "auto.offset.reset":       auto_offset,
        "enable.auto.commit":      False,   # don't advance server-side offsets
        "session.timeout.ms":      30000,
    }

    consumer = Consumer(conf)

    if args.from_beginning:
        # Assign partitions with OFFSET_BEGINNING so replay starts from retention start
        from confluent_kafka import TopicPartition, OFFSET_BEGINNING
        meta = consumer.list_topics(topic, timeout=15)
        if topic not in meta.topics:
            sys.exit(f"[!] Topic '{topic}' not found on broker")
        partitions = [
            TopicPartition(topic, p, OFFSET_BEGINNING)
            for p in meta.topics[topic].partitions.keys()
        ]
        consumer.assign(partitions)
        print(f"[*] Assigned {len(partitions)} partition(s) at OFFSET_BEGINNING")
    else:
        consumer.subscribe([topic])
        print(f"[*] Subscribed to '{topic}' (waiting for new messages)...")

    print(f"[*] Auto-offset reset: {auto_offset}")
    print(f"[*] Press Ctrl+C to stop\n", flush=True)

    count = 0
    try:
        while True:
            msg = consumer.poll(timeout=args.timeout)
            if msg is None:
                print(f"[~] No messages in the last {args.timeout:.0f}s — still waiting...", flush=True)
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    print(f"[~] Reached end of partition {msg.partition()}")
                    continue
                raise KafkaException(msg.error())

            count += 1
            print_message(msg, args.raw, count)

            if args.count and count >= args.count:
                print(f"\n[*] Reached --count {args.count}, stopping.")
                break
    except KeyboardInterrupt:
        print(f"\n[*] Interrupted. Consumed {count} message(s).")
    finally:
        consumer.close()


if __name__ == "__main__":
    main()
