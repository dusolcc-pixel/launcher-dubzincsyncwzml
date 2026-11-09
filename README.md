# DubSync launcher for the original managed repository

This launcher targets the private repository:

- Owner: `dusolcc-pixel`
- Repository: `DubSync-Resource-Managed`
- Branch: `main`

It builds the repository's original Rust CLI with `--no-default-features` for a headless Linux environment, then starts the Telegram bot. It does **not** patch the Rust synchronization or FFmpeg muxing source.

## What it adapts

The original Telegram bot source ends with notebook-style top-level `await run_bot()`. A normal Python process cannot execute that syntax. The launcher therefore creates a runtime-only copy in `$HOME/.cache/dubsync-runtime/telegram_bot.py` with the final call changed to `asyncio.run(run_bot())`. The tracked `bot/telegram_bot.py` and all Rust sources remain untouched.

The launcher installs FFmpeg, FFprobe, MKVToolNix, rclone, Python and Rust; clones or fast-forward pulls the private `main` branch; builds the Rust CLI; and starts the bot using the encrypted vault.

## Vault setup

1. Run `python3 -m pip install cryptography` on a trusted local machine.
2. Run `python3 make_vault.py` and enter your GitHub read-only token, Telegram bot token, Telegram numeric user ID, and upload credentials.
3. Upload the resulting `vault.enc` to the root of the public `launcher-dubzincsyncwzml` repository on its `main` branch. Do not upload plaintext `.env` files or share tokens in chat.
4. Keep the vault passphrase separate from the repository.

The GitHub token needs read access to the private `DubSync-Resource-Managed` repository's contents. It is read through Git's askpass helper and is not embedded in the clone URL.

## Run

After committing `bootstrap.sh` to the root of the public launcher repository, run this from the SSHX Linux shell:

```bash
curl -fsSL https://raw.githubusercontent.com/dusolcc-pixel/launcher-dubzincsyncwzml/main/bootstrap.sh | bash
```

The launcher prints the installed FFmpeg and Rust versions. Compare the FFmpeg version line with the output from the working Colab environment before treating the environment as fully matched.

## Notes

- The `vault.enc` file is deliberately not included in this package. Keep using your separately stored encrypted vault or generate a new one locally.
- The launcher only updates `security.allowed_user_ids` and `paths.dubsync_binary` in `settings.json` (plus an explicit `RCLONE_REMOTE_PATH` override). It does not hard-code new audio codec or synchronization resource values.
- The launcher requires a Linux environment with `apt-get`, sudo/root access, network access and enough memory/disk to compile Rust.
