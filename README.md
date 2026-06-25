# Pi Desktop

A self-contained desktop GUI wrapper for the [pi](https://github.com/earendil-works/pi) coding assistant CLI. Chat with an AI agent, watch it execute shell commands in an embedded terminal, and manage settings and sessions — all from a native Linux window. No separate installation of `pi` required.

## Features

- **Multi-turn chat** with the pi coding agent, with streaming responses
- **Provider & model selection** via auto-generated settings form
- **Live shell output** displayed in an embedded terminal (xterm.js)
- **Session history & resume** — pick up past conversations where you left off
- **File read/write diffs** shown inline in chat
- **Prompt template customization** exposed in settings
- **Workspace folder picker** — point the agent at any directory
- **Single, self-contained package** — ships as `.deb` and `.AppImage`

## Prerequisites

### For Users
- **Ubuntu 22.04+** (or any glibc 2.28+ Linux distribution for AppImage)
- No Node.js, npm, or pi CLI installation needed

### For Developers
- **Node.js 20+** and **npm 9+**
- Git (for cloning the pi monorepo)
- [pkg](https://github.com/vercel/pkg) (used during build to compile the pi CLI binary)

## Installation

### From `.deb` (Ubuntu/Debian)

```bash
sudo dpkg -i pi-desktop_1.0.0_amd64.deb
sudo apt-get install -f   # install any missing dependencies
```

Launch from the application menu or run `pi-desktop` from the terminal.

### From `.AppImage` (Any Linux)

```bash
chmod +x pi-desktop-1.0.0.AppImage
./pi-desktop-1.0.0.AppImage
```

## Development

### Setup

```bash
git clone --recurse-submodules https://github.com/playa77/pi-desktop.git
cd pi-desktop
npm install
```

### Development Mode

Runs the Electron app with hot-reload and a locally built (or globally installed) pi CLI so you don't need to rebuild the full binary on every change.

```bash
npm run dev
```

Set `PI_CLI_PATH` to override the pi binary location:

```bash
PI_CLI_PATH=$(which pi) npm run dev
```

Set `PI_DESKTOP_DEBUG=1` to enable DevTools and verbose RPC logging.

### Project Structure

```
pi-desktop/
├── electron/                  # Main process
│   ├── main.ts                # Electron entry point
│   ├── preload.ts             # contextBridge API
│   ├── subprocess-manager.ts  # pi CLI lifecycle
│   ├── jsonrpc-client.ts      # JSON-RPC over stdio
│   └── settings-store.ts      # ~/.pi/.env read/write
├── src/
│   ├── renderer/              # React UI
│   │   ├── components/        # ChatView, SettingsView, ShellPanel
│   │   ├── hooks/             # useRpcTransport
│   │   └── generated/         # Auto-generated settings JSON Schema
│   └── shared/                # Types and constants
├── resources/                  # Build-time output: compiled pi binary
├── scripts/
│   ├── build-pi-binary.sh     # Compile pi CLI with pkg
│   └── extract-pi-schema.ts   # Generate settings JSON Schema
├── forge.config.js            # Electron Forge config
└── package.json
```

## Full Build Process

The build produces a `.deb` and an `.AppImage`, each containing the entire Electron app and a bundled pi CLI binary — a single artifact with no external dependencies on `pi`.

### 1. Compile the pi CLI Binary

```bash
npm run build:pi
```

This runs `scripts/build-pi-binary.sh`, which:

1. Clones the `earendil-works/pi` monorepo (or uses an existing submodule)
2. Checks out the target stable tag
3. Runs `npm install` and `npm run build` inside the pi repo
4. Compiles the pi CLI into a self-contained Linux x64 binary using `pkg`:
   ```
   pkg . --targets node20-linux-x64 --output resources/pi
   ```
5. The resulting `resources/pi` is a single executable with the Node.js runtime and all dependencies baked in

### 2. Generate the Settings JSON Schema

```bash
npm run build:schema
```

This runs `scripts/extract-pi-schema.ts`, which:

1. Reads the `PiConfig` TypeScript interface from `@earendil-works/pi-agent-core`
2. Uses `ts-json-schema-generator` to produce a JSON Schema file
3. Outputs to `src/renderer/generated/settings-schema.json`

This schema drives the settings form (provider keys, model selection, skills, prompt templates) and guarantees it stays in sync with the pi CLI's capabilities.

### 3. Package the Electron App

```bash
npm run make
```

This invokes Electron Forge, which:

1. Compiles the TypeScript main process (`electron/`) via webpack
2. Bundles the React renderer (`src/renderer/`) via webpack
3. Includes `resources/pi` as an `extraResource` (accessible at `process.resourcesPath` in production)
4. Builds a `.deb` package (with declared system dependencies: libgtk-3-0, libnotify4, etc.)
5. Builds an `.AppImage` (self-contained squashfs image)
6. Outputs artifacts to `out/make/`

### 4. AppImage Sandbox Fix (Critical)

Chromium's SUID sandbox helper cannot run inside an AppImage's read-only squashfs filesystem. Without intervention, the Electron app will crash on launch with `FATAL:setuid_sandbox_host.cc` or render a blank window.

This requires **two pieces** wired together at packaging time:

**Piece 1 — Wrapper script** (`scripts/apprun.sh`):

```sh
#!/bin/sh
SELF="$(readlink -f "$0")"
HERE="$(dirname "$SELF")"
exec "$HERE/pi-desktop" --no-sandbox "$@"
```

This script is the AppImage's `AppRun` entrypoint. It calls the real Electron binary with `--no-sandbox`.

**Piece 2 — Injection point** (`forge.config.js`):

The script must be set as the AppImage's entrypoint **during packaging** — not applied after the fact. In `forge.config.js`, configure the AppImage maker to use the custom script:

```js
// Inside forge.config.js makers array, the AppImage entry:
{
  name: '@reforged/maker-appimage',
  config: {
    options: {
      runtime: path.join(__dirname, 'scripts', 'apprun.sh'),
    },
  },
}
```

The exact config key (`runtime`, `entrypoint`, `customEntrypoint`) depends on the maker package chosen. Consult the maker's documentation. The critical invariant: the `scripts/apprun.sh` file is shipped inside the AppImage squashfs as `AppRun`, and it executes the Electron binary with `--no-sandbox` — all happening at packaging time, inside the CI/build step, never as a post-build patch.

The `.deb` package does **not** need this fix — system-installed packages run on a writable filesystem where the Chromium sandbox functions normally.

### One-Command Production Build

```bash
npm run build:prod
```

This runs all three steps sequentially — equivalent to:

```bash
npm run build:pi && npm run build:schema && npm run make
```

### CI/CD

On GitHub Actions (Ubuntu runner), the workflow:

1. Checks out the repo and submodules
2. Runs `npm ci`
3. Runs `npm run build:prod`
4. Uploads `.deb` and `.AppImage` as release artifacts on tag push

## Usage

1. **Launch the app** — the pi agent starts automatically
2. **Configure providers** — open Settings, add your API keys (OpenAI, Anthropic, etc.), select models
3. **Choose a workspace** — click the folder icon to pick which directory the agent works in
4. **Start chatting** — send messages; responses stream in real time
5. **Watch the terminal** — when the agent runs shell commands, live output appears in the bottom panel
6. **Resume sessions** — past conversations are saved automatically; pick one from the sidebar to continue

## Configuration

All settings are stored in `~/.pi/`, matching the standalone pi CLI layout:

| Path | Purpose |
|------|---------|
| `~/.pi/.env` | API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.) |
| `~/.pi/config.json` | Provider preferences, model selection, skills, prompt templates |
| `~/.pi/sessions/` | Chat session history |

This means you can switch between Pi Desktop and the `pi` CLI without any migration — they share the same configuration.

## Architecture

Pi Desktop is a **zero-business-logic wrapper**. All AI agent logic, tool calling, session management, and provider communication runs inside the bundled `pi` CLI subprocess. The Electron app is strictly a presentation layer:

```
Renderer (React + pi-web-ui + xterm.js)
    │  IPC (contextBridge)
Main Process (Node.js)
    │  JSON-RPC over stdin/stdout
pi CLI (bundled static binary)
```

The renderer communicates with the main process over a limited `contextBridge` API. The main process spawns the pi subprocess with `--rpc --stdio` and relays JSON-RPC requests and streaming notifications between the UI and the CLI. The app ships with `nodeIntegration` disabled and a Content Security Policy in place.

## License

MIT — see [LICENSE](LICENSE).
