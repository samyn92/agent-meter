# Agent Meter

Native macOS menu-bar app for the **existing Claude Code and Codex subscription logins** on this Mac. AppKit status item and SwiftUI popover; no Electron, web server, package dependencies, API billing estimates, or model requests. Requires macOS 14 or later and Swift 6 to build.

## Open

Installed at `~/Applications/Agent Meter.app`:

```sh
open "$HOME/Applications/Agent Meter.app"
```

Click the gauge icon or the `C … · X …` menu-bar text (**C** = Claude, **X** = Codex). Each provider shows its plan, quota **used** (not remaining), reset countdowns, and last successful update. Optional model/code-review quota windows appear when the provider reports them. Hover over reset times for the precise local date.

- Automatic refresh: every five minutes, plus a due refresh after wake/opening.
- Manual refresh: at least 60 seconds between checks, with a visible cooldown.
- Failed refreshes retain the previous reading **marked stale**, not as live data. Readings older than ten minutes are also stale; `*` marks them in the menu bar.
- An elapsed reset says **Awaiting refresh**. The app does not fabricate a new allowance.
- Launch at login is off unless registered through the toggle. It uses macOS Login Items; if approval is required, approve it in System Settings → General → Login Items.
- Quit from the popover or right-click menu.

The app has no Dock icon. Opening the installed app again uses the running instance; click its menu-bar item to view quotas.

## Authentication and privacy

Log in using the CLIs first:

```sh
claude auth login
codex login
```

Claude credentials are read from `~/.claude/.credentials.json` when present, otherwise from the macOS `Claude Code-credentials` Keychain item through `/usr/bin/security`. The native Keychain API stalled during local verification, whereas the OS helper honored the existing credential access rules. Codex credentials are read from `~/.codex/auth.json`. API-key-only accounts do not supply subscription quotas.

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` are honored when passed to the executable. Finder/Launch Services apps do not inherit Terminal startup-file environment variables. Custom Claude directories need a credentials file: custom-directory Keychain items are not supported, and the app will **not** silently read a different default account.

Tokens remain in process memory and are sent only to their provider in authorization headers. No credential writes, token refresh, secret logging, disk usage cache, telemetry, or third-party service. HTTP redirects are rejected. Credentials are reread on every check so CLI login changes are picked up. If tokens expire, run the appropriate CLI login command again; Agent Meter does not independently manage your session.

## Build and verify

```sh
./test-providers.sh
./build-app.sh --install
open "$HOME/Applications/Agent Meter.app"
```

The regression runner compiles the real quota parsers and checks 11 behavior scenarios without XCTest or Swift Testing, which are absent from this Mac's Command Line Tools installation.

The builder produces `dist/Agent Meter.app`, ad-hoc signs it, and optionally installs it in your user Applications directory. This is a local build, not a notarized distribution; do not assume it can be distributed without proper signing/notarization.

A safe live diagnostic reads both actual subscriptions, outputs only plan/quota/reset details, and exits nonzero if either provider fails:

```sh
"$HOME/Applications/Agent Meter.app/Contents/MacOS/AgentMeter" --check
```

`--show` opens the popover at startup. `--help` lists executable options.

## Data sources

[Omarchy's Claude collector](https://github.com/omacom/omarchy/blob/quattro/bin/omarchy-agent-usage-claude) reads Anthropic's OAuth usage endpoint. [Omarchy's Codex collector](https://github.com/omacom/omarchy/blob/quattro/bin/omarchy-agent-usage-codex) uses Codex app-server rate-limit RPC.

Agent Meter uses `https://api.anthropic.com/api/oauth/usage` with the existing Claude OAuth login. For Codex it uses `https://chatgpt.com/backend-api/wham/usage`, which returned live quotas with this Mac's existing Codex login. The installed Codex CLI is version 0.44.0; direct usage access avoids requiring an upgrade for newer app-server methods.

These are provider-internal subscription endpoints, not stable public APIs. Schema/auth changes can break usage collection; the app reports failures rather than inventing usage. This is subscription allowance monitoring, not a historical token counter or monthly renewal-date tracker.

## Local verification

Release bundle built and installed; 11 quota regression scenarios passed. The installed `--check` command fetched live Claude Max and Codex Plus quota windows and reset dates. A missing-Claude-credentials scenario reported that failure while still returning live Codex data. A temporary in-process native smoke capture confirmed that the actual popover opened at 410 × 620 on the main thread with both live subscriptions; its rendered view was visually inspected. The capture hook was removed afterward. Accessibility inspection of the final installed app confirmed the menu-bar title and both providers' live quota tooltips. Full-desktop capture was unavailable because screen-recording access was not granted. Launch-at-login approval and a logout/login cycle were not exercised.
