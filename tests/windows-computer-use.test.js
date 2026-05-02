"use strict";

const assert = require("assert");
const path = require("path");
const { spawn } = require("child_process");

const SERVER = path.resolve(__dirname, "..", "mcp-server.js");

let nextId = 1;

async function main() {
  await check("initialize", async () => {
    const client = startServer();
    try {
      const init = await client.call("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test", version: "0.0.0" },
      });
      assert.equal(init.serverInfo.name, "windows-computer-use");
      assert.equal(init.capabilities.tools != null, true);
    } finally {
      client.stop();
    }
  });

  await check("tools/list includes Computer Use-compatible tools", async () => {
    const client = startServer();
    try {
      await client.call("initialize", {});
      const result = await client.call("tools/list", {});
      const names = result.tools.map((tool) => tool.name);
      for (const name of [
        "windows_computer_use_status",
        "start_computer_use",
        "windows_computer_use_setup_check",
        "app_instruction_catalog",
        "list_apps",
        "get_app_state",
        "dump_app_targets",
        "screenshot_window",
        "click",
        "perform_secondary_action",
        "scroll",
        "drag",
        "press_key",
        "type_text",
        "set_value",
        "move_cursor",
        "show_fake_cursor",
        "hide_fake_cursor",
      ]) {
        assert.ok(names.includes(name), `missing ${name}`);
      }
    } finally {
      client.stop();
    }
  });

  await check("status and instructions are callable on any platform", async () => {
    const client = startServer();
    try {
      await client.call("initialize", {});
      const status = toolJson(await client.call("tools/call", {
        name: "windows_computer_use_status",
        arguments: {},
      }));
      assert.equal(status.name, "windows-computer-use");
      assert.equal(status.implementation, "powershell-uia-draft");
      assert.ok(status.capabilities.includes("Windows UI Automation tree dump"));
      assert.ok(status.capabilities.includes("setup diagnostics"));
      assert.ok(status.capabilities.includes("flattened actionable element dumps with positions"));
      assert.ok(status.capabilities.includes("persistent virtual cursor overlay using the extracted macOS Computer Use cursor asset"));
      assert.ok(status.capabilities.includes("UIA/window-message click dispatch without moving the user's cursor"));

      const starting = await client.call("tools/call", {
        name: "start_computer_use",
        arguments: { reason: "test" },
      });
      assert.equal(starting.content[0].text.includes("Starting Computer Use"), true);
      assert.equal(starting._meta.presentation.appName, "Computer Use");

      const catalog = toolJson(await client.call("tools/call", {
        name: "app_instruction_catalog",
        arguments: {},
      }));
      assert.ok(catalog.files.some((file) => file.name === "Windows Terminal.md"));
      assert.ok(catalog.files.some((file) => file.name === "Calculator.md"));
      assert.ok(catalog.files.some((file) => file.name === "File Explorer.md"));
      assert.ok(catalog.files.some((file) => file.name === "Notepad.md"));

      const setup = toolJson(await client.call("tools/call", {
        name: "windows_computer_use_setup_check",
        arguments: {},
      }));
      assert.equal(setup.toolName, "windows_computer_use_setup_check");
      assert.equal(setup.dryRun, true);
    } finally {
      client.stop();
    }
  });

  await check("fake cursor tools support dry run", async () => {
    const client = startServer();
    try {
      await client.call("initialize", {});
      const shown = toolJson(await client.call("tools/call", {
        name: "show_fake_cursor",
        arguments: { x: 120, y: 80 },
      }));
      assert.equal(shown.toolName, "show_fake_cursor");
      assert.equal(shown.dryRun, true);

      const moved = toolJson(await client.call("tools/call", {
        name: "move_cursor",
        arguments: { x: 140, y: 100, showFakeCursor: true },
      }));
      assert.equal(moved.toolName, "move_cursor");
      assert.equal(moved.args.showFakeCursor, true);
    } finally {
      client.stop();
    }
  });
}

function startServer() {
  const proc = spawn(process.execPath, [SERVER], {
    cwd: path.dirname(SERVER),
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, WINDOWS_COMPUTER_USE_DRY_RUN: "1" },
  });
  proc.stderr.on("data", (chunk) => process.stderr.write(chunk));

  let buffer = "";
  const pending = new Map();
  proc.stdout.setEncoding("utf8");
  proc.stdout.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      const resolver = pending.get(message.id);
      if (!resolver) continue;
      pending.delete(message.id);
      if (message.error) resolver.reject(new Error(message.error.message));
      else resolver.resolve(message.result);
    }
  });

  return {
    call(method, params) {
      const id = nextId++;
      proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
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

function toolJson(result) {
  assert.equal(Array.isArray(result.content), true);
  return JSON.parse(result.content[0].text);
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
