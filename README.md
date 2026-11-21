# AppMan

A personal, local-first registry for the applications you own: where the code lives, where each environment runs, how to deploy it, how to reach its admin consoles, and which credentials and runtime secrets it needs.

Everything is stored in one encrypted database on your machine, protected by a master password. Optionally, encrypted backups go to a private folder in your Google Drive. Google never sees plaintext or the key.

> **Status:** working Windows and Linux desktop app, built for a single user. It has not had an independent security audit. See [Security](#security-model-and-limits) before storing anything critical.

## Why

Side projects and client apps accumulate: a GitHub repo here, a droplet there, a shared-hosting panel, a dozen API keys, a `.env` nobody remembers. AppMan keeps that in one searchable place instead of scattered across notes, browser bookmarks and password-manager entries that don't say which app they belong to.

It is **not** a CI/CD system (it never deploys anything), not a team vault, and not a general password manager. It only holds secrets that belong to an application.

## Features

- **Applications**: status, tags, owner, criticality, Markdown notes; archive and restore (archive is the soft delete), permanent purge only from the archive.
- **Repositories**: GitHub is first-class (paste `https://…`, `git@github.com:…` or `owner/repo`; get clone URLs and deep links to Actions, deploy keys, Actions secrets, settings). GitLab, Bitbucket and self-hosted URLs are recognised too.
- **Environments and hosting**: production/staging/dev with URLs, deploy method and instructions, last deployed date and version. Hosting targets (DigitalOcean, Superhosting, AWS, Azure, Vercel, VPS) are shared across apps, with a "what runs here" reverse view.
- **Credentials and runtime secrets**:
  - Access credentials (logins, API keys, SSH and deploy keys, certificates) and per-environment runtime secrets (DB user/password, env vars).
  - Masked by default; reveal auto-hides; copy clears the clipboard after a delay (only if it still holds your value).
  - Password generator, per-credential history, expiry dates, "mark rotated", custom fields, "open URL and copy secret".
  - `.env` import with a preview (added / updated / unchanged) and export that asks for your master password again.
- **Attachments**: SSH keys, certificates and `.env` files stored inside the encrypted vault.
- **Console links**: labelled links to hosting panels, database admins, DNS, monitoring, launchable from the dashboard and search.
- **Search and dashboard**: global search (Ctrl+K) across everything except secret values; dashboard with expiring credentials, a weak / reused / old / expired report, completeness hints and recently used items.
- **Backups**: debounced rolling local versions, restore, and optional Google Drive upload with a warning if another installation wrote the newest backup.
- **Export / import**: reports without secrets (Markdown, CSV, JSON), a full export with secrets, JSON import and CSV import of applications.
- **Change log**: what changed and when, plus when secrets were revealed or copied. Secret values are never logged.

## Security model and limits

**What is protected**

- The database is a single [SQLCipher](https://www.zetetic.net/sqlcipher/) file (AES-256). A random 256-bit data key encrypts it.
- The data key is wrapped twice with AES-256-GCM: once by a key derived from your master password with **Argon2id** (256 MiB, iterations calibrated on first run to take roughly 0.7 s on your machine) and once by a random **recovery key**. Changing the password or regenerating the recovery key re-wraps the data key; the database is not re-encrypted.
- Only ciphertext leaves your machine: the encrypted database and the key file go to Drive's hidden `appDataFolder` (scope `drive.appdata`, so the app cannot see the rest of your Drive).
- The Google refresh token is protected with Windows DPAPI (or the Secret Service keyring via libsecret on Linux) and kept outside the vault.
- No telemetry. No network access except the optional Drive backup and opening links you click.

**What is not**

- If you lose both the master password and the recovery key, the data is gone by design.
- Anyone who gets the Drive files can try to guess your master password offline, so use a long passphrase. Old backup versions keep the password and recovery key they were made with.
- An attacker with access to your unlocked desktop session or process memory is out of scope. Dart cannot guarantee that key material is wiped from memory on lock.
- Plaintext exports and files you save from attachments are not encrypted once written to disk.
- No independent audit has been done. Treat it accordingly.

## Requirements

- **Windows 10/11**, or a **Linux x64 desktop** (GTK 3, for example Ubuntu 22.04+ or Fedora)
- [Flutter](https://docs.flutter.dev/get-started/install) 3.47+ with desktop support enabled for your platform
- Windows: Visual Studio Build Tools with the **Desktop development with C++** workload
- Linux: the Flutter Linux toolchain plus libsecret, and a running keyring (GNOME Keyring, KWallet, ...) for the optional Drive token:

  ```bash
  sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev
  # runtime only: libsecret-1-0 and gnome-keyring (or another Secret Service provider)
  ```
- WebView2 is *not* needed; the UI is native Flutter

## Build and run

Windows:

```powershell
git clone <this repository>
cd appman\app
flutter pub get
flutter run -d windows            # development
flutter build windows --release   # produces build\windows\x64\runner\Release\appman.exe
```

The release folder is self-contained: it ships `sqlcipher.dll`, `argon2.dll` and the plugin DLLs next to `appman.exe`.

Linux:

```bash
git clone <this repository>
cd appman/app
flutter pub get
flutter run -d linux              # development
flutter build linux --release     # produces build/linux/x64/release/bundle/appman
```

The `bundle/` folder is self-contained: it ships `appman`, `lib/` (SQLCipher, Argon2 and the plugin libraries) and `data/`. Copy the whole folder to install it. Linux builds must be made on Linux; Flutter cannot cross-compile.

The first launch asks you to create a master password and shows your **recovery key once**. Print it or store it offline.

### Where data lives

Folder: `%APPDATA%\AppMan` on Windows, `$XDG_DATA_HOME/AppMan` (default `~/.local/share/AppMan`) on Linux.

| File | Content |
|---|---|
| `vault.db` | the encrypted database |
| `vault.keys` | KDF parameters and the wrapped data keys (useless without the password or recovery key) |
| `backups/` | rolling local backup versions (still encrypted) |
| `*.dpapi` (Windows only) | DPAPI-protected Drive token (not backed up) |

On Linux the Drive token is stored in the Secret Service keyring (entries named `appman.*`) instead of a file.

Set the `APPMAN_HOME` environment variable to use a different folder, for example a throwaway one while developing.

### Google Drive backup (optional)

1. In Google Cloud Console, create a project and enable the **Google Drive API**.
2. Configure the OAuth consent screen and **publish** it. Refresh tokens of apps left in "testing" expire after 7 days.
3. Create an OAuth client of type **Desktop app**.
4. In AppMan open **Settings → Backup**, paste the client ID and secret, and press **Connect Google Drive**.

You bring your own client; nothing is shared with the author.

## Tests

```bash
cd app
flutter analyze
flutter test
```

The suite covers the crypto and key handling, the schema and every store, search and reports, import/export round trips, the backup and Drive sync logic (against an in-memory fake Drive), and widget-level flows through setup, unlock, credentials, `.env` import/export and the dashboard. A few tests call the real Windows APIs (clipboard formats, DPAPI) and are skipped on other platforms.

## Repository layout

```
FUNCTIONAL_SPEC.md   functional description, decisions and implementation status
app/                 the Flutter application
  lib/core/          crypto, vault, database stores, backup, platform bindings, services
  lib/ui/            screens and dialogs
  test/
  windows/, linux/  desktop runners
spike/               throwaway prototype that validated SQLCipher + Argon2id with Flutter on Windows
```

[`FUNCTIONAL_SPEC.md`](FUNCTIONAL_SPEC.md) explains the design decisions (why Flutter, why a wrapped data key, why Drive is backup only) and lists what is implemented versus planned.

## Known limitations

- Windows and Linux only; no installer or package (MSI, .deb, AppImage) yet. macOS is not set up.
- Linux: the vault locks on idle timeout and after resume from sleep but not on screen lock, the "keep out of clipboard history" hint is Windows-only, and Drive backup needs a Secret Service keyring to stay connected between launches.
- Argon2 runs on the UI thread, so the window pauses for about a second while unlocking.
- Windows: a UAC prompt counts as "workstation locked" and locks the vault.
- Not built yet: TOTP codes, breach checks (HIBP), Windows Hello unlock, Bitwarden/KeePass import, live GitHub metadata, URL health checks.
- Single user, single working copy: Drive is a backup, not a sync service.

## Contributing

Issues and pull requests are welcome. Please keep secrets out of logs, the change log and test fixtures, and add tests next to any change to the crypto, key handling or import/export code.

To report a security problem, please open a private security advisory on the repository rather than a public issue.

## License

AppMan is released under the [MIT License](LICENSE).

It builds on third-party software with its own licenses, notably Flutter (BSD-3-Clause), SQLCipher community edition (BSD-style) and the OpenSSL it links on Windows and Linux (Apache-2.0), Argon2 (CC0 / Apache-2.0), and the Dart packages listed in `app/pubspec.yaml`. If you redistribute binaries, include their notices. Flutter can list them for you: the `LicenseRegistry` holds every package license in the build.
