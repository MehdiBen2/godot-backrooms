# Claude Account Switcher

Switch between several Claude Code logins in VS Code.

## Install (no Node needed)
Copy this folder to `%USERPROFILE%\.vscode\extensions\local.claude-account-switcher-0.1.0`, then restart VS Code.
For development: open this folder in VS Code and press F5.

## Use
1. Signed in as account A: run **Claude: Save Current Account as Profile** -> name it.
2. Run **Claude: Add New Account (sign out current)**, reload, log in as account B, save it as a profile.
3. Click the status bar item (or run **Claude: Switch Account**) to swap, then reload the window.

Profiles are stored in `%USERPROFILE%\.claude-profiles\` (copies of `.credentials.json` plus the `oauthAccount` entry).
**These contain login tokens in plain text.** On a shared PC, each person should use their own Windows account, or delete their profile when done.
