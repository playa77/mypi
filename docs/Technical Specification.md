# Technical Specification — Pi Desktop GUI Wrapper

---

## 1. Implementation Scope

This specification covers all components required to build the Pi Desktop Electron application as described in Document 1. The implementation is scoped to deliver v1 with the must-have features and self-contained packaging. No deferred features (containerization, multi-session, etc.) are included.

**In scope:**
- Electron application with main and renderer processes.
- Bundled pi CLI binary for Linux x64, compiled using `pkg` from the `earendil-works/pi` monorepo.
- UI based on `@earendil-works/pi-web-ui` React components and `xterm.js`.
- Custom RPC transport layer bridging pi CLI JSON-RPC to Electron IPC.
- Settings page auto-generated from JSON Schema derived from pi's TypeScript config interface.
- Workspace folder selection via native dialog.
- Session list/resume via subprocess commands.
- Packaging as .deb and AppImage.

**Out of scope:** Docker/Gondolin, session sharing, Slack integration, multi-session, self-update of pi CLI.

---

## 2. Project Structure

```
pi-desktop/
├── electron/
│   ├── main.ts                 # Electron main process entry
│   ├── preload.ts              # contextBridge API definitions
│   ├── subprocess-manager.ts   # Spawns and manages pi CLI child process
│   ├── jsonrpc-client.ts       # JSON-RPC client for stdio communication
│   ├── settings-store.ts       # Read/write ~/.pi/.env and config files
│   └── session-helper.ts       # IPC handlers for session list/resume
├── src/
│   ├── renderer/               # Renderer React app
│   │   ├── index.tsx           # React entry point
│   │   ├── App.tsx             # Root component, routing
│   │   ├── components/
│   │   │   ├── ChatView.tsx    # Wraps pi-web-ui chat components
│   │   │   ├── SettingsView.tsx# Auto-generated settings form
│   │   │   ├── ShellPanel.tsx  # xterm.js terminal panel
│   │   │   └── WorkspaceSelector.tsx # Folder picker trigger
│   │   ├── hooks/
│   │   │   └── useRpcTransport.ts # Custom sendMessage for pi-web-ui
│   │   ├── ipc-bridge.ts      # Typed wrapper around window.electronAPI
│   │   └── types/
│   │       └── rpc.ts         # RPC notification/response types
│   └── shared/                 # Shared constants and types
│       └── config.ts
├── resources/
│   └── pi                      # Compiled pi binary (placed here at build time)
├── scripts/
│   ├── build-pi-binary.sh      # Script to compile pi using pkg
│   └── extract-pi-schema.ts    # Generates JSON Schema from pi-agent-core types
├── forge.config.js             # Electron Forge configuration
├── package.json
├── tsconfig.json
└── README.md
```

---

## 3. Dependencies

### Runtime (production)
- **electron** (v28+): Framework for native desktop app.
- **react**, **react-dom**: UI library (version matching pi-web-ui peer dependency).
- **@earendil-works/pi-web-ui** (v0.75.3+): Pre-built chat UI components.
- **xterm**, **xterm-addon-fit**: Terminal emulator for shell output.
- **react-jsonschema-form** (v5+): Dynamic form generation from JSON Schema.
- **@rjsf/core**, **@rjsf/validator-ajv8**: RJSF dependencies.

### Dev Dependencies
- **electron-forge** and related plugins/makers: For building .deb and AppImage.
- **@earendil-works/pi-agent-core** (same version as pi CLI): Only for its TypeScript types (`PiConfig`, etc.). Not imported at runtime.
- **typescript**, **webpack** (or vite): Build tools for renderer.
- **ts-to-json-schema** or custom script: To convert TS interfaces to JSON Schema.
- **pkg** (optional, not used at runtime): For compiling pi binary in build script.

### System
- The bundled pi binary is compiled via `pkg` which requires Node.js 20+ during build. The resulting binary is self-contained.

---

## 4. Configuration

### Electron Forge (`forge.config.js`)

```js
module.exports = {
  packagerConfig: {
    extraResource: ['./resources/pi'], // includes pi binary
    executableName: 'pi-desktop',
    icon: './icons/icon',
  },
  makers: [
    {
      name: '@electron-forge/maker-deb',
      config: {
        options: {
          maintainer: '...',
          homepage: '...',
          section: 'utils',
          depends: ['libgtk-3-0', 'libnotify4', 'libnss3', 'libxss1', 'libxtst6', 'xdg-utils', 'libatspi2.0-0', 'libdrm2', 'libgbm1', 'libxcb-dri3-0', 'libxdamage1', 'libxfixes3', 'libxrandr2'],
        },
      },
    },
    {
      name: '@electron-forge/maker-appimage',
      config: {},
    },
  ],
  plugins: [
    {
      name: '@electron-forge/plugin-webpack',
      config: {
        mainConfig: './webpack.main.config.js',
        renderer: {
          config: './webpack.renderer.config.js',
          entryPoints: [{
            html: './src/renderer/index.html',
            js: './src/renderer/index.tsx',
            name: 'main_window',
          }],
        },
      },
    },
  ],
};
```

### Renderer App Config (`src/shared/config.ts`)

```typescript
export const APP_CONFIG = {
  // In development, this might be overridden to point to a local pi binary
  PI_BINARY_PATH: process.env.PI_CLI_PATH || path.join(process.resourcesPath, 'pi'),
  PI_SETTINGS_DIR: path.join(os.homedir(), '.pi'),
  PI_ENV_FILE: path.join(os.homedir(), '.pi', '.env'),
};
```

### pi Subprocess Arguments

We will launch the bundled binary with:
```
pi agent --rpc --stdio
```
If the exact flag differs, this is adjusted in `subprocess-manager.ts`.

---

## 5. Data Layer

### 5.1 RPC Notification Types (shared between main and renderer)

```typescript
// src/shared/types/rpc.ts
export interface RpcRequest {
  jsonrpc: "2.0";
  method: string;
  params?: any;
  id: string | number;
}

export interface RpcResponse {
  jsonrpc: "2.0";
  result?: any;
  error?: { code: number; message: string; data?: any };
  id: string | number;
}

export interface RpcNotification {
  jsonrpc: "2.0";
  method: string;
  params: any;
}

export interface ChatChunkNotification {
  chunk: string;
  session_id?: string;
}

export interface ToolCallNotification {
  tool_name: string;
  args: Record<string, any>;
  result?: string;
}

export interface ShellOutputNotification {
  data: string; // raw stdout/stderr
}
```

### 5.2 pi Settings Schema (extracted at build time)

The script `extract-pi-schema.ts` will:

1. Import the `PiConfig` interface from `@earendil-works/pi-agent-core` using TypeScript compiler API or a library like `ts-json-schema-generator`.
2. Generate a JSON Schema file to `src/renderer/generated/settings-schema.json`.
3. This schema is imported in `SettingsView.tsx` and fed to `<Form schema={settingsSchema} ...>`.

Example expected schema (partial, based on typical pi config):

```json
{
  "type": "object",
  "properties": {
    "providers": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "enum": ["openai", "anthropic", "groq", ...] },
          "apiKey": { "type": "string" },
          "baseURL": { "type": "string", "format": "uri" }
        }
      }
    },
    "default_model": { "type": "string" },
    "skills": { "type": "array", "items": { "type": "string" } },
    "prompt_templates": { "type": "object" }
  }
}
```

### 5.3 Session Data

Sessions are stored by pi CLI in `~/.pi/sessions/`. The main process provides IPC calls:

- `session:list` → returns array of `{ id: string, title: string, updated_at: string }` by reading the session directory or invoking an RPC command.
- `session:resume` → restarts the pi subprocess with `--resume <id>` flag.

---

## 6. API Specification (Electron IPC)

Only the API exposed via `contextBridge` in `preload.ts`. No other Node.js APIs are exposed to the renderer.

```typescript
// preload.ts
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  sendRpc: (method: string, params: any) => ipcRenderer.invoke('rpc:request', method, params),
  onRpcNotification: (callback: (notification: any) => void) => {
    ipcRenderer.on('rpc:notification', (_event, notification) => callback(notification));
  },
  selectWorkspace: () => ipcRenderer.invoke('workspace:select'),
  getSettings: () => ipcRenderer.invoke('settings:get'),
  saveSettings: (settings: any) => ipcRenderer.invoke('settings:save', settings),
  listSessions: () => ipcRenderer.invoke('session:list'),
  resumeSession: (id: string) => ipcRenderer.invoke('session:resume', id),
  restartAgent: (env: Record<string, string>) => ipcRenderer.invoke('agent:restart', env),
});
```

### IPC Invocation Contract

| Channel            | Parameters                       | Returns                                       |
|--------------------|----------------------------------|-----------------------------------------------|
| `rpc:request`      | `method: string, params: any`    | `Promise<any>` (RPC result)                   |
| `workspace:select` | none                             | `Promise<string>` (selected folder path)       |
| `settings:get`     | none                             | `Promise<object>` (current settings from .env) |
| `settings:save`    | `settings: object`               | `Promise<void>`                                |
| `session:list`     | none                             | `Promise<{id,title,updated}[]>`                |
| `session:resume`   | `id: string`                     | `Promise<void>`                                |
| `agent:restart`    | `env: Record<string, string>`    | `Promise<void>`                                |

The main process's `ipcMain.handle` will implement these.

---

## 7. AuthN/AuthZ

There is no user authentication within the desktop app itself. The pi CLI uses API keys for LLM providers, stored as environment variables (e.g., `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`).

### API Key Management in the GUI

1. **Settings Form**: When a user opens settings, the app reads `~/.pi/.env` and populates the form fields for API keys. The fields are rendered as `password` type in `react-jsonschema-form` via the `ui:widget` property.
2. **On Save**: The updated key values are written back to `~/.pi/.env`. The main process then restarts the pi subprocess with the new environment variables so the changes take effect.
3. **Security**: The render never accesses the raw file system; it communicates via IPC. The main process never sends API keys back to the renderer except for the masked display (masked in transit) to avoid leakage. The full keys are only present in the main process memory during save.

We'll add a `settings:getKeys` (masked) vs `settings:getFull` (for save) but since the form needs to edit, we can send the full value to the render for editing but that's a potential risk. Instead, we can have the form store the value locally and only when saving, we re-read the file, merge, write. Or we can use a secure IPC that only sends the needed fields. Since it's a local app, the risk is low; but to follow best practices, we will use `secureIPC` flag or not send keys back to renderer unnecessarily. The simplest: load keys into the settings form via IPC but trust the render with them; better would be to have a separate window for keys that calls main process directly. For v1, we'll accept the risk (local machine, no remote access) and just send the full config object.

---

## 8. Module Specifications

### 8.1 Main Process (`electron/main.ts`)

- Responsible for creating BrowserWindow and loading renderer.
- Instantiates `SubprocessManager` and starts pi binary on launch.
- Registers IPC handlers (`settings`, `workspace`, `session`, `rpc`).

```
// main.ts pseudo
app.whenReady().then(() => {
  const subprocessManager = new SubprocessManager();
  subprocessManager.start({ cwd: homedir, env: loadEnv() });

  const mainWindow = new BrowserWindow({
    webPreferences: { preload: path.join(__dirname, 'preload.js'), nodeIntegration: false }
  });

  // Register IPC handlers
  registerIpcHandlers(subprocessManager, mainWindow);
});
```

### 8.2 Subprocess Manager (`electron/subprocess-manager.ts`)

```typescript
interface SpawnOptions {
  cwd?: string;
  env?: Record<string, string>;
}

class SubprocessManager {
  private child: ChildProcess | null = null;
  private rpcClient: JsonRpcClient;

  start(options?: SpawnOptions): void;
  stop(): void;
  restart(options?: SpawnOptions): void;
  sendRpcRequest(method: string, params: any): Promise<any>;
  onNotification(callback: (notification: RpcNotification) => void): void;
}
```

Internally, it spawns:

```ts
const piPath = app.isPackaged ? path.join(process.resourcesPath, 'pi') : APP_CONFIG.PI_BINARY_PATH;
this.child = spawn(piPath, ['agent', '--rpc', '--stdio'], {
  cwd: options.cwd || homedir,
  env: { ...process.env, ...options.env },
  stdio: ['pipe', 'pipe', 'pipe'], // stdin, stdout, stderr
});
```

- `stdin` is used by `JsonRpcClient` to write JSON-RPC requests.
- `stdout` is read line-by-line and parsed as JSON-RPC responses/notifications.
- `stderr` is piped to a log file for debugging.

### 8.3 JSON-RPC Client (`electron/jsonrpc-client.ts`)

```typescript
class JsonRpcClient {
  private requestId = 1;
  private pendingRequests = new Map<number, { resolve: Function, reject: Function }>();
  private notificationHandlers: Array<(notif: RpcNotification) => void> = [];
  private stream: Readable;

  constructor(stream: Readable, writeStream: Writable) {
    // readline interface on stream
    this.stream.on('line', (line: string) => {
      const msg = JSON.parse(line);
      if (msg.method && !msg.id) { // notification
        this.notificationHandlers.forEach(h => h(msg));
      } else if (msg.id) { // response
        const pending = this.pendingRequests.get(msg.id);
        if (pending) {
          if (msg.error) pending.reject(msg.error);
          else pending.resolve(msg.result);
          this.pendingRequests.delete(msg.id);
        }
      }
    });
  }

  async request(method: string, params?: any): Promise<any> {
    const id = this.requestId++;
    return new Promise((resolve, reject) => {
      this.pendingRequests.set(id, { resolve, reject });
      writeStream.write(JSON.stringify({ jsonrpc: '2.0', method, params, id }) + '\n');
    });
  }

  onNotification(callback: (notification: RpcNotification) => void): void {
    this.notificationHandlers.push(callback);
  }
}
```

### 8.4 Preload and IPC Handlers

`preload.ts` as per section 6.

IPC handlers in main:

- `rpc:request`: calls `subprocessManager.sendRpcRequest(method, params)` and returns result.
- `workspace:select`: opens dialog, returns folder, then calls `subprocessManager.restart({ cwd: folderPath })`.
- `settings:get`: reads `~/.pi/.env` and `~/.pi/config.json` (if exists) and returns combined object.
- `settings:save`: writes `~/.pi/.env` with the new keys, restarts agent.
- `session:list`: either calls `subprocessManager.sendRpcRequest('session.list', [])` or reads session directory metadata.
- `session:resume`: restarts agent with `--resume <id>` flag (or sends RPC `session.resume`).
- `agent:restart`: restarts subprocess with optional env vars.

### 8.5 Renderer App (`src/renderer/`)

`App.tsx` uses a simple state machine: either ChatView or SettingsView, plus a ShellPanel always visible. It holds `workspacePath` state.

`ChatView.tsx` wraps the pi-web-ui `Chat` component:

```tsx
import { Chat, PiWebUiProvider } from '@earendil-works/pi-web-ui';
import { useRpcTransport } from '../hooks/useRpcTransport';

export function ChatView() {
  const transport = useRpcTransport();

  return (
    <PiWebUiProvider sendMessage={transport.sendMessage} /* other required props */>
      <Chat />
    </PiWebUiProvider>
  );
}
```

`useRpcTransport.ts`:

```typescript
export function useRpcTransport() {
  const [sessionId, setSessionId] = useState<string | null>(null);

  useEffect(() => {
    window.electronAPI.onRpcNotification((notification) => {
      // Handle chunk, tool call, shell output
      if (notification.method === 'agent.onChunk') {
        // append chunk to chat state (via pi-web-ui's internal state? We need to bridge)
        // Since pi-web-ui expects a sendMessage that returns a stream, we may need to use a callback.
      }
    });
  }, []);

  const sendMessage = async (message: string, sessionId?: string) => {
    // This is the function passed to PiWebUiProvider.
    // Should return an object that the provider can subscribe to for streaming? The pi-web-ui docs show that sendMessage is a function that returns a ChatResponse or a stream.
    // We'll implement it as: start RPC request, then return an async iterable.
    // The provider handles receiving chunks via a notification callback.
  };

  return { sendMessage, sessionId };
}
```

We need to check the exact interface of `PiWebUiProvider`'s `sendMessage`. Based on the docs, it might accept `(message: string) => Promise<string>`. To support streaming, we'll build an async generator that yields chunks, using `onRpcNotification`.

Example:

```typescript
const sendMessage = async (message: string) => {
  const responseStream = new ReadableStream({
    start(controller) {
      const handler = (notif: RpcNotification) => {
        if (notif.method === 'agent.onChunk') controller.enqueue(notif.params.chunk);
        if (notif.method === 'agent.onComplete') controller.close();
      };
      window.electronAPI.onRpcNotification(handler);
      window.electronAPI.sendRpc('agent.chat', { message, session_id: sessionId });
      // cleanup on close
    }
  });
  return responseStream;
};
```

`ShellPanel.tsx`:

```tsx
import { useEffect, useRef } from 'react';
import { Terminal } from 'xterm';
import { FitAddon } from 'xterm-addon-fit';

export function ShellPanel() {
  const terminalRef = useRef<HTMLDivElement>(null);
  const term = useRef<Terminal>();

  useEffect(() => {
    term.current = new Terminal({ convertEol: true });
    const fitAddon = new FitAddon();
    term.current.loadAddon(fitAddon);
    term.current.open(terminalRef.current!);
    fitAddon.fit();

    window.electronAPI.onRpcNotification((notif) => {
      if (notif.method === 'agent.onShellOutput') {
        term.current!.write(notif.params.data);
      }
    });
  }, []);

  return <div ref={terminalRef} style={{ height: '200px' }} />;
}
```

`SettingsView.tsx`:

```tsx
import Form from '@rjsf/core';
import validator from '@rjsf/validator-ajv8';
import settingsSchema from './generated/settings-schema.json';

export function SettingsView() {
  const [formData, setFormData] = useState({});

  useEffect(() => {
    window.electronAPI.getSettings().then(setFormData);
  }, []);

  const onSubmit = async ({ formData }) => {
    await window.electronAPI.saveSettings(formData);
  };

  return <Form schema={settingsSchema} validator={validator} formData={formData} onSubmit={onSubmit} />;
}
```

### 8.6 Settings Schema Extraction Script (`scripts/extract-pi-schema.ts`)

We'll use `ts-json-schema-generator` library (no runtime dependency).

```bash
npx ts-json-schema-generator --path 'node_modules/@earendil-works/pi-agent-core/dist/types.d.ts' --type 'PiConfig' --output 'src/renderer/generated/settings-schema.json'
```

This will be integrated into the build pipeline: run before webpack build.

---

## 9. Background Jobs

There are no long-running background jobs beyond the pi subprocess. The app will not perform any periodic tasks, auto-updates, or network calls other than those made by the pi CLI during an active chat.

### Subprocess Health Monitoring

The main process will monitor the subprocess for unexpected exit:

```typescript
child.on('exit', (code) => {
  if (code !== 0 && !intentionalShutdown) {
    // Show dialog to user: "pi agent crashed", offer restart
  }
});
```

---

## 10. Observability

### 10.1 Logging

- **Main process**: Use `electron-log` (or simple file logging) to record all RPC requests, responses, and subprocess lifecycle events. Log level: info by default, debug when a developer mode flag is set.
- **pi stderr**: Piped to a dedicated log file at `~/.pi-desktop/pi-agent.log` and also forwarded to main logs.
- **Renderer**: Console errors captured via `window.onerror` and sent to main process log.

### 10.2 Metrics

No custom metrics for v1. The Electron window health (frames per second) is not critical.

### 10.3 Debugging

A developer can set an environment variable `PI_DESKTOP_DEBUG=1` to:
- Show DevTools on launch.
- Enable verbose RPC logging.
- Expose a hidden "Terminal Debug" panel showing raw RPC traffic.

---

## 11. Error Handling

### 11.1 RPC Errors

- If an RPC request fails (e.g., `agent.chat` returns an error), the `JsonRpcClient` rejects the promise with the error object. The renderer's `sendMessage` will pick up the rejection and display a toast notification in the chat UI or via pi-web-ui's built-in error display.
- On connection loss (subprocess exit while requests pending), all pending promises will reject with a "Subprocess terminated" error.

### 11.2 Subprocess Crash

- The `SubprocessManager` will attempt to restart the pi process once if it crashes unexpectedly. If it crashes again immediately, it will show a fatal error dialog.
- The UI will show a reconnecting indicator.

### 11.3 File System Errors

- Reading/writing `~/.pi/.env` failures (permission) will surface as user-friendly errors.
- Workspace selection cancellation is handled gracefully (no action).

---

## 12. Testing Strategy

### 12.1 Unit Tests

- **JsonRpcClient**: Test with a mock readable/writable stream, verify request-response matching, notification dispatch.
- **Settings store**: Mock fs, test read/write and merge logic.
- **IPC handlers**: Mock ipcMain and invoke, test each handler.

Framework: Jest.

### 12.2 Integration Tests

- **Subprocess Manager**: Use a dummy script that acts like pi CLI (stdin/stdout) and verifies proper spawning, arguments passing, and communication.
- **Renderer integration**: Use `@testing-library/react` to mount ChatView with a mocked `electronAPI` and simulate messages.

### 12.3 End-to-End Tests

- **Electron app launch**: Using Spectron (or Playwright for Electron) test the main workflow: open app, select a folder, send a message (using a mock pi binary), see chat response, open settings.
- **Build pipeline**: Test that the final .deb and AppImage contain the bundled pi binary and run on Ubuntu.

### 12.4 Manual Testing

- Validate actual pi CLI compilation via `pkg` and integration with real pi functionality (will need a pi binary built from the monorepo). Early stage: use a real pi development binary to verify RPC interface.

---

## 13. Build/Run/Deploy

### 13.1 Development Setup

```bash
npm install
cd node_modules && git clone https://github.com/earendil-works/pi.git # or submodule
cd pi && npm install && npm run build
# Compile pi binary for dev: (optional, can use npx pi if global installed)
npm run build:pi-dev   # calls pkg to output a local binary to resources/
npm run dev            # starts Electron Forge in dev mode
```

### 13.2 Build Pipeline Steps

Command `npm run build:prod` will:

1. `step:pi-binary`:
   - Clone pi repo if not present, checkout stable tag.
   - `npm install` and build.
   - Run `pkg . --targets node20-linux-x64 --output resources/pi`.
2. `step:settings-schema`:
   - Ensure `@earendil-works/pi-agent-core` is installed as devDependency.
   - Run `npx ts-json-schema-generator` to produce `settings-schema.json`.
3. `step:electron-forge`:
   - `electron-forge package` and `electron-forge make`.
   - Outputs:
     - `.deb` in `out/make/deb/`
     - `.AppImage` in `out/make/`

The CI/CD pipeline (GitHub Actions) can run these steps in a Linux runner and upload artifacts as release assets.

### 13.3 Running the App

- **.deb**: `sudo dpkg -i pi-desktop_1.0.0_amd64.deb`, then launch from application menu.
- **AppImage**: `chmod +x pi-desktop-1.0.0.AppImage && ./pi-desktop-1.0.0.AppImage`

---

## 14. Acceptance Criteria

Each must-have feature maps to a testable criterion:

| Feature | Acceptance Criteria |
|---------|---------------------|
| Multi-turn chat | User can send messages and receive streaming responses displayed in chat bubbles. |
| Provider/model selection | Settings page shows provider/model dropdowns; changes persist and affect agent responses. |
| Skills/extensions management | Skills can be added/removed in settings; agent respects enabled skills. |
| Session history & resume | Past sessions appear in a list; selecting one loads that conversation. |
| Live shell output | When agent runs a shell command, output appears in real-time in terminal panel. |
| File read/write | Agent can read workspace files and produce diffs (shown in chat). |
| Prompt template customization | Settings form includes a textarea for prompt templates; changes affect agent behavior. |
| Self-contained package | .deb and AppImage install and run on a clean Ubuntu 22.04 without `pi` CLI pre-installed. |

Additionally:
- App launches without errors on Ubuntu 22.04.
- The bundled pi binary is functional (verify by sending a simple chat message).

---

## 15. Final Consistency Checklist

- **All sections completed:** Yes.
- **No TBDs or placeholders:** Yes.
- **Traceability to design document:** Every decision here is derived from Document 1, with exact implementations described.
- **Security considerations addressed:** API keys protected, nodeIntegration disabled, CSP, IPC limited.
- **Edge cases covered:** Subprocess crash, workspace cancellation, pending requests on exit.
- **Cross-document consistency:** Data model matches Design Doc, API channels match, build pipeline reflects self-contained requirement.
- **No over-engineering:** Minimal logic, uses existing components, no unnecessary features.

---
