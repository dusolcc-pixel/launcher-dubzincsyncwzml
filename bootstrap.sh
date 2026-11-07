#!/usr/bin/env bash
# DubSync fresh-SSHX bootstrap. Safe to run via curl | bash.
set -Eeuo pipefail
umask 077

OWNER="dusolcc-pixel"
PRIVATE_REPO="zincdubsyncewzml"
PRIVATE_BRANCH="main"

LAUNCHER_REPO="launcher-dubzincsyncwzml"
LAUNCHER_BRANCH="main"
REPO_DIR="$HOME/zincdubsyncewzml"

RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${LAUNCHER_REPO}/${LAUNCHER_BRANCH}"
VAULT_URL="${RAW_BASE}/vault.enc"

say() { printf '\n\033[1;36m[DubSync][0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR][0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "This launcher currently supports Linux SSHX environments only."
command -v apt-get >/dev/null 2>&1 || die "Ubuntu/Debian apt-get is required."

if [[ "${EUID}" -eq 0 ]]; then SUDO=(); elif command -v sudo >/dev/null 2>&1; then SUDO=(sudo); else die "Need root or sudo to install system packages."; fi

say "Preparing system dependencies..."
"${SUDO[@]}" apt-get update -y
"${SUDO[@]}" apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential pkg-config ffmpeg mkvtoolnix aria2 rclone \
  python3 python3-venv python3-pip

say "Fetching public encrypted credential vault..."
TMP_BASE="${XDG_RUNTIME_DIR:-/dev/shm}"
[[ -d "$TMP_BASE" && -w "$TMP_BASE" ]] || TMP_BASE="${TMPDIR:-/tmp}"
WORK_TMP="$(mktemp -d "${TMP_BASE%/}/dubsync-bootstrap.XXXXXX")"
chmod 700 "$WORK_TMP"
cleanup() { rm -rf "$WORK_TMP"; }
trap cleanup EXIT INT TERM
curl --fail --silent --show-error --location "$VAULT_URL" -o "$WORK_TMP/vault.enc" || die "Could not download $VAULT_URL. Create the public launcher repository and upload vault.enc first."

say "Preparing isolated decryptor..."
python3 -m venv "$WORK_TMP/venv"
"$WORK_TMP/venv/bin/python" -m pip install --disable-pip-version-check --quiet cryptography

say "Unlock your credential vault. The master passphrase is never saved."
"$WORK_TMP/venv/bin/python" - "$WORK_TMP/vault.enc" "$WORK_TMP/secrets.sh" <<'PY'
import base64, getpass, json, os, shlex, sys
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

vault_path, out_path = map(Path, sys.argv[1:3])
try:
    v = json.loads(vault_path.read_text(encoding="utf-8"))
    if v.get("format") != "dubsync-sshx-vault" or v.get("version") != 1:
        raise ValueError("Unrecognized vault format/version")
    if v.get("cipher") != "AES-256-GCM" or v.get("kdf") != "scrypt-n32768-r8-p1":
        raise ValueError("Unsupported encryption parameters")
    password = getpass.getpass("Vault master passphrase: ")
    salt = base64.b64decode(v["salt"], validate=True)
    nonce = base64.b64decode(v["nonce"], validate=True)
    ciphertext = base64.b64decode(v["ciphertext"], validate=True)
    key = Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(password.encode("utf-8"))
    raw = AESGCM(key).decrypt(nonce, ciphertext, b"DubSync-SSHX-Vault-v1")
    data = json.loads(raw)
except Exception as exc:
    print(f"Vault could not be unlocked: {exc}", file=sys.stderr)
    raise SystemExit(2)

allowed = {
    "DUBSYNC_GITHUB_TOKEN", "BOT_TOKEN", "TELEGRAM_ALLOWED_USER_ID", "VIKING_HASH",
    "RCLONE_CONFIG_B64", "RCLONE_CONFIG_TEXT", "RCLONE_CONFIG_PASS", "RCLONE_REMOTE_PATH"
}
if not isinstance(data, dict):
    raise SystemExit("Vault payload is not an object")
if not data.get("DUBSYNC_GITHUB_TOKEN") or not data.get("BOT_TOKEN"):
    raise SystemExit("Vault is missing DUBSYNC_GITHUB_TOKEN or BOT_TOKEN")
if not str(data.get("TELEGRAM_ALLOWED_USER_ID", "")).isdigit():
    raise SystemExit("Vault Telegram user ID is missing or invalid")
if not data.get("VIKING_HASH"):
    raise SystemExit("Vault is missing VIKING_HASH")
if not (data.get("RCLONE_CONFIG_B64") or data.get("RCLONE_CONFIG_TEXT")):
    raise SystemExit("Vault is missing the rclone config")

lines = []
for key, value in data.items():
    if key in allowed and value is not None:
        lines.append(f"export {key}={shlex.quote(str(value))}")
fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("Credential vault unlocked successfully.")
PY

# Import the decrypted credentials into this shell, then immediately unlink the temporary file.
set -a
# shellcheck disable=SC1090
source "$WORK_TMP/secrets.sh"
set +a
rm -f "$WORK_TMP/secrets.sh" "$WORK_TMP/vault.enc"

[[ "$TELEGRAM_ALLOWED_USER_ID" =~ ^[0-9]+$ ]] || die "Invalid Telegram user ID in vault."

say "Installing Rust stable if it is not already available..."
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || die "Rust installation failed."

# Git uses askpass, not a token embedded in the URL or command line.
ASKPASS="$WORK_TMP/git-askpass.sh"
cat > "$ASKPASS" <<'ASK'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "$DUBSYNC_GITHUB_TOKEN" ;;
esac
ASK
chmod 700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0
GIT_URL="https://github.com/${OWNER}/${PRIVATE_REPO}.git"

say "Downloading your private DubSync repository..."
if [[ -d "$REPO_DIR/.git" ]]; then
  # Remove the previous runtime-only asyncio patch before fast-forwarding.
  git -C "$REPO_DIR" checkout -- bot/telegram_bot.py 2>/dev/null || true
  git -C "$REPO_DIR" -c credential.helper= pull --ff-only origin "$PRIVATE_BRANCH"
elif [[ -e "$REPO_DIR" ]]; then
  die "$REPO_DIR exists but is not a Git checkout. Remove or rename it before retrying."
else
  git -c credential.helper= clone --depth 1 --branch "$PRIVATE_BRANCH" "$GIT_URL" "$REPO_DIR"
fi
rm -f "$ASKPASS"
unset GIT_ASKPASS GIT_TERMINAL_PROMPT DUBSYNC_GITHUB_TOKEN
cd "$REPO_DIR"

# The upstream repository currently ends with top-level `await run_bot()`, which
# raises SyntaxError in a normal Python script. Patch only this final line at runtime.
python3 - <<'PY'
from pathlib import Path
p = Path("bot/telegram_bot.py")
s = p.read_text(encoding="utf-8")
if s.rstrip().endswith("await run_bot()"):
    s = s.rstrip()[:-len("await run_bot()")] + "asyncio.run(run_bot())\n"
    p.write_text(s, encoding="utf-8")
PY

say "Preparing Python environment..."
VENV="$REPO_DIR/.venv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
# requirements.txt is included by the setup patch; provide a fallback for the original repo.
if [[ ! -f "$REPO_DIR/requirements.txt" ]]; then
  cat > "$WORK_TMP/requirements.txt" <<'REQ'
python-telegram-bot>=22.0,<23.0
requests>=2.31,<3.0
psutil>=5.9,<8.0
REQ
  REQ_FILE="$WORK_TMP/requirements.txt"
else
  REQ_FILE="$REPO_DIR/requirements.txt"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
"$VENV/bin/python" -m pip install --disable-pip-version-check -r "$REQ_FILE"

say "Building optimized Rust binary..."
source "$HOME/.cargo/env" 2>/dev/null || true
cargo build --release --no-default-features
[[ -x "$REPO_DIR/target/release/dubsync" ]] || die "Rust binary was not created."

say "Applying resource settings and Telegram allow-list..."
export DUBSYNC_BINARY="$REPO_DIR/target/release/dubsync"
"$VENV/bin/python" - <<'PY'
import json, os
from pathlib import Path
p = Path("settings.json")
s = json.loads(p.read_text(encoding="utf-8"))
s.setdefault("security", {})["allowed_user_ids"] = [int(os.environ["TELEGRAM_ALLOWED_USER_ID"])]
s.setdefault("paths", {})["dubsync_binary"] = os.environ["DUBSYNC_BINARY"]
r = s.setdefault("dubsync", {}).setdefault("resources", {})
r.update({"cpu_threads": 8, "max_ram_gb": 16.0, "ram_reserve_gb": 4.0,
          "auto_fit_ram_to_env": True, "audio_buffer_seconds": 60.0,
          "max_parallel_dubs": 2})
remote = os.environ.get("RCLONE_REMOTE_PATH", "").strip()
if remote:
    s.setdefault("uploads", {}).setdefault("rclone", {})["remote_path"] = remote
p.write_text(json.dumps(s, indent=4) + "\n", encoding="utf-8")
print("Settings applied: 8 CPU workers, 16 GiB splicer budget, 4 GiB reserve, 60s audio blocks, 2 parallel donors.")
print("Telegram access restricted to the configured user ID.")
PY

say "Checking upload credentials and rclone remote..."
[[ -n "${VIKING_HASH:-}" ]] && say "VikingFile credential loaded." || say "WARNING: VikingFile credential missing."
if [[ -n "${RCLONE_CONFIG_B64:-}${RCLONE_CONFIG_TEXT:-}" ]]; then
  # The bot restores the full config itself. This check is advisory and does not block startup.
  say "Rclone configuration secret loaded. The bot will validate the configured remote when uploading."
else
  say "WARNING: rclone configuration missing."
fi

say "Checking Python syntax..."
"$VENV/bin/python" -m py_compile bot/telegram_bot.py
export DUBSYNC_BINARY PATH="$REPO_DIR/target/release:$PATH"

say "Starting Telegram bot. Keep this SSHX session open."
"$VENV/bin/python" bot/telegram_bot.py
