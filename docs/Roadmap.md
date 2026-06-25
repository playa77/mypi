# Roadmap — Pi Desktop GUI Wrapper

This roadmap is structured into work packages grouped by phases. Each work package is self-contained where possible, with clear dependencies, deliverables, and estimated effort. Dependencies are noted; some packages can be parallelized. The roadmap assumes a single developer; tasks are sized accordingly (small=0.5–1 day, medium=1–3 days, large=3–5 days). All tasks are traceable to the Design Document and Technical Specification.

---

## Phase 0: Project Setup & Foundations

**Goal:** Establish repository, tooling, and build environment. Produce a minimal Electron app that spawns a placeholder binary and verifies IPC.

### WP0.1 — Repository Initialization
- **Tasks:**
  - Initialize Git repo with `.gitignore`, `README.md` (brief overview).
  - Set up Node.js project (`package.json`, `tsconfig.json` for main & renderer).
  - Install Electron, Electron Forge, React, TypeScript, webpack.
  - Create directory structure as per Technical Spec §2.
- **Deliverable:** Empty Electron app launching a blank window.
- **Effort:** Small (0.5 day)
- **Dependencies:** None

### WP0.2 — Build Pipeline Scripts (Early Stage)
- **Tasks:**
  - Write `scripts/build-pi-binary.sh`: clones pi repo (or uses submodule), installs, builds, uses `pkg` to output a static binary into `resources/pi`. Ensure it targets Linux x64.
  - Write `scripts/extract-pi-schema.ts`: uses `ts-json-schema-generator` to read `PiConfig` type from `@earendil-works/pi-agent-core` and output `src/renderer/generated/settings-schema.json`.
  - Integrate these scripts into `package.json` (`npm run build:pi`, `npm run build:schema`).
  - Test both scripts manually (outputs must exist).
- **Deliverable:** Runnable build commands producing a dummy pi binary (or real one) and a JSON schema file.
- **Effort:** Medium (2 days)
- **Dependencies:** WP0.1 (repo exists)

### WP0.3 — Development Mode Setup
- **Tasks:**
  - Configure Electron Forge for development (webpack dev server with hot reload).
  - Create a `dev:pi` script that either uses a globally installed `pi` or a local dev binary to avoid rebuilding for every change.
  - Add environment variable `PI_CLI_PATH` support; if set, the app uses that binary.
  - Document development workflow in `CONTRIBUTING.md`.
- **Deliverable:** Developer can run `npm run dev` and get a hot-reloading app with a working pi subprocess.
- **Effort:** Small (1 day)
- **Dependencies:** WP0.2

---

## Phase 1: Core Subprocess Integration

**Goal:** Establish the JSON-RPC communication bridge with the pi CLI. Achieve reliable subprocess lifecycle and request/response flow.

### WP1.1 — Subprocess Manager
- **Tasks:**
  - Implement `electron/subprocess-manager.ts`.
    - Spawn pi binary with arguments `agent --rpc --stdio`, set CWD, env.
    - Handle `start()`, `stop()`, `restart()`.
    - Listen to `exit` event and log.
  - Expose status via IPC (`agent:restart`, `agent:status`).
  - Write unit tests with a mock script that echoes RPC-like messages.
- **Deliverable:** SubprocessManager can start/stop a test binary; restart resets correctly.
- **Effort:** Medium (2 days)
- **Dependencies:** WP0.3 (dev mode)

### WP1.2 — JSON-RPC Client
- **Tasks:**
  - Implement `JsonRpcClient` in `electron/jsonrpc-client.ts` as per spec.
    - Parses line-delimited JSON from stdout.
    - Dispatches responses to pending promises, forwards notifications to registered callbacks.
    - Tracks request IDs, handles errors.
  - Integrate with SubprocessManager: wire stdin/stdout.
  - Write unit tests with simulated streams.
- **Deliverable:** Client sends requests, receives responses/notifications; works with a test echo server.
- **Effort:** Medium (2 days)
- **Dependencies:** WP1.1

### WP1.3 — IPC Bridge for RPC
- **Tasks:**
  - Register `ipcMain.handle('rpc:request', ...)` that delegates to SubprocessManager’s `sendRpcRequest`.
  - Forward pi notifications to renderer via `mainWindow.webContents.send('rpc:notification', ...)`, while preventing duplicates on re-render.
  - Implement `preload.ts` to expose `sendRpc` and `onRpcNotification`.
  - Test flow: Renderer invokes `sendRpc` → main process sends to pi → notification appears in renderer.
- **Deliverable:** End-to-end JSON-RPC call returns a response observable from renderer.
- **Effort:** Medium (1.5 days)
- **Dependencies:** WP1.2

### WP1.4 — Workspace Integration
- **Tasks:**
  - Implement `workspace:select` IPC handler: opens native folder dialog, stores path, restarts subprocess with new CWD.
  - Expose current workspace path via IPC (`workspace:get`, used by renderer to display).
  - Handle dialog cancel gracefully.
  - Test that after selecting a folder, the pi subprocess starts in that directory and `PWD` is correct.
- **Deliverable:** User can pick a folder; agent operates there.
- **Effort:** Small (1 day)
- **Dependencies:** WP1.3

---

## Phase 2: Renderer & UI Integration

**Goal:** Build the chat interface using `pi-web-ui` and `xterm.js`, connected to the RPC transport.

### WP2.1 — Basic Renderer App Shell
- **Tasks:**
  - Create React app entry point and root `App.tsx` with routing/state (chat vs settings).
  - Add a top bar showing workspace path and a button to open settings.
  - Add a `WorkspaceSelector` component.
  - Style the shell minimally (CSS or CSS-in-JS).
- **Deliverable:** App shows a window with placeholder areas for chat and terminal.
- **Effort:** Medium (1.5 days)
- **Dependencies:** WP1.4 (workspace IPC)

### WP2.2 — Chat UI with pi-web-ui
- **Tasks:**
  - Install `@earendil-works/pi-web-ui` v0.75.3+.
  - Create `ChatView.tsx` component, wrapping `PiWebUiProvider` and `Chat`.
  - Implement `useRpcTransport` custom hook:
    - `sendMessage` function that calls `window.electronAPI.sendRpc('agent.chat', ...)` and returns a ReadableStream (or async iterator) of chunks from notifications.
    - Manage subscription to `rpc:notification` events.
  - Handle session ID prop passing.
  - Test with a mock RPC backend that emulates `agent.onChunk` and `agent.onComplete`; verify messages appear.
- **Deliverable:** Sending a message results in streamed chat responses displayed in pi-web-ui components.
- **Effort:** Large (3 days) — may need reverse-engineering pi-web-ui’s expected props
- **Dependencies:** WP1.3, WP2.1

### WP2.3 — Shell Terminal Panel
- **Tasks:**
  - Install `xterm` and `xterm-addon-fit`.
  - Create `ShellPanel.tsx` component that mounts a Terminal instance.
  - Listen to `rpc:notification` for `agent.onShellOutput` and write data.
  - Listen to `agent.onToolCall` to show tool start/stop in terminal header.
  - Add resize handling (FitAddon).
  - Ensure terminal only appears when shell output is active; otherwise collapse or show empty state.
- **Deliverable:** Shell commands executed by the agent show live output in a resizable terminal panel.
- **Effort:** Medium (1.5 days)
- **Dependencies:** WP2.2 (notifications already flowing)

### WP2.4 — Diff & File Change Display
- **Tasks:**
  - pi-web-ui includes a `DiffView` component; ensure it receives file change data.
  - Map `agent.onToolCall` (for file operations like `write_file`, `replace`) to `DiffView` props.
  - If pi CLI includes diff output in tool results, parse it; otherwise, leave for future iteration.
- **Deliverable:** When agent modifies a file, a diff card appears in chat.
- **Effort:** Small (1 day)
- **Dependencies:** WP2.2

---

## Phase 3: Settings & Session Management

**Goal:** Full settings GUI and session history functionality.

### WP3.1 — Settings Store (Main Process)
- **Tasks:**
  - Implement `electron/settings-store.ts`:
    - `readSettings()`: reads `~/.pi/.env` and `config.json`, merges into a single object.
    - `saveSettings(settings)`: writes back to `~/.pi/.env` for API keys and to `config.json` for other settings (if pi uses that). Follow pi's actual config structure.
  - Register IPC handlers `settings:get` and `settings:save`.
  - After saving, trigger agent restart with updated env if keys changed.
- **Deliverable:** Settings read/write works.
- **Effort:** Medium (2 days)
- **Dependencies:** WP1.4 (agent restart)

### WP3.2 — Settings UI Form
- **Tasks:**
  - Create `SettingsView.tsx` using `react-jsonschema-form` and the generated JSON schema.
  - Add `ui:schema` customizations to mask passwords, use drop-downs for enums, etc.
  - Load initial formData from IPC (`settings:get`).
  - On submit, call `settings:save`.
  - Provide navigation back to chat.
  - Test that changing model/provider and saving is reflected in the agent's next response.
- **Deliverable:** Full-featured settings page that auto-populates from schema.
- **Effort:** Large (3 days) — schema generation may need refinement
- **Dependencies:** WP2.1 (app shell routes), WP3.1, WP0.2 (schema generation)

### WP3.3 — Session History & Resume
- **Tasks:**
  - Implement `session:list` IPC handler:
    - Invoke `subprocessManager.sendRpcRequest('session.list', [])` or read `~/.pi/sessions/` directory and parse metadata.
  - Implement `session:resume`: restart subprocess with `--resume <id>` flag (or RPC `session.resume`).
  - Add UI: a sidebar or dropdown listing past sessions; selecting one triggers resume.
  - Handle edge case: if session not found, show error.
- **Deliverable:** User can see past sessions, click to resume a conversation where it left off.
- **Effort:** Medium (2 days)
- **Dependencies:** WP2.2 (chat ready), WP1.4 (restart)

---

## Phase 4: Packaging & Self-Contained Binary

**Goal:** Produce the final .deb and AppImage with the bundled pi binary, ensuring no external dependencies on pi.

### WP4.1 — Production Build of pi Binary
- **Tasks:**
  - Finalize `build-pi-binary.sh` to produce a fully statically linked binary (using `pkg` with appropriate Node.js version, or a bundled Node.js if `pkg` fails). Test that the binary runs on a clean Ubuntu 22.04 without Node.js installed.
  - Validate the RPC interface of the built binary: run `./pi agent --rpc --stdio` and send a test message, capture output.
  - Optimize binary size: consider using `--compress` or strip.
- **Deliverable:** Single binary file that acts as a fully functional pi CLI.
- **Effort:** Medium (2 days) — may involve troubleshooting pkg issues
- **Dependencies:** WP1.2 (RPC client works with the binary)

### WP4.2 — Electron Packaging Configuration
- **Tasks:**
  - Configure Electron Forge makers for .deb (dependency list) and AppImage.
  - Set `extraResource` to include `resources/pi`.
  - Add app icon, name, version.
  - Test that after packaging, the app runs and the binary is found (via `process.resourcesPath`).
  - Handle potential changes to binary path between dev and production.
- **Deliverable:** Installable .deb and launchable AppImage.
- **Effort:** Medium (2 days)
- **Dependencies:** WP4.1

### WP4.3 — Automated CI/CD Pipeline
- **Tasks:**
  - Create GitHub Actions workflow:
    - Checkout code and submodules.
    - Build pi binary (cache if possible).
    - Generate settings schema.
    - Run Electron Forge make.
    - Upload artifacts (.deb, .AppImage) as release assets on tag push.
  - Ensure the workflow runs on Ubuntu runners.
- **Deliverable:** On every release tag, distributable builds are produced automatically.
- **Effort:** Medium (2 days)
- **Dependencies:** WP4.2

---

## Phase 5: Testing & Polish

**Goal:** Ensure stability, performance, and usability.

### WP5.1 — Unit & Integration Tests
- **Tasks:**
  - Write Jest tests for JsonRpcClient, SubprocessManager, settings-store.
  - Add integration tests for IPC using a mock pi binary.
  - Add component tests for ChatView with mocked IPC.
- **Deliverable:** >80% code coverage on critical modules.
- **Effort:** Large (3 days)
- **Dependencies:** All features implemented

### WP5.2 — End-to-End Testing
- **Tasks:**
  - Set up Spectron/Playwright to launch the Electron app.
  - Write scenario: launch app → select workspace → send message → see response.
  - Validate that the bundled binary works in the packaged app (use a real pi binary for e2e).
  - Test session resume flow.
- **Deliverable:** Few critical-user-flow automated tests passing.
- **Effort:** Medium (2 days)
- **Dependencies:** WP4.2

### WP5.3 — Error Handling & Edge Cases
- **Tasks:**
  - Implement and test: subprocess crashing and auto-restart; pending request rejection; file permission errors; workspace dialog cancellation; invalid API keys (agent error).
  - Add user-friendly messages and reconnection UI.
- **Deliverable:** Graceful degradation in all known failure modes.
- **Effort:** Medium (2 days)
- **Dependencies:** WP5.1

### WP5.4 — Performance & Polish
- **Tasks:**
  - Profile memory usage; ensure subprocess is not leaking.
  - Add loading states, toast notifications for actions (saving settings, session resumed).
  - Verify UI responsiveness during long agent responses.
- **Deliverable:** Smooth user experience.
- **Effort:** Small (1 day)
- **Dependencies:** WP5.3

---

## Phase 6: Release & Documentation

**Goal:** Public release readiness.

### WP6.1 — Documentation
- **Tasks:**
  - Write `README.md` with installation instructions, feature list, development guide.
  - Add `CHANGELOG.md`.
  - Create a simple user guide (how to set up providers, start chatting, manage sessions).
- **Effort:** Small (1 day)
- **Dependencies:** Phase 5

### WP6.2 — Pre-release Validation
- **Tasks:**
  - Perform manual testing on Ubuntu 22.04 clean VM: install .deb, run, use real pi features (if available) or at least verify RPC with real pi binary.
  - Test AppImage on different Linux distros (Fedora, Debian).
  - Fix any packaging issues.
- **Effort:** Medium (2 days)
- **Dependencies:** WP4.2

### WP6.3 — v1.0.0 Release
- **Tasks:**
  - Tag release `v1.0.0`, trigger CI to build and publish artifacts.
  - Announce (optional).
- **Effort:** Small (0.5 day)
- **Dependencies:** WP6.2

---

## Effort Summary (Estimated)

| Phase | Work Packages | Total Effort |
|-------|---------------|--------------|
| 0: Setup | 3 | 3.5 days |
| 1: Core Subprocess | 4 | 6.5 days |
| 2: UI Integration | 4 | 7 days |
| 3: Settings & Sessions | 3 | 7 days |
| 4: Packaging & CI | 3 | 6 days |
| 5: Testing & Polish | 4 | 8 days |
| 6: Release & Docs | 3 | 3.5 days |
| **Total** | **20 work packages** | **~41.5 days (approx. 8–9 weeks)** |

These estimates assume one developer with moderate Electron/React experience. They will vary based on actual pi CLI RPC interface discovery and pi-web-ui compatibility.

---
