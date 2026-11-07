#!/usr/bin/env python3
"""Create an encrypted DubSync credential vault. Plaintext secrets are never written to disk."""
from __future__ import annotations

import base64
import getpass
import json
import os
import secrets
import sys
from pathlib import Path

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print("Missing dependency. Install it with: python3 -m pip install cryptography", file=sys.stderr)
    raise SystemExit(2)

OUT = Path(__file__).resolve().parent / "vault.enc"


def ask(label: str, *, required: bool = False, hidden: bool = True) -> str:
    while True:
        prompt = label + (" (required)" if required else " (Enter to skip)") + ": "
        value = getpass.getpass(prompt) if hidden else input(prompt)
        value = value.strip()
        if value or not required:
            return value
        print("This value is required.")


def main() -> None:
    print("DubSync encrypted credential vault builder")
    print("Secrets are prompted locally and encrypted before vault.enc is written.")
    print("Do not paste credentials into ChatGPT or commit plaintext files.\n")

    github_token = ask("GitHub fine-grained token (Contents: Read-only for your private repo)", required=True)
    bot_token = ask("Telegram BOT_TOKEN", required=True)
    telegram_id = ask("Your numeric Telegram user ID", required=True, hidden=False)
    viking_hash = ask("VIKING_HASH", required=True)
    rclone_b64 = ask("RCLONE_CONFIG_B64 (base64 of the complete rclone.conf; preferred)")
    rclone_text = ""
    if not rclone_b64:
        config_path = ask("Path to a local complete rclone.conf file (alternative to B64)", required=True, hidden=False)
        try:
            rclone_text = Path(config_path).expanduser().read_text(encoding="utf-8")
        except Exception as exc:
            raise SystemExit(f"Could not read rclone config file: {exc}")
    data = {
        "DUBSYNC_GITHUB_TOKEN": github_token,
        "BOT_TOKEN": bot_token,
        "TELEGRAM_ALLOWED_USER_ID": telegram_id,
        "VIKING_HASH": viking_hash,
        "RCLONE_CONFIG_B64": rclone_b64,
        "RCLONE_CONFIG_TEXT": rclone_text,
        "RCLONE_CONFIG_PASS": ask("RCLONE_CONFIG_PASS (only if your rclone config is encrypted)"),
        "RCLONE_REMOTE_PATH": ask("Rclone remote path override, e.g. fakeopcb1:Sync: (Enter keeps settings.json)"),
    }

    if not data["TELEGRAM_ALLOWED_USER_ID"].isdigit():
        raise SystemExit("Telegram user ID must contain digits only.")
    if data["RCLONE_CONFIG_B64"]:
        import re
        compact = "".join(data["RCLONE_CONFIG_B64"].split())
        try:
            decoded = base64.b64decode(compact + "=" * ((-len(compact)) % 4), validate=True)
        except Exception as exc:
            raise SystemExit(f"RCLONE_CONFIG_B64 is not valid base64: {exc}")
        if not (decoded.lstrip().startswith(b"[") or decoded.lstrip().startswith(b"RCLONE_ENCRYPT_V0:")):
            raise SystemExit("RCLONE_CONFIG_B64 must decode to the complete rclone.conf file.")
    if not data["DUBSYNC_GITHUB_TOKEN"].startswith(("github_pat_", "ghp_")):
        print("Warning: token prefix is not a common GitHub PAT prefix. Verify it has private-repository Contents: Read-only access.")

    password = getpass.getpass("Create a strong vault master passphrase (20+ characters recommended): ")
    if len(password) < 16:
        raise SystemExit("Use a passphrase of at least 16 characters.")
    confirm = getpass.getpass("Confirm master passphrase: ")
    if password != confirm:
        raise SystemExit("Passphrases do not match.")

    # scrypt N=2^15, r=8, p=1 (32 MiB memory), followed by AES-256-GCM.
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(12)
    from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    kdf = Scrypt(salt=salt, length=32, n=2**15, r=8, p=1)
    key = kdf.derive(password.encode("utf-8"))
    plaintext = json.dumps(data, separators=(",", ":")).encode("utf-8")
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, b"DubSync-SSHX-Vault-v1")

    vault = {
        "format": "dubsync-sshx-vault",
        "version": 1,
        "kdf": "scrypt-n32768-r8-p1",
        "cipher": "AES-256-GCM",
        "salt": base64.b64encode(salt).decode("ascii"),
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(OUT, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(vault, f, indent=2)
        f.write("\n")
    print(f"\nEncrypted vault created: {OUT}")
    print("Upload ONLY vault.enc to the public DubSync-Launcher repository.")
    print("Keep the master passphrase separate. Anyone with both the vault and passphrase can decrypt all credentials.")


if __name__ == "__main__":
    main()
