# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [2.1.0] - 2026-07-02

### Added

- **Auto-detected pinentry-dms support**. At load the plugin checks whether
  [`pinentry-dms`](https://github.com/tdesaules/pinentry-dms) is wired up
  end-to-end (the `pinentryDms` DMS plugin enabled **and** a pinentry directive
  pointing at the `pinentry-dms` binary — either gopass's `[age] pinentry` in
  `~/.config/gopass/config` or gpg-agent's `pinentry-program` in
  `~/.gnupg/gpg-agent.conf`). When both are true it
  switches to pinentry-dms mode: it stops injecting `GOPASS_AGE_PASSWORD`, lets
  gopass drive `pinentry-dms` (native DMS modal), and relies on the age agent to
  cache the unlock across restarts. When either condition is missing it falls
  back to the existing builtin passphrase dialog, so behavior is unchanged for
  users without pinentry-dms. Detection is logged as
  `GopassDms: pinentry-dms detection plugin=… gopass=… => …`.

### Notes

- pinentry-dms requires gopass's age backend (the same backend this plugin
  already targets). The GPG backend remains unsupported.

## [2.0.0] - 2026-07-01

### Changed

- **Renamed plugin**: id `gopassDank` → `gopassDms`, display name
  `Gopass-Dank` → `GoPass DMS`, repository and install folder
  `gopass-dank` → `gopass-dms`. QML entry points renamed
  `GopassLauncher.qml` → `GopassDmsLauncher.qml` and
  `GopassSettings.qml` → `GopassDmsSettings.qml` (paths updated in
  `plugin.json`).
- Log prefix and toast title updated to `GopassDms:` / `GoPass DMS`.

### Notes

- The persisted secret-path cache is keyed by plugin id; changing the id
  resets it on first reload. It is regenerated automatically by the next
  `gopass list`, so no user action is required.

## [1.1.0] - 2026-06-30

### Added

- **Delete secret** action in the launcher context menu (Tab) — a native
  confirmation popup guards the deletion, then runs `gopass rm -f`. No passphrase
  is needed (`rm` doesn't decrypt). The local secret cache is refreshed so the
  entry disappears from the list. Git push to the remote is handled by gopass's
  `core.autopush`.
- **Add new secret** action (always available in the Tab menu) — a path-entry
  popup collects the new secret's path, then the existing passphrase + editor
  flow is reused to author the content. Saved through the canonical
  `gopass insert -f`, followed by a local cache refresh (push via
  `core.autopush`).
- Reusable native confirmation and path-entry dialogs (`FloatingWindow`).

### Fixed

- Edit dialog retained the previous secret's content when reused (adding a new
  secret or editing a different one). The editor content is now reset explicitly
  on each open.
- The passphrase reveal toggle (eye icon) had no effect — `echoMode` is now
  bound to the field's `passwordVisible` (the pattern expected by
  `DankTextField`).
- The edit dialog now shows a "Saving..." state with its buttons disabled while
  `gopass insert` (and the auto-push to the git remote) runs, so the ~3 s write
  is no longer silent.

## [1.0.0] - 2026-06-28

First stable release.

### Added

- **Native passphrase dialog** that fully bypasses `pinentry`. The passphrase is
  captured in a DMS-styled `FloatingWindow`, injected to `gopass` through the
  `GOPASS_AGE_PASSWORD` environment variable, and cached **in memory for the
  session** so it is only entered once.
- **Copy password / Copy username / Copy TOTP** actions in the launcher context
  menu (Tab).
- **Edit secret** action — a native editor window loads the full secret content
  and saves it back through the canonical `gopass show -f` → `gopass insert -f`
  round-trip.
- **Sync vault** action — runs `gopass sync` (git pull/push) then rebuilds the
  local path cache.
- Multi-word, case-insensitive search over the whole vault.
- Local cache of secret paths, persisted across plugin reloads for instant
  display.
- Settings: configurable trigger, gopass binary path, and max results.

### Changed

- The launcher is refreshed through `pluginService.requestLauncherUpdate()`,
  the channel DMS actually listens on (replacing the unwired custom signal).
- Cleaner launcher entries: name is the last path segment, comment is the
  parent path.
- Documentation and architecture notes rewritten for the stable release.

### Removed

- Dead `itemsChanged` signal (never listened to by DMS).
- Verbose `EDIT` debug logging.

## [0.x] - Initial development

Iterative development builds prior to the first stable release.

### Added

- Launcher search over a gopass vault via the `pass` trigger.
- Background secret listing (`gopass list --flat`) and manual vault refresh.
- Clipboard copy of a secret's password (`gopass show -c`).
- Basic settings panel.

### Changed

- Multiple refactors of the plugin lifecycle and the async refresh mechanism
  (auto-refresh, manual refresh, request-launcher-update wiring).

[2.1.0]: https://github.com/tdesaules/gopass-dms/releases/tag/v2.1.0
[2.0.0]: https://github.com/tdesaules/gopass-dms/releases/tag/v2.0.0
[1.1.0]: https://github.com/tdesaules/gopass-dms/releases/tag/v1.1.0
[1.0.0]: https://github.com/tdesaules/gopass-dms/releases/tag/v1.0.0
