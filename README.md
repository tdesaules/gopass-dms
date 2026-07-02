# GoPass DMS

A [DankMaterialShell](https://danklinux.com) **launcher** plugin that lets you search,
copy and edit secrets stored in a [gopass](https://github.com/gopasspw/gopass) vault
(`age` backend) straight from the launcher bar.

Two ways to unlock (auto-detected at load):

- **pinentry-dms** (preferred): if [`pinentry-dms`](https://github.com/tdesaules/pinentry-dms)
  is wired up end-to-end, the plugin lets gopass drive it — a native DMS modal handles
  the passphrase and the age agent caches the unlock across restarts.
- **Builtin passphrase dialog** (fallback): otherwise the plugin captures the
  passphrase in a DMS window and injects it via `GOPASS_AGE_PASSWORD`, so
  `pinentry` is never spawned.

## Features

- **`pass` trigger** in the launcher to activate the plugin
- **Live, multi-word search** through the whole vault (case-insensitive)
- **Local cache** of secret paths for instant display, refreshed in the background
- **Copy actions** (Enter or Tab menu):
  - Password (`gopass show -c`)
  - Username / any body field (`gopass show -c <secret> <field>`)
  - TOTP code (`gopass totp -c`)
- **Edit secret** — a native editor window loads the full content and saves it back
  (`gopass show -f` → `gopass insert -f`)
- **Add new secret** — a path-entry popup, then the editor, to create a new
  secret (`gopass insert -f`)
- **Delete secret** — a confirmation popup guards `gopass rm -f`
- **Sync vault** — `gopass sync` (git pull/push) then rebuild the cache
- **Auto-detected pinentry-dms** support: when
  [`pinentry-dms`](https://github.com/tdesaules/pinentry-dms) is wired up, gopass
  drives it (native DMS modal + age-agent caching) and the plugin stays out of
  the way. Otherwise it falls back to a **builtin passphrase dialog** that
  injects `GOPASS_AGE_PASSWORD` and caches the passphrase **in memory for the
  session**.

## Requirements

- [DankMaterialShell](https://danklinux.com) >= 1.4.0
- [gopass](https://github.com/gopasspw/gopass) >= 1.16, initialized and configured
  with the **`age`** backend (`gopass init --crypto age`)
- The vault must be unlocked/initialized (`gopass init`)

> Unlocking relies on the `age` backend. The GPG backend is not supported.
> The builtin fallback uses gopass's `GOPASS_AGE_PASSWORD` environment variable;
> pinentry-dms uses gopass's pinentry resolution (see below).

## pinentry-dms integration

This plugin auto-detects [`pinentry-dms`](https://github.com/tdesaules/pinentry-dms)
at load time. If **both** of the following are true, it switches to pinentry-dms
mode and stops injecting `GOPASS_AGE_PASSWORD` (which would otherwise bypass it):

1. The **`pinentryDms`** DMS plugin is enabled
   (`~/.config/DankMaterialShell/plugin_settings.json` → `"pinentryDms": { "enabled": true }`)
2. A **pinentry directive** points at the `pinentry-dms` binary, in **either**:
   - gopass's age config (`~/.config/gopass/config` → `[age]` section,
     `pinentry = .../pinentry-dms`), **or**
   - gpg-agent's config (`~/.gnupg/gpg-agent.conf` →
     `pinentry-program .../pinentry-dms`)

   The gopass age agent honors the gpg-agent setting even when no `gpg-agent`
   daemon is running.

To set it up:

```sh
# 1. Install pinentry-dms + its pinentryDms DMS plugin (see its README)

# 2. Point gopass at it — pick EITHER location:
#    a) ~/.config/gopass/config
[age]
agent-enabled = true
pinentry = /home/<you>/.local/share/mise/shims/pinentry-dms
#    b) — or — ~/.gnupg/gpg-agent.conf
pinentry-program /home/<you>/.local/share/mise/shims/pinentry-dms

# 3. Reload; detection logs the result
dms ipc call plugins reload gopassDms
journalctl --user -u dms.service -f | grep GopassDms
# → GopassDms: pinentry-dms detection plugin=true gopass=true => true
```

In pinentry-dms mode the unlock is handled by gopass + the age agent, so the
passphrase is entered once per agent lifetime (it survives DMS restarts, unlike
the builtin in-memory cache). If either condition is missing, the plugin falls
back to the builtin passphrase dialog automatically.

## Installation

### From GitHub

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
git clone https://github.com/tdesaules/gopass-dms.git ~/.config/DankMaterialShell/plugins/gopass-dms
dms restart
```

### Activation

1. Open **Settings → Plugins**
2. Click **Scan for Plugins**
3. Enable **GoPass DMS**
4. Restart the shell: `dms restart`

## Usage

1. Open the launcher (Ctrl+Space or the launcher button)
2. Type `pass` — the plugin lists the vault's secrets
3. Refine with keywords: `pass github token`

### Selecting a secret

- **Enter** — copy the password to the clipboard
- **Tab** — open the context menu:
  | Action | Description |
  |--------|-------------|
  | **Copy password** | `gopass show -c` |
  | **Copy username** | Copies the `username` body field |
  | **Copy TOTP** | `gopass totp -c` (requires a `totp:` entry, see below) |
  | **Edit secret** | Opens a native editor window |
  | **Delete secret** | `gopass rm -f` (with confirmation) |
  | **Add new secret** | Path popup → editor → `gopass insert -f` |
  | **Sync vault** | `gopass sync` then reloads the cache |

### Display format

The visible name is the last path segment; the comment is the parent path.

Example for `websites/github.com/tdesaules`:
- **Name**: `tdesaules`
- **Comment**: `websites / github.com`

### Passphrase

How a secret is unlocked depends on what the plugin detected at load (see
[pinentry-dms integration](#pinentry-dms-integration)):

- **pinentry-dms mode**: copying/editing a locked secret pops the pinentry-dms
  modal. The age agent caches the unlock, so later calls are instant and persist
  across DMS restarts until the agent relocks.
- **Builtin mode** (fallback): a native passphrase window appears on first use,
  the passphrase is cached in memory for the session, and `pinentry` is never
  invoked. A wrong passphrase shows an error and lets you retry.

### TOTP

Add a `totp` key to a secret's body to enable TOTP codes:

```sh
gopass edit github/me
```
```
<password>
totp: JBSWY3DPEHPK3PXP
```

Then **Copy TOTP** generates `gopass totp -c`. The value can be a bare base32
secret or a full `otpauth://` URI.

### Editing a secret

**Edit secret** loads the full content (line 1 = password, rest = body) into an
editor window. Edit, then **Save** (button or `Ctrl+Enter`) or **Cancel**
(button or `Esc`). Saving commits and pushes to the git remote if `core.autopush`
is enabled.

## Configuration

Available in **Settings → Plugins → GoPass DMS**:

| Setting | Description | Default |
|---------|-------------|---------|
| Trigger | Keyword that activates the plugin in the launcher | `pass` |
| Gopass Binary | Path to the `gopass` executable | `gopass` |
| Max Results | Maximum number of secrets displayed | `50` |

> After changing the trigger, reload the plugin: `dms ipc call plugins reload gopassDms`

## Architecture

```
gopass-dms/
├── plugin.json          # Plugin manifest
├── GopassDmsLauncher.qml   # Launcher component (search, copy, edit, dialogs)
├── GopassDmsSettings.qml   # Settings UI
├── README.md
├── CHANGELOG.md
└── LICENSE
```

### How it works

1. On load and on **Sync vault**, the plugin runs `gopass list --flat`. This lists
   secret **paths only** — no decryption, no passphrase needed. Paths are cached
   in memory and persisted via `pluginService.savePluginState` for instant display.
2. `getItems(query)` filters the cache synchronously (multi-word, case-insensitive).
3. At load the plugin detects whether `pinentry-dms` is wired up (the
   `pinentryDms` DMS plugin enabled **and** gopass's `[age] pinentry` pointing at
   the `pinentry-dms` binary).
4. **Copy / edit** actions need decryption:
   - **pinentry-dms mode**: they run `gopass` with no `GOPASS_AGE_PASSWORD`, so
     gopass calls `pinentry-dms`, which pops a native DMS modal via IPC. The age
     agent caches the unlock.
   - **Builtin mode**: they inject the cached passphrase into a short-lived
     `gopass` child process via `GOPASS_AGE_PASSWORD`, bypassing `pinentry`.
5. The builtin passphrase dialog and the edit dialog are native DMS
   `FloatingWindow`s spawned by the plugin (`DankTextField` with
   `echoMode: Password`).

### Security model

- The secret-path cache contains **only paths** (already stored in cleartext on
  disk by gopass) — no secret material.
- In **pinentry-dms mode** the plugin never sees the passphrase: it flows only
  between gopass and `pinentry-dms` (over a Unix socket), exactly gopass's normal
  pinentry trust model. The age agent holds the unlock.
- In **builtin mode** the passphrase lives **only in memory** (a QML property),
  for the duration of the session. It is **never written to disk** and **never
  logged**. It is passed to `gopass` exclusively through the
  `GOPASS_AGE_PASSWORD` environment variable of a transient child process; the
  exposure window is the gopass process lifetime (a few hundred milliseconds).
- Secret editing round-trips through `gopass show -f` → `gopass insert -f`, the
  canonical gopass read/write path, so the AKV format (line 1 = password, rest =
  body) is preserved.

## Development

```sh
# Clone the DMS source for IDE support
git clone https://github.com/AvengeMedia/DankMaterialShell.git ~/repos/DankMaterialShell

# Symlink the plugin into your plugins dir (so reloads pick up edits directly)
ln -sf "$PWD" ~/.config/DankMaterialShell/plugins/gopass-dms

# Reload the plugin after changes
dms ipc call plugins reload gopassDms

# Status
dms ipc call plugins list

# Live logs
journalctl --user -u dms.service -f
```

### Notes

- The launcher refreshes on async updates through
  `pluginService.requestLauncherUpdate(pluginId)` — the channel DMS actually
  listens on. A custom `itemsChanged` signal is **not** wired by DMS.
- A launcher plugin is headless (`QtObject`), but it can spawn `FloatingWindow`s
  on demand. This is how the passphrase and edit dialogs are rendered.

## License

MIT
