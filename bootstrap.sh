#!/usr/bin/env bash
# DubSync launcher for the original DubSync-Resource-Managed Telegram bot.
# Run from an SSHX Linux shell. The original Rust synchronization/muxing source is not patched.
set -Eeuo pipefail
umask 077

OWNER="dusolcc-pixel"
PRIVATE_REPO="DubSync-Resource-Managed"
PRIVATE_BRANCH="main"
GIT_URL="https://github.com/${OWNER}/${PRIVATE_REPO}.git"
REPO_DIR="$HOME/DubSync-Resource-Managed"

# Keep the launcher/vault repository separate from the private application repository.
LAUNCHER_REPO="launcher-dubzincsyncwzml"
LAUNCHER_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${LAUNCHER_REPO}/${LAUNCHER_BRANCH}"
VAULT_URL="${RAW_BASE}/vault.enc"

WORK_DIR="${DUBSYNC_WORK_DIR:-$HOME/dubsync-work}"
RUNTIME_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dubsync-runtime"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dubsync"
RUNTIME_SETTINGS="$CONFIG_DIR/settings.json"

say() { printf '\n\033[1;36m[DubSync]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "This launcher supports Linux SSHX environments only."
command -v apt-get >/dev/null 2>&1 || die "Ubuntu/Debian apt-get is required."

if [[ "${EUID}" -eq 0 ]]; then SUDO=(); elif command -v sudo >/dev/null 2>&1; then SUDO=(sudo); else die "Need root or sudo to install system packages."; fi

say "Installing system dependencies..."
"${SUDO[@]}" apt-get update -y
"${SUDO[@]}" apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential pkg-config ffmpeg mkvtoolnix aria2 rclone \
  python3 python3-venv python3-pip

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg was not installed."
command -v ffprobe >/dev/null 2>&1 || die "ffprobe was not installed."
command -v mkvmerge >/dev/null 2>&1 || say "WARNING: mkvmerge is unavailable; FFmpeg-based operations can still run."

say "FFmpeg environment: $(ffmpeg -version | head -n 1)"
say "FFprobe environment: $(ffprobe -version | head -n 1)"

TMP_BASE="${XDG_RUNTIME_DIR:-/dev/shm}"
[[ -d "$TMP_BASE" && -w "$TMP_BASE" ]] || TMP_BASE="${TMPDIR:-/tmp}"
WORK_TMP="$(mktemp -d "${TMP_BASE%/}/dubsync-bootstrap.XXXXXX")"
chmod 700 "$WORK_TMP"
cleanup() { rm -rf "$WORK_TMP"; }
trap cleanup EXIT INT TERM

say "Fetching encrypted credential vault..."
curl --fail --silent --show-error --location "$VAULT_URL" -o "$WORK_TMP/vault.enc" \
  || die "Could not download $VAULT_URL. Ensure vault.enc exists at the root of the public launcher repository."

say "Preparing isolated vault decryptor..."
python3 -m venv "$WORK_TMP/venv"
"$WORK_TMP/venv/bin/python" -m pip install --disable-pip-version-check --quiet cryptography

say "Unlock your credential vault. The master passphrase is not saved."
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
for required in ("DUBSYNC_GITHUB_TOKEN", "BOT_TOKEN", "TELEGRAM_ALLOWED_USER_ID"):
    if not data.get(required):
        raise SystemExit(f"Vault is missing {required}")
if not str(data["TELEGRAM_ALLOWED_USER_ID"]).isdigit():
    raise SystemExit("Vault Telegram user ID is invalid")

lines = []
for key, value in data.items():
    if key in allowed and value is not None:
        lines.append(f"export {key}={shlex.quote(str(value))}")
fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("Credential vault unlocked successfully.")
PY

set -a
# shellcheck disable=SC1090
source "$WORK_TMP/secrets.sh"
set +a
rm -f "$WORK_TMP/secrets.sh" "$WORK_TMP/vault.enc"

[[ "$TELEGRAM_ALLOWED_USER_ID" =~ ^[0-9]+$ ]] || die "Invalid Telegram user ID in vault."

say "Installing Rust stable if needed..."
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || die "Rust installation failed."

# Keep credentials out of the Git URL and process arguments.
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

say "Fetching private repository ${OWNER}/${PRIVATE_REPO} (${PRIVATE_BRANCH})..."
if [[ -d "$REPO_DIR/.git" ]]; then
  origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  [[ "$origin" == "$GIT_URL" ]] || die "Existing checkout at $REPO_DIR has a different origin ($origin). Move it aside before retrying."
  git -C "$REPO_DIR" checkout "$PRIVATE_BRANCH"
  git -C "$REPO_DIR" -c credential.helper= pull --ff-only origin "$PRIVATE_BRANCH"
elif [[ -e "$REPO_DIR" ]]; then
  die "$REPO_DIR exists but is not a Git checkout. Move it aside before retrying."
else
  git -c credential.helper= clone --depth 1 --branch "$PRIVATE_BRANCH" "$GIT_URL" "$REPO_DIR"
fi
rm -f "$ASKPASS"
unset GIT_ASKPASS GIT_TERMINAL_PROMPT DUBSYNC_GITHUB_TOKEN

[[ -f "$REPO_DIR/Cargo.toml" ]] || die "The checked-out repository has no Cargo.toml."
[[ -f "$REPO_DIR/Cargo.lock" ]] || die "The checked-out repository has no Cargo.lock; expected the original locked project."
[[ -f "$REPO_DIR/bot/telegram_bot.py" ]] || die "The checked-out repository has no bot/telegram_bot.py."

cd "$REPO_DIR"
mkdir -p "$WORK_DIR" "$RUNTIME_DIR"
chmod 700 "$WORK_DIR" "$RUNTIME_DIR"

# The original Colab file ends in top-level `await run_bot()`, which is valid in
# notebooks but not in a regular Python process. Create a runtime-only copy with
# asyncio.run(); do not edit the tracked original bot or any Rust source.
say "Creating a Python runtime entry point without editing repository sources..."
"$(command -v python3)" - "$REPO_DIR/bot/telegram_bot.py" "$RUNTIME_DIR/telegram_bot.py" <<'PY'
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:3])
text = source.read_text(encoding="utf-8")
stripped = text.rstrip()
if stripped.endswith("await run_bot()"):
    text = stripped[:-len("await run_bot()")] + "asyncio.run(run_bot())\n"
elif stripped.endswith("asyncio.run(run_bot())"):
    text = stripped + "\n"
else:
    raise SystemExit(
        "Could not identify the expected bot entry point. No source files were changed. "
        "Review the final lines of bot/telegram_bot.py before adapting the launcher."
    )
target.write_text(text, encoding="utf-8")
print(f"Runtime entry point created: {target}")
PY

say "Preparing isolated Python environment..."
VENV="$REPO_DIR/.venv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --disable-pip-version-check --quiet --upgrade pip
"$VENV/bin/python" -m pip install --disable-pip-version-check \
  'python-telegram-bot>=22.0,<23.0' 'requests>=2.31,<3.0' 'psutil>=5.9,<8.0'

say "Building original Rust core (GUI feature disabled for a headless Linux server)..."
source "$HOME/.cargo/env" 2>/dev/null || true
cargo build --release --locked --no-default-features
DUBSYNC_BINARY="$REPO_DIR/target/release/dubsync"
[[ -x "$DUBSYNC_BINARY" ]] || die "Rust binary was not created."

say "Preparing persistent runtime settings outside the Git checkout..."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
export DUBSYNC_PROJECT_DIR="$REPO_DIR"
export DUBSYNC_REPO_DIR="$REPO_DIR"
export DUBSYNC_WORK_DIR="$WORK_DIR"
export DUBSYNC_SETTINGS_PATH="$RUNTIME_SETTINGS"
export DUBSYNC_BINARY
"$VENV/bin/python" - <<'PY'
import json, os, shutil
from pathlib import Path
source = Path("settings.json")
target = Path(os.environ["DUBSYNC_SETTINGS_PATH"])
reset = os.environ.get("DUBSYNC_RESET_SETTINGS", "0").strip() == "1"
if reset or not target.exists():
    if source.is_file():
        shutil.copyfile(source, target)
    else:
        target.write_text("{}\n", encoding="utf-8")
try:
    settings = json.loads(target.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    raise SystemExit(f"Invalid runtime settings JSON at {target}: {exc}")
if not isinstance(settings, dict):
    raise SystemExit("Runtime settings must contain a JSON object")
settings.setdefault("security", {})["allowed_user_ids"] = [int(os.environ["TELEGRAM_ALLOWED_USER_ID"])]
settings.setdefault("paths", {})["dubsync_binary"] = os.environ["DUBSYNC_BINARY"]
remote = os.environ.get("RCLONE_REMOTE_PATH", "").strip()
if remote:
    settings.setdefault("uploads", {}).setdefault("rclone", {})["remote_path"] = remote
target.write_text(json.dumps(settings, indent=4) + "\n", encoding="utf-8")
print(f"Runtime settings: {target}")
print("The Git checkout's settings.json is not modified.")
print("Codec, synchronization and resource settings are preserved; edit this runtime settings file and use /reload_settings for live reload.")
PY

say "Checking runtime Python syntax..."
"$VENV/bin/python" -m py_compile "$RUNTIME_DIR/telegram_bot.py"
export PATH="$REPO_DIR/target/release:$PATH"

say "Build environment summary:"
say "$(rustc --version)"
say "$(cargo --version)"
say "$(python3 --version)"
say "$(ffmpeg -version | head -n 1)"
say "$(ffprobe -version | head -n 1)"

say "Starting the original Telegram bot. Keep this SSHX session open."
exec "$VENV/bin/python" "$RUNTIME_DIR/telegram_bot.py"
