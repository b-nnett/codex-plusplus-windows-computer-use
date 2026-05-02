#!/usr/bin/env node
"use strict";

const net = require("net");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const WINDOWS_BRIDGE = path.join(ROOT, "scripts", "windows-bridge.ps1");
const PIPE_NAME = process.env.WINDOWS_COMPUTER_USE_BRIDGE_PIPE || "\\\\.\\pipe\\codex-plusplus-windows-computer-use";

let bridgeProcess = null;
let bridgeBuffer = "";
let bridgeNextId = 1;
const bridgePending = new Map();

function startBridge() {
  if (bridgeProcess && !bridgeProcess.killed && bridgeProcess.exitCode == null) {
    return bridgeProcess;
  }

  bridgeBuffer = "";
  bridgeProcess = spawn(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      WINDOWS_BRIDGE,
      "-Server",
    ],
    { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] },
  );
  bridgeProcess.stdout.setEncoding("utf8");
  bridgeProcess.stdout.on("data", handleBridgeStdout);
  bridgeProcess.stderr.on("data", (chunk) => {
    if (process.env.WINDOWS_COMPUTER_USE_BRIDGE_DEBUG === "1") {
      process.stderr.write(chunk);
    }
  });
  bridgeProcess.on("exit", (code, signal) => {
    const error = new Error(`Windows bridge exited (${signal || (code ?? "unknown")})`);
    for (const [id, pending] of bridgePending) {
      clearTimeout(pending.timeout);
      pending.reject(error);
      bridgePending.delete(id);
    }
    bridgeProcess = null;
  });
  return bridgeProcess;
}

function callBridge(command, payload) {
  const proc = startBridge();
  const id = bridgeNextId++;
  proc.stdin.write(`${JSON.stringify({ id, command, payload: payload || {} })}\n`);

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      bridgePending.delete(id);
      reject(new Error(`Timed out waiting for Windows bridge daemon command: ${command}`));
    }, Math.max(15000, Number(process.env.WINDOWS_COMPUTER_USE_BRIDGE_TIMEOUT_MS || 45000)));
    bridgePending.set(id, { resolve, reject, timeout });
  });
}

function handleBridgeStdout(chunk) {
  bridgeBuffer += chunk;
  let newline;
  while ((newline = bridgeBuffer.indexOf("\n")) >= 0) {
    const line = bridgeBuffer.slice(0, newline).trim();
    bridgeBuffer = bridgeBuffer.slice(newline + 1);
    if (!line) continue;

    const message = parseJson(line);
    if (message?.type === "ready") continue;
    const pending = bridgePending.get(message?.id);
    if (!pending) continue;
    bridgePending.delete(message.id);
    clearTimeout(pending.timeout);
    if (message.ok) {
      pending.resolve(message.result);
    } else {
      pending.reject(new Error(message.error || "Windows bridge command failed"));
    }
  }
}

function handleSocket(socket) {
  socket.setEncoding("utf8");
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      void handleSocketLine(socket, line);
    }
  });
}

async function handleSocketLine(socket, line) {
  const request = parseJson(line);
  const id = request?.id;
  try {
    if (!request || typeof request.command !== "string") {
      throw new Error("Invalid bridge daemon request.");
    }
    const result = await callBridge(request.command, request.payload || {});
    socket.write(`${JSON.stringify({ id, ok: true, result })}\n`);
  } catch (error) {
    socket.write(`${JSON.stringify({
      id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    })}\n`);
  }
}

function parseJson(raw) {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function shutdown() {
  try {
    server.close();
  } catch {}
  if (bridgeProcess && bridgeProcess.exitCode == null) {
    bridgeProcess.kill();
  }
}

const server = net.createServer(handleSocket);
server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    process.exit(0);
  }
  console.error(error);
  process.exit(1);
});

server.listen(PIPE_NAME, () => {
  void callBridge("warmup", {}).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
  });
});

process.on("SIGTERM", () => {
  shutdown();
  process.exit(0);
});
process.on("SIGINT", () => {
  shutdown();
  process.exit(0);
});
process.on("exit", shutdown);
