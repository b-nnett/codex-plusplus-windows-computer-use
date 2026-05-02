"use strict";

const STYLE_ID = "codexpp-windows-computer-use-style";

/** @type {import("@codex-plusplus/sdk").Tweak} */
module.exports = {
  start(api) {
    if (api.process === "main") {
      const daemon = startBridgeDaemon(api);
      this._state = { process: "main", daemon };
      api.log.info("[windows-computer-use] main service active", {
        platform: process.platform,
        bridgeDaemonPid: daemon?.pid || null,
      });
      return;
    }

    startRenderer(this, api);
  },

  stop() {
    const state = this._state;
    if (!state) return;
    state.pageHandle?.unregister?.();
    state.style?.remove();
    if (state.daemon && state.daemon.exitCode == null) {
      state.daemon.kill();
    }
    this._state = null;
  },
};

function startBridgeDaemon(api) {
  if (process.platform !== "win32") return null;
  if (process.env.WINDOWS_COMPUTER_USE_APP_LAUNCH_WARMUP === "0") return null;
  if (typeof require !== "function") return null;
  const path = require("path");
  const { spawn } = require("child_process");
  const bridgeDaemon = path.join(__dirname, "scripts", "bridge-daemon.js");
  const node = process.env.WINDOWS_COMPUTER_USE_NODE || "node.exe";
  try {
    const child = spawn(node, [bridgeDaemon], {
      cwd: __dirname,
      env: process.env,
      stdio: "ignore",
      windowsHide: true,
      detached: false,
    });
    child.on("error", (error) => {
      api.log.warn("[windows-computer-use] bridge daemon failed to start", String(error));
    });
    child.on("exit", (code, signal) => {
      if (code === 0) return;
      api.log.warn("[windows-computer-use] bridge daemon exited", { code, signal });
    });
    return child;
  } catch (error) {
    api.log.warn("[windows-computer-use] bridge daemon spawn failed", String(error));
    return null;
  }
}

function startRenderer(self, api) {
  const state = {
    process: "renderer",
    api,
    style: installStyle(),
    pageHandle: null,
  };
  self._state = state;

  if (typeof api.settings?.registerPage === "function") {
    state.pageHandle = api.settings.registerPage({
      id: "main",
      title: "Windows Computer Use",
      description: "Draft Windows desktop automation MCP tools.",
      iconSvg: computerIconSvg(),
      render: (root) => renderSettings(root, state),
    });
  } else {
    api.log.warn("[windows-computer-use] settings.registerPage unavailable");
  }

  api.log.info("[windows-computer-use] renderer active");
}

function installStyle() {
  document.getElementById(STYLE_ID)?.remove();
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
    [data-wcu-settings] {
      display: flex;
      flex-direction: column;
      gap: 12px;
      max-width: 760px;
    }

    [data-wcu-card] {
      border: 1px solid var(--color-token-border, rgba(127,127,127,.22));
      border-radius: 8px;
      background: var(--color-background-panel, var(--color-token-bg-fog, Canvas));
      overflow: hidden;
    }

    [data-wcu-row] {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      padding: 12px;
      border-bottom: 1px solid var(--color-token-border, rgba(127,127,127,.16));
    }

    [data-wcu-row]:last-child {
      border-bottom: 0;
    }

    [data-wcu-title] {
      font-size: 13px;
      color: var(--color-token-text-primary, currentColor);
    }

    [data-wcu-desc] {
      margin-top: 3px;
      font-size: 12px;
      color: var(--color-token-text-secondary, color-mix(in srgb, currentColor 68%, transparent));
      line-height: 1.4;
    }

    [data-wcu-code] {
      margin: 0;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      font-size: 12px;
      line-height: 1.5;
      color: var(--color-token-text-primary, currentColor);
      background: var(--color-token-bg-primary, rgba(127,127,127,.08));
      padding: 12px;
      border-radius: 8px;
    }
  `;
  document.head.appendChild(style);
  return style;
}

function renderSettings(root) {
  const wrap = document.createElement("div");
  wrap.dataset.wcuSettings = "true";

  const intro = document.createElement("div");
  intro.dataset.wcuCard = "true";
  intro.appendChild(row("Status", "Windows-only Computer Use MCP server using a local PowerShell and UI Automation bridge."));
  intro.appendChild(row("Setup", "Install and run this tweak on Windows. Use npm run setup:windows to check UI Automation, screenshots, input, overlay assets, execution policy, and elevation caveats."));
  intro.appendChild(row("Tool Surface", "Matches macOS Computer Use names where possible: list_apps, get_app_state, click, scroll, drag, press_key, type_text, set_value."));
  intro.appendChild(row("Target Dumps", "get_app_state and dump_app_targets include flattened controls with button positions, UIA patterns, action hints, and screen/window-relative centers."));
  intro.appendChild(row("Instruction Layer", "AppInstructions/*.md mirrors the readable app-specific guidance from OpenAI's macOS bundle."));
  wrap.appendChild(intro);

  const code = document.createElement("pre");
  code.dataset.wcuCode = "true";
code.textContent = `[mcp_servers.windows-computer-use]
command = "node"
args = ["C:\\\\Users\\\\YOU\\\\AppData\\\\Roaming\\\\codex-plusplus\\\\tweaks\\\\co.bennett.windows-computer-use\\\\mcp-server.js"]`;
  wrap.appendChild(code);

  root.appendChild(wrap);
}

function row(title, desc) {
  const item = document.createElement("div");
  item.dataset.wcuRow = "true";
  const text = document.createElement("div");
  const h = document.createElement("div");
  h.dataset.wcuTitle = "true";
  h.textContent = title;
  const d = document.createElement("div");
  d.dataset.wcuDesc = "true";
  d.textContent = desc;
  text.append(h, d);
  item.appendChild(text);
  return item;
}

function computerIconSvg() {
  return `
    <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden="true">
      <path d="M3.5 4.5A1.5 1.5 0 0 1 5 3h10a1.5 1.5 0 0 1 1.5 1.5v7A1.5 1.5 0 0 1 15 13H5a1.5 1.5 0 0 1-1.5-1.5v-7Z" stroke="currentColor" stroke-width="1.4"/>
      <path d="M7.5 16.5h5M10 13v3.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
    </svg>
  `;
}
