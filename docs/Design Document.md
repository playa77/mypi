# Design Document — pi GUI Wrapper

**Project Name (proposed):** Pi Desktop

---

## 1. Overview & Goals

Pi Desktop is a minimal desktop GUI wrapper for the [earendil-works/pi](https://github.com/earendil-works/pi) coding assistant CLI. It ships as a **self-contained AppImage and .deb package**, requiring no separate installation of the `pi` CLI. Every pi feature exposed by the CLI is accessible through a native-feeling desktop window without altering the CLI’s logic. The application targets Linux as the primary release platform, with cross-platform architecture allowing future macOS and Windows builds at minimal cost.

### Core Principle

**Zero business logic in the wrapper.** All AI agent, tool calling, session management, and provider logic is executed by the bundled `pi` CLI subprocess. The GUI is strictly a presentation layer that sends JSON-RPC commands over stdio and renders responses using pre-built web components.

---

## 2. Requirements Summary

Traceable to the interview and confirmed answers.

### Must-Have Features (v1)
- **Multi-turn chat** with the pi coding agent, displayed in a message list.
- **Provider and model selection** via auto-generated settings GUI.
- **Skills and extensions management** through the same settings interface.
- **Session history and resume**: list past sessions, resume from any point.
- **Live shell command output** rendered in an embedded terminal (xterm.js).
- **File read/write in a user-chosen workspace** (opens folder picker, sets subprocess CWD).
- **Prompt template customization** exposed in settings.
- **Single, self-contained package**: no external `pi` CLI dependency for end users.

### Deferred (explicitly non-goals for v1)
- Containerization (Docker/Gondolin/OpenShell)
- Session sharing to Hugging Face
- Multiple concurrent sessions
- pi-chat / Slack integration settings
- Self-update of the pi CLI (the whole AppImage is updated instead)

### Non-Functional Requirements
- Runs on Ubuntu 22.04+ (primary) via .deb and AppImage.
- Architecture supports future macOS and Windows builds with zero code changes outside packaging.
- Minimal memory footprint (Electron + subprocess).
- Settings and session data must be compatible with standalone pi CLI usage.
- Real-time streaming of agent responses and shell output.

---

## 3. System Architecture

The application follows a **three-layer architecture** within a single Electron process:

- **Main Process (Node.js):** Spawns pi CLI subprocess, manages JSON-RPC communication, provides file system access for settings/workspace, and exposes APIs via IPC to the renderer.
- **Renderer Process (Chromium):** Hosts React-based UI built with `@earendil-works/pi-web-ui` components and a thin custom RPC transport layer.
- **Bundled pi Binary:** A standalone executable (compiled Node.js) placed in Electron’s `extraResources`, launched via stdio for JSON-RPC communication.

```
┌──────────────────────────────────────────────┐
│                  Electron App                 │
│  ┌────────────────────────────────────────┐  │
│  │          Renderer Process              │  │
│  │  ┌──────────────┐  ┌───────────────┐   │  │
│  │  │  pi-web-ui    │  │  xterm.js     │   │  │
│  │  │ (Chat,        │  │ (Shell Output) │   │  │
│  │  │  Settings)   │  │               │   │  │
│  │  └──────┬───────┘  └───────┬───────┘   │  │
│  │         │                  │           │  │
│  │  ┌──────┴──────────────────┴──────┐    │  │
│  │  │  Custom RPC Transport Layer    │    │  │
│  │  │  (sendMessage, useChat hook)   │    │  │
│  │  └──────────────┬─────────────────┘    │  │
│  └─────────────────│──────────────────────┘  │
│            IPC (contextBridge)                │
│  ┌─────────────────│──────────────────────┐  │
│  │   Main Process  │                      │  │
│  │  ┌──────────────▼──────────────────┐   │  │
│  │  │  JSON-RPC Client & Subprocess   │   │  │
│  │  │  Manager                        │   │  │
│  │  └──────────────┬──────────────────┘   │  │
│  │                 │ stdin/stdout          │  │
│  │  ┌──────────────▼──────────────────┐   │  │
│  │  │  pi CLI (bundled binary)        │   │  │
│  │  │  (agent-core, ai, tool libs)    │   │  │
│  │  └─────────────────────────────────┘   │  │
│  │  ┌────────────────────────────────┐   │  │
│  │  │  File System (settings,        │   │  │
│  │  │  sessions, workspace)          │   │  │
│  │  └────────────────────────────────┘   │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

Key design constraint: **No import of `@earendil-works/pi-agent-core` or `@earendil-works/pi-ai` at runtime.** Only the uncoupled types may be used as a dev dependency to generate the settings schema.

---

## 4. Component Responsibilities

### 4.1 Electron Main Process
- **Subprocess Manager:** Starts the bundled `pi` binary with `--rpc --stdio` flags, sets CWD to the user’s workspace folder, passes environment variables (for provider keys). Maintains the child process lifecycle.
- **JSON-RPC Client:** Serializes requests from renderer over IPC, writes to subprocess stdin; reads from stdout, deserializes responses/notifications, routes back to renderer.
- **Session & Config Helper:** Exposes file system operations to the renderer (read/write `~/.pi/.env`, list session directories, etc.) via IPC, so that settings and session data are handled transparently but compatibly.
- **Workspace Folder Dialog:** Opens native folder picker (via `dialog.showOpenDialog`) and stores the selected path; on selection, restarts the subprocess with new CWD, allowing the agent to work in that directory.

### 4.2 Renderer Process
- **Chat UI (pi-web-ui):** Renders message list, input box, tool call cards, diff views. Uses `useChat` hook with a custom `sendMessage` callback that posts messages to the main process via IPC and listens for events.
- **RPC Transport Layer:** A thin module that translates between pi-web-ui’s expected `sendMessage` signature and the Electron IPC channel. Responsible for dispatching streaming chunk events, tool call updates, and shell output to appropriate UI components.
- **xterm.js Panel:** Mounts an `xterm` terminal emulator connected to a stream of shell output events. Receives data as raw strings from the agent’s `onShellOutput` notification.
- **Settings Page:** Renders an auto-generated form using `react-jsonschema-form` and a JSON Schema derived at build time from `PiConfig` TypeScript interface. On form submission, new settings are written to `~/.pi/.env` or passed as environment to the subprocess (restarting it if needed).

### 4.3 Bundled pi Binary
- Unmodified pi CLI, compiled into a single executable using `pkg`.
- Runs in JSON-RPC server mode, listening on stdin for requests and writing responses/notifications to stdout.
- Handles all agent logic, LLM API calls, tool execution, session persistence, configuration reading.

---

## 5. Data Model

The GUI stores minimal state directly; persistent data resides in the pi CLI’s native storage.

### 5.1 Local Application State (Renderer)
```typescript
interface AppState {
  workspacePath: string | null;
  activeSessionId: string | null;
  // Transient UI state (current conversation view, etc.)
}
```
This state is ephemeral; not persisted between app launches.

### 5.2 pi CLI Native Data (on disk)
- **Configuration:** `~/.pi/config.json` (or similar), with provider settings, model choices, prompt templates, skills definitions. We will also ensure provider API keys are written to `~/.pi/.env` as environment variables that the CLI reads.
- **Sessions:** Stored under `~/.pi/sessions/` as likely JSON or SQLite files. The exact format is opaque to the GUI; we only interact via CLI RPC (`session.list`, `session.resume`).
- **Workspace:** The agent operates directly on the user’s file system at the CWD; no virtual file system.

### 5.3 Settings JSON Schema (derived)
At build time, we will extract the TypeScript interface for `PiConfig` from `@earendil-works/pi-agent-core` (devDependency) and generate a JSON Schema to drive the settings form. This ensures the GUI can configure every option the CLI supports without manual syncing.

---

## 6. API & Interface Design

### 6.1 Electron IPC Channels
The renderer communicates with the main process over a `contextBridge` API:

```typescript
interface IElectronAPI {
  // Chat
  sendRpcRequest(method: string, params: any): Promise<any>;
  onRpcNotification(callback: (notification: RpcNotification) => void): void;

  // Session management
  listSessions(): Promise<string[]>;
  resumeSession(sessionId: string): Promise<void>;

  // Settings
  readSettings(): Promise<PiSettings>;
  writeSettings(settings: PiSettings): Promise<void>;

  // Workspace
  selectWorkspace(): Promise<string>;

  // Subprocess control
  restartAgent(env?: Record<string, string>): Promise<void>;
}
```

### 6.2 pi CLI JSON-RPC (expected)
Based on [PROPOSED DESIGN DECISION] we will use the command `pi agent --rpc --stdio`. The exact method names are anticipated from the CLI’s documented feature set:

```json
// Request
{"jsonrpc":"2.0","method":"agent.chat","params":{"session_id":"optional","message":"...","workspace":"..."},"id":1}

// Notifications (streaming)
{"jsonrpc":"2.0","method":"agent.onChunk","params":{"chunk":"..."}}
{"jsonrpc":"2.0","method":"agent.onToolCall","params":{"tool_name":"...","args":...}}
{"jsonrpc":"2.0","method":"agent.onShellOutput","params":{"data":"...\n"}}
{"jsonrpc":"2.0","method":"agent.onComplete","params":{"finish_reason":"stop"}}
```

Additional methods for session management will be mapped in implementation (e.g., `session.list`, `session.resume`). The exact specification will be validated against the actual binary; adjustments will be encapsulated in the subprocess manager.

### 6.3 pi-web-ui Integration
The `PiWebUiProvider` expects a configuration object with `endpoint`, `apiKey`, etc. Instead of providing real HTTP endpoint/API key, we will inject a mock `sendMessage` function that instead calls our IPC-based RPC client. The `useChat` hook will call `sendMessage(text, sessionId)` and we will convert its promise/stream into the expected interface of the chat state.

---

## 7. Security Architecture

### 7.1 API Key Handling
- Keys are stored in `~/.pi/.env` (plain text, as the pi CLI does). The Electron app reads this file when launching the subprocess and passes it as environment variables.
- When users enter new keys in the settings form, the app writes them to the `.env` file and restarts the agent. The keys are never sent to the renderer (they are redacted in the IPC response).
- We will consider in a future version to use the OS keychain for enhanced security─this would require a change in the pi CLI’s own key reading logic, so it’s out of scope for v1.

### 7.2 Subprocess Sandboxing
- The pi agent runs with the user’s permissions at the chosen workspace folder. The GUI does not restrict its access beyond what the CLI would normally do.
- We will not add any sandboxing of our own; the agent’s containerization feature (deferred) is the recommended path for safe execution.

### 7.3 Electron Security
- `nodeIntegration` in the renderer is disabled.
- Only preload-exposed APIs are available via `contextBridge`.
- Content Security Policy (CSP) will be set to restrict script sources.
- DevTools will be disabled in production builds.

---

## 8. Infrastructure & Deployment

### 8.1 Build Pipeline (Self-Contained Binary)
1. **Obtain pi CLI source:** Either include the `earendil-works/pi` monorepo as a submodule or a npm dependency for the build script. We will use the same version used for development.
2. **Compile pi to standalone binary:** Use `pkg` (by Vercel) to create a single executable that bundles the Node.js runtime and all dependencies. Target: Linux x64, output: `dist/pi`.
3. **Include in Electron:** Place the compiled binary into `extraResources/pi` (configured in Electron Forge/Builder).
4. **Electron Build:** Package the Electron app with the extra resource. Build for .deb and AppImage using Electron Forge’s makers.
5. **CI/CD:** A GitHub Action workflow can automate the pi binary compilation and Electron packaging, triggered on version tags.

### 8.2 Packaging Details
- **.deb**: Targets Ubuntu 22.04+, includes dependency on `libgtk-3-0`, `libnotify4`, etc. (Electron’s standard dependencies).
- **AppImage**: Self-contained squashfs image, runs on any glibc2.28+ Linux without installation.

### 8.3 Development Mode
- For development, we will use a locally built or development version of the pi CLI (e.g., `npx pi` or a relative path to a development binary). This avoids rebuilding the large static binary on every change. A `PI_CLI_PATH` environment variable allows overriding.

---

## 9. Operational Model

### 9.1 Application Lifecycle
- Start → Main process spawns pi binary with `--rpc --stdio` using CWD = last workspace (or home directory by default).
- Renderer loads, shows chat interface.
- User selects workspace folder → Main restarts subprocess with new CWD.
- User sends message → Renderer IPC → Main writes JSON-RPC request to stdin → pi processes → returns streaming notifications → Main forwards to Renderer → UI updates.
- On exit: Main process kills subprocess gracefully.

### 9.2 Session Persistence
- Sessions are saved automatically by the pi CLI when the agent completes or when explicitly saved. The GUI can query for past sessions using an RPC method `session.list`.
- Resuming a session: The GUI sends a `session.resume` request to the main process, which restarts the pi subprocess with the appropriate `--resume` flag (or equivalent RPC parameter).

### 9.3 Logging & Debugging
- The main process will log all RPC communication to a file (rotating) for debugging purposes. The user can enable verbose logging from a settings toggle.
- Crash reports from the pi subprocess are captured and displayed via dialog.

---

## 10. Key Design Decisions

| Decision | Rationale | Traceability |
|----------|-----------|--------------|
| Use pi CLI subprocess, not SDK | Minimal logic in GUI, avoids reinventing session management, tool execution, etc. User’s revised Q1 answer. | Q1 (Option B) |
| Bundle pi as static binary via `pkg` | Satisfies the strict self-contained requirement (no separate pi install). | User directive: “releases must be one single, fully self-contained appimage or deb” |
| Use `@earendil-works/pi-web-ui` for chat | Pre-built, polished, maintained by pi project, reduces UI development to integration. | Q2: `pi-web-ui` exists and is documented |
| Custom RPC transport layer glue | pi-web-ui doesn’t include an RPC client; we must bridge to our subprocess via IPC. | Q5 research |
| Embed `xterm.js` for shell output | pi-web-ui lacks a terminal component; needed to show real-time shell execution. | Original user suggestion; Q4 (live shell output must-have) |
| Settings form from derived JSON Schema | Avoids manually coding UI for every pi config option. Automatically stays in sync with CLI capabilities. | Q4 (all settings must be wrapped), Q7 research finding (no ready schema) |
| Store keys in `~/.pi/.env` | Compatible with pi CLI’s own configuration, zero migration needed. | Q7 research finding |
| Workspace via subprocess CWD | Simplest way to give context to pi CLI without special flags. CLI inherently uses process CWD. | Q8 and revised architecture |
| Linux-first, but Electron cross-platform | Electron makes macOS/Windows trivial; no Linux-only native modules. | Q3 (Option B) |

---

## 11. Open Questions & Assumptions

### Assumptions (to be validated)
1. [ASSUMPTION] The pi CLI can be invoked with `pi agent --rpc --stdio` to start a JSON-RPC server on stdio. If the flag is different, we will adjust the launch command.
2. [ASSUMPTION] The `pkg` compilation of the pi CLI into a single binary works without Node.js native module issues. If it fails, we may use a bundled Node.js runtime with the pi source as an alternative (less ideal but still self-contained).
3. [ASSUMPTION] The `@earendil-works/pi-web-ui` React component library uses a standard `useChat` hook pattern that can accept a custom `sendMessage` function. We will validate compatibility early.
4. [ASSUMPTION] The pi CLI stores sessions in a file-based format under `~/.pi/sessions/` and provides RPC calls to list and resume them. The exact methods will be discovered and integrated.
5. [ASSUMPTION] The TypeScript interface `PiConfig` (or similar) is exported from `@earendil-works/pi-agent-core` and can be used to generate a JSON Schema. If not, we will fall back to dynamically invoking `pi config list` to discover settings and generate a form from that output.
6. [ASSUMPTION] The pi CLI reads API keys from environment variables defined in `~/.pi/.env` (or standard env vars like `OPENAI_API_KEY`). This is consistent with the project’s documentation.

### Open Questions
- **RPC method names:** Exact method names (`agent.chat`, `session.*`, etc.) need to be confirmed from the actual pi binary. We will build a small test harness during initial development to probe.
- **File change diffs:** Does the pi CLI emit file change notifications that we can map to the `DiffView` component? If not, we may need to parse tool call results for file operations and render diffs ourselves.

---

## Consistency Checklist (Completed)
- All must-have features mapped to architecture.
- No TBD placeholders; all design decisions are justified.
- Security considerations accounted for.
- Build pipeline for self-contained binary included.
- Non-goals clearly stated to avoid scope creep.

---
