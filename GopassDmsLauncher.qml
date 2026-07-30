import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "gopassDms"
    property string trigger: "pass"

    // Cached secret paths from gopass list --flat
    property var secrets: []
    property bool loading: false
    property bool syncing: false
    property string errorMessage: ""

    // Settings (loaded from plugin data)
    property string gopassBinary: "gopass"
    property int maxResults: 50

    // In-memory passphrase cache (session only, never persisted). Injected as
    // GOPASS_AGE_PASSWORD into gopass show so pinentry is never invoked.
    property string _passphrase: ""

    // True when pinentry-dms is wired up end-to-end (the pinentryDms DMS plugin
    // is enabled AND gopass's age pinentry points at the pinentry-dms binary).
    // When set, the plugin lets gopass drive pinentry-dms instead of capturing
    // the passphrase itself and injecting GOPASS_AGE_PASSWORD. Falls back to the
    // builtin flow otherwise.
    property bool _pinentryDmsAvailable: false
    property string _pendingSecret: ""
    property string _pendingField: ""
    property string _pendingKind: ""
    property var _passphraseDialog: null
    property var _viewDialog: null
    property var _editDialog: null
    property var _confirmDialog: null
    property var _pathDialog: null
    property string _pendingDeletePath: ""
    property bool _isNewSecret: false

    Component.onCompleted: {
        console.info("GopassDms: Plugin loaded")

        if (!pluginService)
            return

        trigger = pluginService.loadPluginData(pluginId, "trigger", "pass")
        gopassBinary = pluginService.loadPluginData(pluginId, "gopassBinary", "gopass")
        maxResults = pluginService.loadPluginData(pluginId, "maxResults", 50)

        var cached = pluginService.loadPluginState(pluginId, "secrets", [])
        if (cached && cached.length > 0)
            secrets = cached

        refreshSecrets()
        _detectPinentryDms()
    }

    onTriggerChanged: {
        if (pluginService)
            pluginService.savePluginData(pluginId, "trigger", trigger)
    }

    // Ask the launcher to re-run getItems. DMS listens to requestLauncherUpdate
    // (not a custom itemsChanged signal).
    function _refreshLauncher() {
        if (pluginService)
            pluginService.requestLauncherUpdate(pluginId)
    }

    // Detects whether pinentry-dms is wired up end-to-end so the plugin can let
    // gopass drive it instead of injecting GOPASS_AGE_PASSWORD. Requires BOTH:
    //   C1 — the pinentryDms DMS plugin is enabled (plugin_settings.json)
    //   C2 — a pinentry directive points at pinentry-dms: either gopass's
    //        [age] pinentry (~/.config/gopass/config) or gpg-agent's
    //        pinentry-program (~/.gnupg/gpg-agent.conf). The gopass age agent
    //        reads the latter even without a running gpg-agent.
    // Reading only C1 would risk a broken state (no env var but gopass not
    // actually configured for pinentry-dms).
    function _detectPinentryDms() {
        var proc = detectProcessComponent.createObject(root)
        proc.running = true
    }

    function _finishDetection(raw) {
        var psText = ""
        var gcText = ""
        var psIdx = raw.indexOf("<PS>")
        var gcIdx = raw.indexOf("<GC>")
        if (psIdx !== -1 && gcIdx !== -1) {
            psText = raw.substring(psIdx + 4, gcIdx)
            gcText = raw.substring(gcIdx + 4)
        }

        var c1 = false
        try {
            var obj = JSON.parse(psText)
            if (obj && obj.pinentryDms && obj.pinentryDms.enabled === true)
                c1 = true
        } catch (e) {
            c1 = false
        }

        var c2 = /pinentry(?:-program)?\s+=?\s*\S*pinentry-dms/i.test(gcText)

        _pinentryDmsAvailable = (c1 && c2)
        console.info("GopassDms: pinentry-dms detection plugin=" + c1
                     + " gopass=" + c2 + " => " + _pinentryDmsAvailable)
    }

    property Component detectProcessComponent: Component {
        Process {
            command: ["sh", "-c",
                "echo '<PS>'; " +
                "cat \"$HOME/.config/DankMaterialShell/plugin_settings.json\" 2>/dev/null || true; " +
                "echo '<GC>'; " +
                "cat \"${GOPASS_CONFIG:-$HOME/.config/gopass/config}\" 2>/dev/null || true; " +
                "cat \"$HOME/.gnupg/gpg-agent.conf\" 2>/dev/null || true"
            ]
            stdout: StdioCollector {
                id: collector
            }
            onExited: (exitCode) => {
                root._finishDetection(collector.text)
                destroy()
            }
        }
    }

    function refreshSecrets() {
        if (loading)
            return
        if (!gopassBinary || gopassBinary.length === 0) {
            errorMessage = "Gopass binary path is not configured"
            root._refreshLauncher()
            return
        }

        loading = true
        syncing = false
        errorMessage = ""
        var proc = listProcessComponent.createObject(root)
        proc.running = true
    }

    // Sync git (gopass sync) then refresh the local secret list. Invoked from
    // the Tab context menu ("Sync vault") and the error retry action.
    function syncAndRefresh() {
        if (loading)
            return
        if (!gopassBinary || gopassBinary.length === 0) {
            errorMessage = "Gopass binary path is not configured"
            root._refreshLauncher()
            return
        }

        loading = true
        syncing = true
        errorMessage = ""
        var proc = syncProcessComponent.createObject(root)
        proc.running = true
    }

    property Component syncProcessComponent: Component {
        Process {
            command: [root.gopassBinary, "sync"]
            property var syncMessages: []

            stdout: SplitParser {
                onRead: line => {
                    if (line && line.trim().length > 0)
                        syncMessages.push(line.trim())
                }
            }

            stderr: SplitParser {
                onRead: line => {
                    if (line && line.trim().length > 0)
                        syncMessages.push(line.trim())
                }
            }

            onExited: (exitCode) => {
                if (exitCode !== 0)
                    root._showToast("Sync failed, using local cache")
                else if (syncMessages.length > 0)
                    root._showToast("Vault synced")

                root.syncing = false
                root._requestList()
                destroy()
            }
        }
    }

    // Launches gopass list --flat to (re)build the local cache.
    function _requestList() {
        var proc = listProcessComponent.createObject(root)
        proc.running = true
    }

    property Component listProcessComponent: Component {
        Process {
            command: [root.gopassBinary, "list", "--flat"]
            property var lines: []

            stdout: SplitParser {
                onRead: line => {
                    if (line && line.trim().length > 0)
                        lines.push(line.trim())
                }
            }

            stderr: SplitParser {
                onRead: line => {
                    if (line && line.trim().length > 0)
                        root.errorMessage = line.trim()
                }
            }

            onExited: (exitCode) => {
                if (exitCode === 0) {
                    root.secrets = lines.slice()
                    if (root.pluginService)
                        root.pluginService.savePluginState(root.pluginId, "secrets", root.secrets)
                } else {
                    if (root.secrets.length === 0)
                        root.errorMessage = root.errorMessage || ("gopass exited with code " + exitCode)
                }
                root.loading = false
                root._refreshLauncher()
                destroy()
            }
        }
    }

    function getItems(query) {
        var items = []
        var isEmpty = !query || query.trim().length === 0

        // Trigger an initial load if the cache is empty
        if (secrets.length === 0 && !loading && errorMessage === "")
            refreshSecrets()

        if (loading && secrets.length === 0) {
            items.push({
                name: syncing ? "Syncing gopass vault..." : "Loading gopass vault...",
                icon: "material:hourglass_empty",
                comment: syncing ? "Running gopass sync, then fetching secrets"
                                 : "Fetching secret list from gopass",
                action: "noop:",
                categories: ["Gopass"]
            })
            return items
        }

        if (errorMessage !== "" && secrets.length === 0) {
            items.push({
                name: "Gopass error",
                icon: "material:error",
                comment: errorMessage,
                action: "retry:",
                categories: ["Gopass"]
            })
            items.push({
                name: "Retry",
                icon: "material:refresh",
                comment: "Attempt to load secrets again",
                action: "retry:",
                categories: ["Gopass"]
            })
            return items
        }

        if (isEmpty) {
            var shown = Math.min(maxResults, secrets.length)
            for (var i = 0; i < shown; i++)
                items.push(_makeSecretItem(secrets[i]))

            if (secrets.length > maxResults) {
                items.push({
                    name: (secrets.length - maxResults) + " more secrets...",
                    icon: "material:more_horiz",
                    comment: "Refine your search to see more",
                    action: "noop:",
                    categories: ["Gopass"]
                })
            }

            return items
        }

        var terms = query.trim().toLowerCase().split(/\s+/)
        for (var j = 0; j < secrets.length; j++) {
            var secret = secrets[j]
            var lower = secret.toLowerCase()
            var match = true
            for (var t = 0; t < terms.length; t++) {
                if (lower.indexOf(terms[t]) === -1) {
                    match = false
                    break
                }
            }
            if (match) {
                items.push(_makeSecretItem(secret))
                if (items.length >= maxResults)
                    break
            }
        }

        if (items.length === 0) {
            items.push({
                name: "No secrets found",
                icon: "material:search_off",
                comment: "No matches for \u2018" + query.trim() + "\u2019",
                action: "noop:",
                categories: ["Gopass"]
            })
        }

        return items
    }

    function _makeSecretItem(secret) {
        var parts = secret.split("/")
        var name = parts[parts.length - 1]
        var comment = parts.length > 1 ? parts.slice(0, -1).join(" / ") : "gopass secret"
        return {
            name: name,
            icon: "material:key",
            comment: comment,
            action: "copy:" + secret,
            categories: ["Gopass"]
        }
    }

    function executeItem(item) {
        if (!item || !item.action)
            return

        var colonIdx = item.action.indexOf(":")
        var actionType = item.action.substring(0, colonIdx)
        var actionData = item.action.substring(colonIdx + 1)

        switch (actionType) {
        case "copy":
            _copySecret(actionData)
            break
        case "retry":
            syncAndRefresh()
            break
        case "noop":
            break
        default:
            _showToast("Unknown action: " + actionType)
        }
    }

    // Context menu actions (opened with Tab on a selected item).
    function getContextMenuActions(item) {
        if (!item || !item.action)
            return []

        var actions = []

        if (item.action.indexOf("copy:") === 0) {
            var colonIdx = item.action.indexOf(":")
            var secretPath = item.action.substring(colonIdx + 1)
            actions.push({
                icon: "vpn_key",
                text: "Copy password",
                action: function() { root._copySecret(secretPath) }
            })
            actions.push({
                icon: "person",
                text: "Copy username",
                action: function() { root._copyField(secretPath, "username") }
            })
            actions.push({
                icon: "timer",
                text: "Copy TOTP",
                action: function() { root._copyTotp(secretPath) }
            })
            actions.push({
                icon: "visibility",
                text: "View secret",
                action: function() { root._viewSecret(secretPath) }
            })
            actions.push({
                icon: "edit",
                text: "Edit secret",
                action: function() { root._editSecret(secretPath) }
            })
            actions.push({
                icon: "delete",
                text: "Delete secret",
                action: function() { root._deleteSecret(secretPath) }
            })
        }

        actions.push({
            icon: "add",
            text: "Add new secret",
            action: function() { root._addSecret() }
        })

        actions.push({
            icon: "sync",
            text: "Sync vault",
            action: function() { root.syncAndRefresh() }
        })

        return actions
    }

    // --- Passphrase-aware decryption (bypasses pinentry via GOPASS_AGE_PASSWORD) ---

    function _copySecret(secretPath) {
        _requestSecret(secretPath, "", "password")
    }

    function _copyField(secretPath, field) {
        _requestSecret(secretPath, field, "field")
    }

    function _copyTotp(secretPath) {
        _requestSecret(secretPath, "", "totp")
    }

    function _requestSecret(secretPath, field, kind) {
        _pendingSecret = secretPath
        _pendingField = field
        _pendingKind = kind
        // pinentry-dms mode: gopass handles unlocking; no dialog, no cache.
        if (_pinentryDmsAvailable)
            _runCopy()
        else if (_passphrase !== "")
            _runCopy()
        else
            _openPassphraseDialog()
    }

    function _runCopy() {
        var args
        if (_pendingKind === "totp")
            args = [gopassBinary, "totp", "-c", _pendingSecret]
        else {
            args = [gopassBinary, "show", "-c", _pendingSecret]
            if (_pendingField !== "")
                args.push(_pendingField)
        }
        var proc = copyProcessComponent.createObject(root, {
            command: args,
            secretPath: _pendingSecret,
            fieldName: _pendingField,
            kind: _pendingKind
        })
        proc.running = true
    }

    function _onCopySuccess(secretPath, fieldName, kind) {
        if (_passphraseDialog && _passphraseDialog.visible)
            _passphraseDialog.hide()
        if (kind === "totp")
            _showToast("Copied TOTP code for: " + secretPath)
        else if (fieldName === "")
            _showToast("Copied password for: " + secretPath)
        else
            _showToast("Copied " + fieldName + " for: " + secretPath)
    }

    function _onCopyFailure(secretPath, fieldName, kind, exitCode, stderrText) {
        var isDecrypt = exitCode === 11 || (stderrText && stderrText.toLowerCase().indexOf("ecrypt") !== -1)

        // pinentry-dms mode: no passphrase cache/dialog on our side. gopass +
        // pinentry-dms handle unlocking and retry; we only surface the result.
        if (root._pinentryDmsAvailable) {
            if (root._passphraseDialog && root._passphraseDialog.visible)
                root._passphraseDialog.hide()
            if (isDecrypt)
                root._showToast("Copy failed: decryption cancelled or failed")
            else if (kind === "totp")
                root._showToast("No TOTP configured in " + secretPath)
            else if (fieldName !== "")
                root._showToast("No " + fieldName + " in " + secretPath)
            else
                root._showToast("Copy failed (exit " + exitCode + ")")
            return
        }

        if (isDecrypt) {
            _passphrase = ""
            if (_passphraseDialog && _passphraseDialog.visible)
                _passphraseDialog.setError("Wrong passphrase, try again")
            else
                _showToast("Copy failed: wrong passphrase")
        } else if (kind === "totp") {
            if (_passphraseDialog && _passphraseDialog.visible)
                _passphraseDialog.hide()
            _showToast("No TOTP configured in " + secretPath)
        } else if (fieldName !== "") {
            if (_passphraseDialog && _passphraseDialog.visible)
                _passphraseDialog.hide()
            _showToast("No " + fieldName + " in " + secretPath)
        } else {
            if (_passphraseDialog && _passphraseDialog.visible)
                _passphraseDialog.hide()
            _showToast("Copy failed (exit " + exitCode + ")")
        }
    }

    property Component copyProcessComponent: Component {
        Process {
            property string secretPath: ""
            property string fieldName: ""
            property string kind: ""
            property string stderrText: ""
            // In pinentry-dms mode, do NOT inject GOPASS_AGE_PASSWORD: it
            // bypasses pinentry, and we want gopass to call pinentry-dms.
            environment: root._pinentryDmsAvailable
                ? ({})
                : ({ "GOPASS_AGE_PASSWORD": root._passphrase })
            stderr: SplitParser {
                onRead: line => {
                    if (line)
                        stderrText += line + "\n"
                }
            }
            onExited: (exitCode) => {
                if (exitCode === 0)
                    root._onCopySuccess(secretPath, fieldName, kind)
                else
                    root._onCopyFailure(secretPath, fieldName, kind, exitCode, stderrText)
                destroy()
            }
        }
    }

    // --- Secret editing (load via show -f, save via insert -f) ---

    function _viewSecret(secretPath) {
        _pendingSecret = secretPath
        _pendingKind = "view"
        _isNewSecret = false
        if (_pinentryDmsAvailable || _passphrase !== "")
            _loadForEdit()
        else
            _openPassphraseDialog()
    }

    function _editSecret(secretPath) {
        _pendingSecret = secretPath
        _pendingKind = "edit"
        _isNewSecret = false
        if (_pinentryDmsAvailable || _passphrase !== "")
            _loadForEdit()
        else
            _openPassphraseDialog()
    }

    function _loadForEdit() {
        var proc = loadEditProcessComponent.createObject(root, {
            secretPath: _pendingSecret
        })
        proc.running = true
    }

    function _openEditDialog(secretPath, content) {
        if (_passphraseDialog && _passphraseDialog.visible)
            _passphraseDialog.hide()
        if (!_editDialog) {
            _editDialog = editDialogComponent.createObject(root)
            _editDialog.saved.connect(function(newContent) {
                _editDialog.saving = true
                root._saveSecret(_editDialog.secretPath, root._normalizeText(newContent))
            })
        }
        _editDialog.secretPath = secretPath
        _editDialog.originalContent = content
        _editDialog.show()
    }

    function _openViewDialog(secretPath, content) {
        if (_passphraseDialog && _passphraseDialog.visible)
            _passphraseDialog.hide()
        if (!_viewDialog)
            _viewDialog = viewDialogComponent.createObject(root)
        _viewDialog.secretPath = secretPath
        _viewDialog.originalContent = content
        _viewDialog.show()
    }

    function _saveSecret(secretPath, content) {
        var proc = saveEditProcessComponent.createObject(root, {
            secretPath: secretPath,
            editContent: content,
            refreshAfter: root._isNewSecret
        })
        _isNewSecret = false
        proc.running = true
    }

    // --- Secret deletion (gopass rm -f; no passphrase: rm doesn't decrypt) ---

    function _deleteSecret(secretPath) {
        if (!_confirmDialog) {
            _confirmDialog = confirmDialogComponent.createObject(root)
            _confirmDialog.confirmed.connect(function() {
                _confirmDialog.hide()
                if (root._pendingDeletePath !== "") {
                    var proc = deleteProcessComponent.createObject(root, {
                        secretPath: root._pendingDeletePath
                    })
                    proc.running = true
                    root._pendingDeletePath = ""
                }
            })
            _confirmDialog.cancelled.connect(function() {
                root._pendingDeletePath = ""
            })
        }
        _pendingDeletePath = secretPath
        _confirmDialog.messageText = "Delete \"" + secretPath + "\"?\nThis cannot be undone."
        _confirmDialog.confirmText = "Delete"
        _confirmDialog.danger = true
        _confirmDialog.show()
    }

    // --- Secret creation (path popup -> passphrase if needed -> editor empty) ---

    function _addSecret() {
        if (!_pathDialog) {
            _pathDialog = pathDialogComponent.createObject(root)
            _pathDialog.submitted.connect(function(path) {
                root._pendingSecret = path
                root._pendingField = ""
                root._pendingKind = "add"
                root._pathDialog.hide()
                if (root._pinentryDmsAvailable || root._passphrase !== "") {
                    root._isNewSecret = true
                    root._openEditDialog(root._pendingSecret, "")
                } else {
                    root._openPassphraseDialog()
                }
            })
        }
        _pathDialog.show()
    }

    property Component loadEditProcessComponent: Component {
        Process {
            property string secretPath: ""
            property var lines: []
            command: [root.gopassBinary, "show", "-f", secretPath]
            environment: root._pinentryDmsAvailable
                ? ({})
                : ({ "GOPASS_AGE_PASSWORD": root._passphrase })
            stdout: SplitParser {
                onRead: line => { lines.push(line) }
            }
            onExited: (exitCode) => {
                if (exitCode === 0) {
                    if (root._pendingKind === "view")
                        root._openViewDialog(secretPath, lines.join("\n"))
                    else
                        root._openEditDialog(secretPath, lines.join("\n"))
                } else if (root._pinentryDmsAvailable) {
                    if (root._passphraseDialog && root._passphraseDialog.visible)
                        root._passphraseDialog.hide()
                    root._showToast(root._pendingKind === "view"
                        ? "Failed to load secret for view"
                        : "Failed to load secret for edit")
                } else {
                    root._passphrase = ""
                    if (root._passphraseDialog && root._passphraseDialog.visible)
                        root._passphraseDialog.setError("Wrong passphrase, try again")
                    else
                        root._showToast(root._pendingKind === "view"
                            ? "Failed to load secret for view"
                            : "Failed to load secret for edit")
                }
                destroy()
            }
        }
    }

    property Component saveEditProcessComponent: Component {
        Process {
            property string secretPath: ""
            property string editContent: ""
            property bool refreshAfter: false
            command: ["sh", "-c", "printf '%s' \"$EC\" | \"$GP\" insert -f \"$SP\""]
            environment: root._pinentryDmsAvailable
                ? ({ "EC": editContent, "SP": secretPath, "GP": root.gopassBinary })
                : ({ "EC": editContent, "SP": secretPath, "GP": root.gopassBinary,
                     "GOPASS_AGE_PASSWORD": root._passphrase })
            onExited: (exitCode) => {
                if (exitCode === 0) {
                    if (root._editDialog) {
                        root._editDialog.saving = false
                        if (root._editDialog.visible)
                            root._editDialog.hide()
                    }
                    root._showToast("Saved secret: " + secretPath)
                    if (refreshAfter)
                        root.refreshSecrets()
                } else {
                    if (root._editDialog)
                        root._editDialog.saving = false
                    root._showToast("Failed to save (exit " + exitCode + ")")
                }
                destroy()
            }
        }
    }

    // gopass rm -f deletes the secret (no decryption, no passphrase). Git push
    // to the remote is handled by gopass's core.autopush.
    property Component deleteProcessComponent: Component {
        Process {
            property string secretPath: ""
            command: [root.gopassBinary, "rm", "-f", secretPath]
            onExited: (exitCode) => {
                if (exitCode === 0) {
                    root._showToast("Deleted secret: " + secretPath)
                    root.refreshSecrets()
                } else {
                    root._showToast("Failed to delete (exit " + exitCode + ")")
                }
                destroy()
            }
        }
    }

    function _showToast(message) {
        if (typeof ToastService !== "undefined")
            ToastService.showInfo("GoPass DMS", message)
        else
            console.log("GopassDms:", message)
    }

    function _colorizeDigits(plain) {
        var s = String(plain)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/\r\n|\r|\n|\u2028|\u2029/g, "<br>")
        return s.replace(/\d+/g, '<span style="color: #b48ead;">$&</span>')
    }

    // QtQuick's TextEdit represents line breaks as U+2029 (paragraph separator)
    // in rich-text mode; getText() can hand those back raw. Normalize every
    // flavor of line break to "\n" before writing the secret so the vault
    // never ends up with collapsed or stray separator characters.
    function _normalizeText(s) {
        return String(s).replace(/\r\n|\r|\u2028|\u2029/g, "\n")
    }

    // --- Passphrase dialog (native DMS-styled FloatingWindow) ---

    function _openPassphraseDialog() {
        if (!_passphraseDialog) {
            _passphraseDialog = passphraseDialogComponent.createObject(root)
            _passphraseDialog.submitted.connect(function(value) {
                root._passphrase = value
                if (root._pendingKind === "edit") {
                    root._isNewSecret = false
                    root._loadForEdit()
                } else if (root._pendingKind === "view") {
                    root._loadForEdit()
                } else if (root._pendingKind === "add") {
                    root._isNewSecret = true
                    root._openEditDialog(root._pendingSecret, "")
                } else {
                    root._runCopy()
                }
            })
            _passphraseDialog.cancelled.connect(function() {
                root._pendingSecret = ""
                root._pendingField = ""
            })
        }
        var label
        if (_pendingKind === "totp")
            label = "Generating TOTP: " + _pendingSecret
        else if (_pendingKind === "view")
            label = "Loading for view: " + _pendingSecret
        else if (_pendingKind === "edit")
            label = "Loading for edit: " + _pendingSecret
        else if (_pendingKind === "add")
            label = "Creating new secret: " + _pendingSecret
        else
            label = "Decrypting: " + _pendingSecret
        if (_pendingField !== "")
            label += " (" + _pendingField + ")"
        _passphraseDialog.promptText = label
        _passphraseDialog.show()
    }

    property Component passphraseDialogComponent: Component {
        FloatingWindow {
            id: dlg
            visible: false
            implicitWidth: 620
            implicitHeight: 160
            title: "Gopass Passphrase"
            color: Theme.surfaceContainer

            property string promptText: ""
            property string errorText: ""

            signal submitted(string value)
            signal cancelled()

            function show() {
                errorText = ""
                field.clear()
                visible = true
                Qt.callLater(function() { field.forceActiveFocus() })
            }

            function hide() { visible = false }

            function setError(msg) {
                errorText = msg
                field.clear()
                Qt.callLater(function() { field.forceActiveFocus() })
            }

            onClosed: dlg.visible = false

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS
                    DankIcon {
                        name: "lock"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        text: "Enter gopass passphrase"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    width: parent.width
                    text: dlg.promptText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    visible: dlg.promptText !== ""
                }

                DankTextField {
                    id: field
                    width: parent.width
                    echoMode: field.passwordVisible ? TextInput.Normal : TextInput.Password
                    showPasswordToggle: true
                    placeholderText: "Passphrase"
                    leftIconName: "vpn_key"
                    onAccepted: {
                        if (field.text.length > 0) {
                            dlg.submitted(field.text)
                            field.clear()
                        }
                    }
                    Keys.onEscapePressed: {
                        dlg.cancelled()
                        dlg.hide()
                    }
                }

                StyledText {
                    width: parent.width
                    text: dlg.errorText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                    visible: dlg.errorText !== ""
                }

                StyledText {
                    width: parent.width
                    text: "Enter to submit · Esc to cancel"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }
            }
        }
    }

    // --- View dialog (read-only FloatingWindow, colorized digits) ---

    property Component viewDialogComponent: Component {
        FloatingWindow {
            id: viewDlg
            visible: false
            implicitWidth: 620
            implicitHeight: 310
            title: "Gopass View Secret"
            color: Theme.surfaceContainer

            property string secretPath: ""
            property string originalContent: ""

            function show() {
                viewArea.text = root._colorizeDigits(viewDlg.originalContent)
                visible = true
            }
            function hide() { visible = false }

            onClosed: viewDlg.visible = false

            Row {
                id: viewHeader
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                DankIcon {
                    name: "visibility"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: viewDlg.secretPath
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Flickable {
                id: viewFlick
                anchors.top: viewHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: viewCloseRow.top
                anchors.margins: Theme.spacingL
                clip: true
                flickableDirection: Flickable.VerticalFlick
                contentHeight: Math.max(viewArea.implicitHeight, viewFlick.height)

                TextEdit {
                    id: viewArea
                    width: viewFlick.width
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.RichText
                    readOnly: true
                    activeFocusOnTab: true
                    text: ""
                    font.family: "monospace"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    selectionColor: Theme.withAlpha(Theme.primary, 0.4)
                    selectedTextColor: Theme.surfaceText
                    Keys.onEscapePressed: viewDlg.hide()
                    Keys.onPressed: event => {
                        if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_A)) {
                            viewArea.selectAll()
                            event.accepted = true
                        }
                    }
                }
            }

            Row {
                id: viewCloseRow
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                Rectangle {
                    width: 110
                    height: 38
                    radius: Theme.cornerRadius
                    color: viewCloseArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                    border.color: Theme.primary
                    border.width: 1
                    StyledText {
                        anchors.centerIn: parent
                        text: "Close"
                        color: Theme.primary
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                    }
                    MouseArea {
                        id: viewCloseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: viewDlg.hide()
                    }
                }
            }
        }
    }

    // --- Edit dialog (FloatingWindow with a multiline editor) ---

    property Component editDialogComponent: Component {
        FloatingWindow {
            id: editDlg
            visible: false
            implicitWidth: 620
            implicitHeight: 310
            title: "Gopass Edit Secret"
            color: Theme.surfaceContainer

            property string secretPath: ""
            property string originalContent: ""
            property bool saving: false

            signal saved(string content)
            signal cancelled()

            function show() {
                editor._updating = true
                editor.text = root._colorizeDigits(editDlg.originalContent)
                editor._updating = false
                saving = false
                visible = true
                Qt.callLater(function() { editor.forceActiveFocus() })
            }

            function hide() { visible = false }

            onClosed: editDlg.visible = false

            Row {
                id: header
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                DankIcon {
                    name: "edit"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: editDlg.secretPath
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Flickable {
                id: flick
                anchors.top: header.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: buttonsRow.top
                anchors.margins: Theme.spacingL
                clip: true
                flickableDirection: Flickable.VerticalFlick
                contentHeight: Math.max(editor.implicitHeight, flick.height)

                TextEdit {
                    id: editor
                    width: flick.width
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.RichText
                    text: ""
                    font.family: "monospace"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    selectionColor: Theme.withAlpha(Theme.primary, 0.4)
                    selectedTextColor: Theme.surfaceText
                    focus: true
                    enabled: !editDlg.saving
                    property bool _updating: false
                    onTextChanged: {
                        if (_updating)
                            return
                        _updating = true
                        var plain = getText(0, length)
                        var html = root._colorizeDigits(plain)
                        var cur = cursorPosition
                        text = html
                        cursorPosition = Math.min(cur, length)
                        _updating = false
                    }
                    Keys.onPressed: event => {
                        if (!editDlg.saving && (event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                            editDlg.saved(editor.getText(0, editor.length))
                            event.accepted = true
                        }
                    }
                    Keys.onEscapePressed: {
                        editDlg.cancelled()
                        editDlg.hide()
                    }
                }
            }

            Row {
                id: buttonsRow
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                Rectangle {
                    width: 96
                    height: 38
                    radius: Theme.cornerRadius
                    color: cancelArea.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                    border.color: Theme.outlineMedium
                    border.width: 1
                    StyledText {
                        anchors.centerIn: parent
                        text: "Cancel"
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeMedium
                    }
                    MouseArea {
                        id: cancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !editDlg.saving
                        onClicked: {
                            editDlg.cancelled()
                            editDlg.hide()
                        }
                    }
                }

                Rectangle {
                    width: 110
                    height: 38
                    radius: Theme.cornerRadius
                    opacity: editDlg.saving ? 0.6 : 1.0
                    color: saveArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.2) : Theme.withAlpha(Theme.primary, 0.12)
                    border.color: Theme.primary
                    border.width: 1
                    StyledText {
                        anchors.centerIn: parent
                        text: editDlg.saving ? "Saving..." : "Save"
                        color: Theme.primary
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                    }
                    MouseArea {
                        id: saveArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !editDlg.saving
                        onClicked: editDlg.saved(editor.getText(0, editor.length))
                    }
                }
            }
        }
    }

    // --- Generic confirmation dialog (FloatingWindow with Cancel/Confirm) ---

    property Component confirmDialogComponent: Component {
        FloatingWindow {
            id: confirmDlg
            visible: false
            implicitWidth: 620
            implicitHeight: 160
            title: "Gopass Confirm"
            color: Theme.surfaceContainer

            property string messageText: ""
            property string confirmText: "Confirm"
            property bool danger: false

            signal confirmed()
            signal cancelled()

            function show() { visible = true }
            function hide() { visible = false }

            onClosed: {
                confirmDlg.visible = false
                confirmDlg.cancelled()
            }

            Row {
                id: msgRow
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                DankIcon {
                    name: "warning"
                    size: Theme.iconSize
                    color: confirmDlg.danger ? Theme.error : Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    width: msgRow.width - Theme.iconSize - Theme.spacingS
                    text: confirmDlg.messageText
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                id: confirmBtnRow
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingS

                Rectangle {
                    width: 96
                    height: 38
                    radius: Theme.cornerRadius
                    color: confirmCancelArea.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                    border.color: Theme.outlineMedium
                    border.width: 1
                    StyledText {
                        anchors.centerIn: parent
                        text: "Cancel"
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeMedium
                    }
                    MouseArea {
                        id: confirmCancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            confirmDlg.cancelled()
                            confirmDlg.hide()
                        }
                    }
                }

                Rectangle {
                    width: 96
                    height: 38
                    radius: Theme.cornerRadius
                    color: confirmActionArea.containsMouse
                        ? (confirmDlg.danger ? Theme.withAlpha(Theme.error, 0.3) : Theme.withAlpha(Theme.primary, 0.2))
                        : (confirmDlg.danger ? Theme.withAlpha(Theme.error, 0.15) : Theme.withAlpha(Theme.primary, 0.12))
                    border.color: confirmDlg.danger ? Theme.error : Theme.primary
                    border.width: 1
                    StyledText {
                        anchors.centerIn: parent
                        text: confirmDlg.confirmText
                        color: confirmDlg.danger ? Theme.error : Theme.primary
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeMedium
                    }
                    MouseArea {
                        id: confirmActionArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: confirmDlg.confirmed()
                    }
                }
            }
        }
    }

    // --- New-secret path dialog ---

    property Component pathDialogComponent: Component {
        FloatingWindow {
            id: pathDlg
            visible: false
            implicitWidth: 620
            implicitHeight: 160
            title: "Gopass New Secret"
            color: Theme.surfaceContainer

            signal submitted(string path)
            signal cancelled()

            function show() {
                pathField.clear()
                visible = true
                Qt.callLater(function() { pathField.forceActiveFocus() })
            }
            function hide() { visible = false }

            onClosed: {
                pathDlg.visible = false
                pathDlg.cancelled()
            }

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Row {
                    spacing: Theme.spacingS
                    DankIcon {
                        name: "add"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        text: "New secret path"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Enter the path for the new secret (e.g. websites/github.com/username)."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                DankTextField {
                    id: pathField
                    width: parent.width
                    placeholderText: "websites/github.com/username"
                    leftIconName: "folder"
                    onAccepted: {
                        if (pathField.text.trim().length > 0) {
                            pathDlg.submitted(pathField.text.trim())
                            pathField.clear()
                        }
                    }
                    Keys.onEscapePressed: {
                        pathDlg.cancelled()
                        pathDlg.hide()
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Enter to create · Esc to cancel"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }
            }
        }
    }
}
