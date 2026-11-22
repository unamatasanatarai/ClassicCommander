# Total Commander FTP client — feature and implementation specification

## 1. Scope

The built-in FTP client lets users connect to remote servers and browse remote directories in either file panel. It should feel like a filesystem provider integrated into the normal two-panel file manager, not a separate browser.

This specification describes a practical clone target. Exact labels, menu placement, shortcuts, and availability of individual controls can vary by Total Commander version and configuration. Validate compatibility against the specific version being cloned.

## 2. Primary workflows

1. Open the FTP connection manager.
2. Select a saved profile or create a new one.
3. Connect and display the remote directory in the active panel.
4. Browse remote folders and select files.
5. Use normal file-manager commands to upload, download, rename, create directories, delete, and inspect files.
6. Monitor transfer progress and handle errors.
7. Disconnect without losing saved connection profiles.

## 3. Screen: connection manager

Reference: [`images/01-connection-manager.png`](images/01-connection-manager.png)

### Purpose

Manage saved FTP connection profiles and connect to a selected server.

### Controls

| Control | Expected behavior |
|---|---|
| Connection list | Displays saved profiles and optional folders/groups |
| Connect | Connects using the selected profile |
| New connection | Opens the profile editor with empty/default values |
| New URL | Parses a supplied FTP URL into a profile, where supported |
| Duplicate | Creates a copy of the selected profile |
| New folder | Creates a grouping folder for profiles |
| Edit | Opens the selected profile for editing |
| Delete | Deletes the selected saved profile after confirmation |
| Encrypt / protect | Protects stored credentials, where supported |
| Cancel / Close | Closes the manager without connecting |
| Help | Opens relevant help |

### Interaction

- Double-clicking a profile should connect.
- Enter should activate the selected profile where appropriate.
- Profile selection must be distinct from connecting.
- Deleting a profile must not delete remote files.
- Connection failures should leave the manager usable and show actionable diagnostics.
- Folder organization must not change the underlying connection settings.

## 4. Screen: profile editor — General

Reference: [`images/02-profile-general.png`](images/02-profile-general.png)

### Fields

| Field | Meaning | Validation / behavior |
|---|---|---|
| Session name | Friendly profile label | Required; unique within its folder is recommended |
| Host | DNS name or IP address | Required |
| Port | Server control port | Default to 21 for FTP/explicit FTPS; allow override |
| Username | Login name | Optional only for anonymous access |
| Password | Login secret | Store using OS credential storage where available |
| Anonymous login | Use anonymous authentication | Disables or ignores normal username/password |
| Remote start directory | Initial server path | Optional; navigate after login |
| Local start directory | Initial local path | Optional; navigate the opposite panel after login |
| TLS/SSL mode | Enable encrypted FTP | Make the security mode explicit; validate certificate |
| Passive mode | Use passive data connections | Default enabled for common NAT/firewall environments |

### Behavior

- Distinguish plain FTP from FTPS.
- Never silently downgrade a requested secure connection to plaintext.
- Do not log passwords or include them in error messages.
- Provide a password visibility toggle, but mask the value by default.
- Test the connection without requiring the user to save the profile.
- Preserve the selected profile when returning from an unsuccessful connection attempt.

## 5. Screen: profile editor — Advanced

Reference: [`images/03-profile-advanced.png`](images/03-profile-advanced.png)

Advanced options should be grouped and explained with tooltips.

| Setting | Behavior |
|---|---|
| Server/listing type | Automatic detection by default; allow custom parsing only when needed |
| Keep-alive | Send an appropriate harmless command during idle periods |
| Keep-alive interval | Configurable interval, bounded to safe values |
| Commands after login | Optional list of server commands; show security warning and execution result |
| Directory listing cache | Optional cache with explicit refresh/invalidation |
| Proxy/firewall | Configure supported proxy types and credentials separately |
| Transfer mode | Binary, text, or automatic; binary should be the safe default for general files |

Do not assume every setting shown in a mockup maps to a control in every Total Commander release. Treat this section as a clone product specification, not a claim of exact pixel-level parity.

## 6. Screen: connected remote panel

Reference: [`images/04-connected-ftp-panel.png`](images/04-connected-ftp-panel.png)

### Core behavior

- Render remote directories using the same file-list component as local folders.
- Support path navigation, parent-directory navigation, selection, sorting, and refresh.
- Display remote name, size, timestamp, and directory status where available.
- Show connection identity/status so users can distinguish local and remote panels.
- Keep normal keyboard and function-key behavior consistent with local files.

### File operations

| Operation | Expected behavior |
|---|---|
| View | Download to a temporary file or stream where supported, then open with viewer |
| Edit | Download temporary copy, edit, then offer/upload changes |
| Copy local → remote | Upload selected files/directories |
| Copy remote → local | Download selected files/directories |
| Move / rename | Use server rename when possible; cross-provider move becomes copy then delete after verification |
| Create directory | Create remote directory |
| Delete | Delete remote file/directory with confirmation and clear partial-failure reporting |
| Refresh | Re-fetch remote listing and invalidate stale cache |
| Permissions | Expose chmod/attributes only when supported by the server |

### Transfer semantics

- Preserve directory structure during recursive copy.
- Use binary transfer by default to avoid corrupting arbitrary files.
- Support resume only when the server and transfer mode permit it.
- Do not claim a transfer succeeded until the server confirms completion and the client closes/verifies the transfer.
- For cross-server copies, use client-mediated transfer unless a supported server-side mechanism exists.
- Show partial failures per file rather than reporting only a generic batch failure.

## 7. Transfer manager

Recommended dedicated queue for long-running operations.

Each task should expose:

- Source and destination
- Direction (upload/download)
- Current file and overall progress
- Bytes transferred and total bytes, when known
- Current speed and elapsed time
- Pause/cancel where protocol and implementation permit
- Retry for recoverable failures
- Per-file result and error detail

Cancellation must close data and control resources cleanly. A cancelled or interrupted transfer must not be marked complete.

## 8. Protocol distinctions

| Protocol | Notes |
|---|---|
| FTP | Plaintext protocol; credentials and data are not encrypted |
| Explicit FTPS | FTP upgraded to TLS, commonly on port 21 |
| Implicit FTPS | TLS from connection start; commonly associated with port 990 |
| SFTP | SSH File Transfer Protocol; not FTP and not FTPS |
| HTTP/SOCKS proxy | Proxy transport/configuration, not a file-transfer protocol |

Do not label SFTP as an FTP security mode. If SFTP is offered, implement it as a separate SSH-based provider or plugin.

## 9. Error handling and security

- Validate host, port, and path input.
- Verify TLS certificates and provide a deliberate certificate-trust workflow.
- Keep credentials in the platform credential store where available.
- Never persist credentials in plaintext.
- Redact secrets from logs, diagnostics, and exported profiles.
- Handle authentication failure, DNS failure, timeout, refused connection, TLS errors, permission denied, quota exceeded, disk full, and connection loss.
- Detect stale sessions and reconnect only when safe.
- Avoid automatic retries for non-idempotent operations unless their state is known.
- Confirm destructive operations and show the affected remote path.
- Treat server-provided filenames and listing data as untrusted input.

## 10. Suggested architecture

```text
FTPFeature
├── ConnectionManager
│   ├── ProfileRepository
│   ├── ProfileFolders
│   ├── ProfileEditor
│   └── CredentialStore
├── Providers
│   ├── FTPProvider
│   └── FTPSProvider
├── RemoteFilesystem
│   ├── DirectoryListing
│   ├── Stat
│   ├── Read
│   ├── Write
│   ├── Rename
│   ├── CreateDirectory
│   ├── Delete
│   └── SetPermissions
├── TransferManager
│   ├── Queue
│   ├── Upload
│   ├── Download
│   ├── Resume
│   ├── Retry
│   └── Progress
└── UI
    ├── ConnectionManagerDialog
    ├── ConnectionEditor
    ├── RemotePanelAdapter
    └── TransferQueueDialog
```

The UI should depend on a filesystem-provider abstraction. Local filesystems and remote FTP/FTPS providers should implement the same operations contract where possible.

## 11. Acceptance criteria

- [ ] User can create, edit, duplicate, group, and delete connection profiles.
- [ ] User can connect using a saved profile.
- [ ] Credentials are protected at rest.
- [ ] User can browse remote directories in either panel.
- [ ] User can upload and download files and directory trees.
- [ ] User can rename, create directories, delete, and refresh.
- [ ] Transfers report progress and per-file failures.
- [ ] Binary mode is the default.
- [ ] FTPS certificate validation is implemented.
- [ ] Plain FTP is clearly identified as unencrypted.
- [ ] SFTP is not misrepresented as FTP/FTPS.
- [ ] Interrupted transfers are not reported as successful.
- [ ] Destructive actions require appropriate confirmation.
- [ ] Remote filesystem operations are testable independently of the UI.

## 12. Keyboard and menu notes

The commonly used Total Commander entry point for the FTP connection dialog is `Ctrl+F` (Net → FTP Connect). Verify exact menu labels and other shortcuts against the target release before hard-coding them. Do not assume every FTP command has a default shortcut; allow users to inspect or customize command bindings if the clone supports configurable hotkeys.
