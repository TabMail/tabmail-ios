
### iOS Keychain Persistence
- Keychain items survive app deletion/reinstall
- Must detect fresh installs via UserDefaults flag and clear stale Keychain data
