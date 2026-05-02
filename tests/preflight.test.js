"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const SERVER = path.join(ROOT, "mcp-server.js");

let nextId = 1000;

async function main() {
  await check("manifest and package wiring", () => {
    const manifest = readJson("manifest.json");
    const pkg = readJson("package.json");
    assert.equal(manifest.id, "co.bennett.windows-computer-use");
    assert.equal(manifest.main, "index.js");
    assert.deepEqual(manifest.mcp, { command: "node", args: ["mcp-server.js"] });
    assert.equal(pkg.scripts["setup:windows"], "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/setup-windows.ps1");
    assert.equal(pkg.scripts["install:codexpp:windows"], "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-codexpp-windows.ps1");
    assert.equal(pkg.scripts["smoke:windows"], "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/smoke-test-windows.ps1");
    assert.ok(pkg.scripts["codex-computer:windows"].includes("codex-computer-prompt-test-windows.ps1"));
    assert.equal(pkg.scripts["visual-task:windows"], "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run-visual-test-task-windows.ps1");
    assert.equal(pkg.scripts["visual:windows"], "powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/visual-test-windows.ps1");
    for (const file of [manifest.main, manifest.mcp.args[0], "scripts/windows-bridge.ps1", "scripts/fake-cursor-overlay.ps1", "scripts/codex-computer-prompt-test-windows.ps1"]) {
      assert.ok(fs.existsSync(path.join(ROOT, file)), `missing ${file}`);
    }
    const codexPromptTest = fs.readFileSync(path.join(ROOT, "scripts", "codex-computer-prompt-test-windows.ps1"), "utf8");
    assert.ok(codexPromptTest.includes("using visible mouse/cursor movement only"));
    assert.ok(codexPromptTest.includes("do not use press_key, type_text, keyboard shortcuts, or direct text entry"));
    assert.ok(codexPromptTest.includes("move_cursor to each button"));
  });

  await check("@computer plugin wrapper is bundled", () => {
    const plugin = readJson(path.join("codex-plugin", ".codex-plugin", "plugin.json"));
    assert.equal(plugin.name, "computer");
    assert.equal(plugin.skills, "./skills/");
    assert.ok(plugin.description.includes("@computer"));
    assert.ok(plugin.interface.displayName.includes("Computer"));
    assert.equal(plugin.interface.composerIcon, "./assets/app-icon.png");
    assert.equal(plugin.interface.logo, "./assets/app-icon.png");
    assert.ok(fs.existsSync(path.join(ROOT, "codex-plugin", "skills", "computer", "SKILL.md")));
    assert.ok(fs.existsSync(path.join(ROOT, "codex-plugin", "assets", "app-icon.png")));
    assert.ok(fs.existsSync(path.join(ROOT, "codex-plugin", "assets", "cursor.png")));
    const skill = fs.readFileSync(path.join(ROOT, "codex-plugin", "skills", "computer", "SKILL.md"), "utf8");
    assert.ok(skill.includes("get_app_state"));
    assert.ok(skill.includes("screenshot_window"));
    assert.ok(skill.includes("Do not use SSH"));
  });

  await check("bundled app instructions cover Windows smoke apps", () => {
    const instructionDir = path.join(ROOT, "AppInstructions");
    const files = fs.readdirSync(instructionDir).filter((name) => name.endsWith(".md")).sort();
    for (const expected of [
      "Calculator.md",
      "Edge.md",
      "File Explorer.md",
      "Notepad.md",
      "Paint.md",
      "PowerShell.md",
      "Settings.md",
      "Task Manager.md",
      "VS Code.md",
      "Visual Studio.md",
      "Windows Terminal.md",
    ]) {
      assert.ok(files.includes(expected), `missing ${expected}`);
    }
    for (const file of files) {
      const text = fs.readFileSync(path.join(instructionDir, file), "utf8");
      assert.ok(text.includes("## "), `${file} missing heading`);
      assert.ok(/Localization|AutomationId|control type|UI Automation/i.test(text), `${file} missing localization/UIA guidance`);
    }
  });

  await check("macOS cursor assets are present", () => {
    const assetDir = path.join(ROOT, "assets", "macos-computer-use");
    const lensDir = path.join(assetDir, "LensSequence");
    const frames = fs.readdirSync(lensDir).filter((name) => /^Lens_frame_\d\d\.png$/.test(name)).sort();
    assert.equal(frames.length, 45);
    assert.ok(fs.existsSync(path.join(assetDir, "SoftwareCursor.png")));
    assert.ok(fs.existsSync(path.join(assetDir, "cursor.png")));
    assert.ok(fs.existsSync(path.join(assetDir, "FAKE_CURSOR_UI_DUMP.md")));
  });

  await check("PowerShell bridge contains reliability entry points", () => {
    const bridge = fs.readFileSync(path.join(ROOT, "scripts", "windows-bridge.ps1"), "utf8");
    for (const snippet of [
      "function Get-SetupCheck",
      "function Resolve-InputPoint",
      "coordinateSpace",
      "window-relative-pixels",
      "screenOrigin",
      "PayloadBase64",
      "WCU_PAYLOAD_BASE64",
      "Start-BridgeServer",
      "[Console]::In.ReadLine()",
      "Invoke-BridgeCommand",
      "\"setup-check\"",
      "function Dump-AppTargets",
      "\"dump-app-targets\"",
      "function Get-RecommendedTool",
      "function Get-AppDisplay",
      "function Save-AppIcon",
      "ExtractAssociatedIcon",
      "appDisplay",
      "function Get-CompactAccessibilityTree",
      "function Get-CompactTargets",
      "includeRawAccessibilityTree",
      "compact-lines",
      "timeoutMs",
      "CopyFromScreen",
      "GetCursorPos",
      "PostMessage",
      "WindowFromPoint",
      "GetForegroundWindow",
      "Focus-AppStrict",
      "New-ActionPresentation",
      "presentation",
      "verifiedBeforeSend",
      "function Get-ShowFakeCursor",
      "function Set-FakeCursorPressed",
      "hasPosition",
      "AutomationElement",
      "RawViewWalker",
      "synthetic:browser-address-bar",
      "synthetic:file-explorer-address-bar",
      "synthetic:file-explorer-search",
      "includeRawViewTargets",
      "includeSyntheticTargets",
    ]) {
      assert.ok(bridge.includes(snippet), `bridge missing ${snippet}`);
    }
    assert.ok(bridge.includes("$state.cursor.visible = $true"));
    assert.ok(bridge.includes("inferredCoordinateSpace"));
    assert.ok(bridge.includes("movedRealCursor = $false"));
    assert.ok(!bridge.includes("SetCursorPos"));
    assert.ok(!bridge.includes("mouse_event"));

    const server = fs.readFileSync(path.join(ROOT, "mcp-server.js"), "utf8");
    assert.ok(server.includes("structuredContent"));
    assert.ok(server.includes("Focus verified before send"));
    assert.ok(server.includes("listAppsFast"));
    assert.ok(server.includes("tasklist.exe"));
    assert.ok(server.includes("runPersistentBridge"));
    assert.ok(server.includes("ensureBridgeProcess"));
    assert.ok(server.includes("runDaemonBridge"));
    assert.ok(server.includes("WINDOWS_COMPUTER_USE_BRIDGE_DAEMON"));
    assert.ok(server.includes("WINDOWS_COMPUTER_USE_PERSISTENT_BRIDGE"));
    assert.ok(server.includes("startComputerUse"));
    assert.ok(server.includes("warmBridgeInBackground"));
    assert.ok(server.includes("Starting Computer Use"));
    assert.ok(bridge.includes('"warmup"'));

    const daemon = fs.readFileSync(path.join(ROOT, "scripts", "bridge-daemon.js"), "utf8");
    assert.ok(daemon.includes("net.createServer"));
    assert.ok(daemon.includes("windows-bridge.ps1"));
    assert.ok(daemon.includes("callBridge(\"warmup\""));
    assert.ok(fs.existsSync(path.join(ROOT, "scripts", "daemon-bridge-test-windows.ps1")));
    assert.ok(fs.existsSync(path.join(ROOT, "scripts", "browser-target-dump-test-windows.ps1")));
    assert.ok(fs.existsSync(path.join(ROOT, "scripts", "target-border-visual-test-windows.ps1")));

    const entry = fs.readFileSync(path.join(ROOT, "index.js"), "utf8");
    assert.ok(entry.includes("startBridgeDaemon"));
    assert.ok(entry.includes("WINDOWS_COMPUTER_USE_APP_LAUNCH_WARMUP"));
  });

  await check("layered cursor overlay uses per-pixel alpha window", () => {
    const overlay = fs.readFileSync(path.join(ROOT, "scripts", "fake-cursor-overlay.ps1"), "utf8");
    for (const snippet of [
      "UpdateLayeredWindow",
      "Format32bppPArgb",
      "WS_EX_TRANSPARENT",
      "WS_EX_NOACTIVATE",
      "WS_EX_TOOLWINDOW",
      "AC_SRC_ALPHA",
      "VirtualScreen",
      "Render-CursorFrame",
    ]) {
      assert.ok(overlay.includes(snippet), `overlay missing ${snippet}`);
    }
  });

  await check("MCP supports Content-Length framing", async () => {
    const client = startContentLengthClient();
    try {
      const init = await client.call("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "preflight", version: "0.0.0" },
      });
      assert.equal(init.serverInfo.name, "windows-computer-use");
      const tools = await client.call("tools/list", {});
      const names = tools.tools.map((tool) => tool.name);
      assert.ok(names.includes("windows_computer_use_setup_check"));
      assert.ok(names.includes("start_computer_use"));
      assert.ok(names.includes("dump_app_targets"));
      const server = fs.readFileSync(path.join(ROOT, "mcp-server.js"), "utf8");
      assert.ok(server.includes("withAppSpecificInstructions"));
      assert.ok(server.includes("appSpecificInstructions"));
    } finally {
      client.stop();
    }
  });
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(path.join(ROOT, file), "utf8"));
}

function startContentLengthClient() {
  const proc = spawn(process.execPath, [SERVER], {
    cwd: ROOT,
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, WINDOWS_COMPUTER_USE_DRY_RUN: "1" },
  });
  proc.stderr.on("data", (chunk) => process.stderr.write(chunk));

  let buffer = Buffer.alloc(0);
  const pending = new Map();

  proc.stdout.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    drain();
  });

  function drain() {
    while (buffer.length > 0) {
      const text = buffer.toString("utf8");
      if (!/^Content-Length:/i.test(text)) {
        const newline = text.indexOf("\n");
        if (newline < 0) return;
        const line = text.slice(0, newline).trim();
        buffer = Buffer.from(text.slice(newline + 1), "utf8");
        if (line) handle(JSON.parse(line));
        continue;
      }

      const headerEnd = text.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = text.slice(0, headerEnd);
      const length = Number(header.match(/Content-Length:\s*(\d+)/i)?.[1]);
      assert.ok(Number.isFinite(length), "invalid Content-Length response");
      const bodyStart = Buffer.byteLength(text.slice(0, headerEnd + 4));
      if (buffer.length < bodyStart + length) return;
      const body = buffer.slice(bodyStart, bodyStart + length).toString("utf8");
      buffer = buffer.slice(bodyStart + length);
      handle(JSON.parse(body));
    }
  }

  function handle(message) {
    const resolver = pending.get(message.id);
    if (!resolver) return;
    pending.delete(message.id);
    if (message.error) resolver.reject(new Error(message.error.message));
    else resolver.resolve(message.result);
  }

  return {
    call(method, params) {
      const id = nextId++;
      const body = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      proc.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        setTimeout(() => {
          if (!pending.has(id)) return;
          pending.delete(id);
          reject(new Error(`Timed out waiting for ${method}`));
        }, 2000);
      });
    },
    stop() {
      proc.kill();
    },
  };
}

async function check(name, fn) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
