# Does the "Encrypt..." Button Do Anything Ever?

**Short answer:** No, it did not perform any active encryption or configuration. It only displayed an informational dialog explaining that passwords are automatically encrypted and protected by the macOS Keychain.

**Status:** The "Encrypt..." button has been removed from the Connection Manager as requested.

---

## Technical Details

Previously in [`Sources/App/Presentation/FTPConnectionManager.swift`](Sources/App/Presentation/FTPConnectionManager.swift), the button was included in the sidebar buttons list and hooked to `encryptInfo()`:

```swift
@objc private func encryptInfo() {
    let alert = NSAlert()
    alert.messageText = "Password protection"
    alert.informativeText = """
        Saved FTP passwords are kept in the macOS Keychain (item “ClassicCommander FTP”), encrypted and \
        protected by your login. They are never written to settings files or exports. \
        Untick “Save password in Keychain” in a profile to be asked each time instead.
        """
    Modal.run(alert)
}
```

The button and method have now been removed.

---

## Background & Context

- **In Original Total Commander (Windows):**  
  The "Encrypt..." button opens a dialog to set or change an **AES Master Password** used to encrypt passwords stored in `wcx_ftp.ini`, since Windows lacks a unified, per-user credential store for simple configuration files.

- **In ClassicCommander (macOS):**  
  The application does not store passwords in plaintext configuration files or settings files. Instead, all saved credentials are automatically stored in the **macOS Keychain** (`item "ClassicCommander FTP"` via `KeychainCredentialStore`), which is already encrypted and hardware/login protected by macOS.

- **Removal:**  
  Because the button was redundant and only showed an informational pop-up, it has been removed from the UI.
