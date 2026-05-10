# Hermes Desktop - OS1 Edition

> **OS1 by Element Software** · powered by Orgo · forked from Hermes Desktop

A native macOS interface for an AI agent that lives in a cloud computer.
Inspired by *Her* (2013): warm coral on cream, thin type, calm motion.

Provision a cloud computer, hand it to the agent, and stay in one
focused workspace: sessions, kanban, files, skills, cron jobs, and a
real terminal. The infrastructure is Orgo; the agent on it is Hermes.
The product you touch is OS1.

## What you get

- **Cloud computers, end to end**: paste your API key once, pick a
  workspace, pick a computer (or create one), save. The app talks
  directly to the platform's HTTP API and the per-VM websocket
  terminal — no SSH, no gateway, no helper service on the VM.
- **One-click agent install** on a fresh computer. The first time you
  open the workspace and the agent isn't there, the Overview screen
  surfaces an "Install Hermes Agent" button. ~60–90 seconds later
  Sessions, Kanban, Files, Skills, and Cron all populate.
- **Real interactive shell** over the per-VM terminal websocket.
  Bytes stream in real time; resize works; output and history reflow
  cleanly.
- **SSH connections still supported** for hosts you reach over SSH
  today. Same flow as the upstream Hermes Desktop fork OS1 was built
  on.
- **Everything else** from the foundation: native Sessions browser
  with full-text search, Kanban board, file editor with conflict
  checks, skills viewer, cron job manager, profile-aware paths,
  English / Simplified Chinese / Russian localization scaffolding.

## Requirements

- macOS 14 or newer (Apple Silicon or Intel — universal build)
- One of:
  - An **Orgo account** with an API key (the cloud-computer infra
    powering OS1 — get a key at
    [orgo.ai/settings/api-keys](https://www.orgo.ai/settings/api-keys)),
    OR
  - A host you already reach with `ssh` from this Mac without
    interactive prompts (same flow as upstream Hermes Desktop)

For cloud computers, the app handles VM provisioning, agent
installation, and the websocket terminal automatically. For SSH
connections, the host needs `python3` on the non-interactive SSH PATH
and Hermes already installed.

## Install

Download the latest `OS1.app.zip` from the GitHub Releases page,
unzip it, drag `OS1.app` into `/Applications`, and launch.

The build is universal (Apple Silicon + Intel) and ad-hoc signed.
On first launch macOS may say it can't verify the developer — right-click
the app, choose Open, and confirm.

## Setup

### Cloud computer (recommended)

1. Open the **Connections** tab → click **Add Host**
2. Switch the transport picker to **Orgo VM**
3. Paste your API key → click **Verify & Save**. The key persists in
   the macOS Keychain; subsequent connections reuse it.
4. Pick a workspace from the dropdown.
5. Pick a computer, or click **Create new computer…** to spin one up
   inline (defaults: Linux, 8 GB RAM, 4 CPU, 50 GB disk).
6. Save → the connection is selectable from the host list.
7. If the agent isn't installed on the VM, the **Overview** screen
   shows an install banner. One click runs the official Hermes
   Agent installer. You can use the rest of the app while it runs.

### SSH

Add a connection and switch the transport picker to **SSH**. Alias or
host, optional user/port, optional Hermes profile.

## Build from source

```sh
./scripts/build-macos-app.sh
```

The bundle lands at `dist/OS1.app`.

```sh
swift test
```

## Realtime voice mode

OS1 includes a minimal WebRTC voice mode using OpenAI Realtime calls
with `gpt-realtime-2`. The app starts a loopback session endpoint when
the boot animation finishes. The bottom-left **Voice** row toggles the
live voice connection on or off; there is no separate voice control
panel.

The browser surface in the app sends raw SDP to `POST /session` on a
loopback-only endpoint protected by a per-process random token. The
Swift endpoint keeps `OPENAI_API_KEY` server-side, forwards the SDP to
`https://api.openai.com/v1/realtime/calls`, and uses multipart
`FormData` fields named `sdp` and `session`.

Use the **Providers** tab to save an OpenAI key in the macOS Keychain.
For local development, `OPENAI_API_KEY` is also supported as a fallback.

Run from source with an environment fallback:

```sh
OPENAI_API_KEY="sk-..." swift run OS1
```

Run the packaged app from a shell with an environment fallback:

```sh
./scripts/build-macos-app.sh
OPENAI_API_KEY="sk-..." ./dist/OS1.app/Contents/MacOS/OS1
```

The packaging script signs ad-hoc with an explicit designated
requirement for `com.elementsoftware.os1`, which gives macOS a stable
local app identity so privacy grants such as microphone access can
survive rebuilds. For a stronger certificate-backed identity, set
`OS1_CODESIGN_IDENTITY` / `HERMES_CODESIGN_IDENTITY`, or set
`OS1_AUTO_CODESIGN=1` to use the first available `Apple Development`
identity.

After the boot animation completes, the hidden WebRTC view requests
microphone access, opens the `oai-events` data channel, registers a sample
`check_calendar(date, time)` function with `session.update`, and asks
the model to greet with `hello, can you hear me?`.

The same voice session also exposes Orgo MCP tools to the model as
Realtime function tools. OS1 starts the MCP server locally, reads tools
with `tools/list`, registers them with `session.update`, and forwards
model tool calls back to `tools/call`; Orgo credentials stay in the
Swift app and are never sent to the browser or model. By default the
Realtime voice bridge exposes `core,screen,files`, disables file upload,
uses the saved Orgo API key in OS1 or `ORGO_API_KEY` if no key is saved,
passes the active Orgo connection's computer ID as
`ORGO_DEFAULT_COMPUTER_ID`, and defaults the local MCP process to
read-only mode.

Voice mode runs `npx -y @orgo-ai/mcp@3.0.0` by default. You can override the
bridge with:

```sh
OS1_ORGO_MCP_JS_PATH="/absolute/path/to/dist/index.js"
OS1_ORGO_MCP_PACKAGE="@orgo-ai/mcp@3.0.0"
OS1_REALTIME_ORGO_TOOLSETS="core,screen,files"
OS1_REALTIME_ORGO_DISABLED_TOOLS="orgo_upload_file"
OS1_REALTIME_ORGO_READ_ONLY="true"
```

`OS1_ORGO_MCP_PACKAGE` must include an explicit npm version. `shell` and
`admin` are opt-in through `OS1_REALTIME_ORGO_TOOLSETS`, and write-capable
tool behavior requires explicitly setting `OS1_REALTIME_ORGO_READ_ONLY=false`.
Only enable them for agents and computers you are comfortable letting a voice
model operate.

Live integration tests (skipped by default) hit a real cloud computer:

```sh
ORGO_LIVE_TESTS=1 \
ORGO_API_KEY="sk_live_..." \
ORGO_DEFAULT_COMPUTER_ID="<uuid>" \
swift test --filter OrgoTransportLiveTests
```

## How it routes

For cloud connections:

1. **HTTP ops** (`/bash`, `/exec`) try the platform proxy at
   `https://www.orgo.ai/api/computers/{id}/...` first. On a 5xx
   that looks like a routing failure (ECONNREFUSED, gateway timeout,
   stale port), the transport falls back to the direct VM URL
   `https://<fly_instance_id>.orgo.dev/...` with the VNC password as
   bearer. Long-running ops (e.g. the agent installer) skip the
   proxy entirely since its 30s request timeout would always trip
   first.
2. **Terminal** opens a websocket directly to
   `wss://<fly_instance_id>.orgo.dev/terminal?token=<vncPassword>`,
   feeding bytes into SwiftTerm.

VM clock drift, missing system git, stale apt locks from earlier
attempts — all handled in the install path so you don't have to wrestle
with the VM by hand.

## Acknowledgements

OS1 builds on two layers of generous prior work:

- The original native macOS application code is forked from
  [dodo-reach/hermes-desktop](https://github.com/dodo-reach/hermes-desktop),
  the SSH-first companion for the Hermes Agent. The conventions, panels,
  discovery model, and most of the SSH-side code are that author's
  design.
- The cloud-computer transport, websocket terminal, agent auto-install,
  and connection picker were added on top to make OS1 work directly
  with Orgo VMs.

The visual design language (coral on cream, DM Sans, OS¹ wordmark) is
the **Element Software** product theme — see [`OS-1`](https://github.com/nickvasilescu/OS-1)
for the canonical palette and motion vocabulary that this app borrows.

License: [MIT](LICENSE). All upstream copyrights are preserved.

## Status

This is an early build. Translation polish, GitHub Pages site, and
signing/notarization are still in progress. Open issues in this repo
for bugs and feature requests.
