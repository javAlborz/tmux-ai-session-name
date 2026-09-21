import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import status from "../pi/tmux-session-status.ts";

function setup(hasUI = true, helper) {
  const handlers = new Map();
  let name = "Analysis";
  const titles = [];
  const ui = {setTitle: value => titles.push(value), select: async () => "yes",
    confirm: async () => true, input: async () => "answer", custom: async () => {}, editor: async () => "text"};
  const ctx = {hasUI, mode: hasUI ? "tui" : "print", cwd: "/workspace", ui,
    sessionManager: {getSessionId: () => "12345678-1234-1234-1234-123456789abc"}};
  status({getSessionName: () => name, on: (event, handler) => handlers.set(event, handler), registerTool() {}}, helper);
  return {ctx, titles, emit: event => handlers.get(event)({}, ctx), name: value => {name = value;}};
}

test("file transport covers names, dialogs, completion and headless mode", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "pi-status-"));
  const file = path.join(dir, "status.json");
  const old = process.env.PI_TMUX_STATUS_FILE;
  process.env.PI_TMUX_STATUS_FILE = file;
  const run = setup();
  const read = () => JSON.parse(readFileSync(file));
  try {
    let finish;
    run.ctx.ui.select = () => new Promise(resolve => {finish = resolve;});
    run.ctx.ui.confirm = async () => {throw Error("cancelled");};
    run.emit("session_start");
    run.emit("agent_start");
    assert.equal(read().state, "working");
    const dialog = run.ctx.ui.select();
    assert.equal(read().state, "waiting");
    await assert.rejects(run.ctx.ui.confirm(), /cancelled/);
    assert.equal(read().state, "waiting", "nested dialog must retain waiting");
    finish("yes"); await dialog;
    assert.equal(read().state, "working");
    run.name("unsafe\x1b#name");
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(read().name, "unsafename");
    run.emit("agent_end"); assert.equal(read().state, "done");
    run.emit("input"); assert.equal(read().state, "idle");
    run.emit("session_shutdown"); assert.equal(read().state, "closed");
    rmSync(file);
    const headless = setup(false);
    headless.emit("session_start"); headless.emit("agent_start");
    assert.equal(existsSync(file), false); assert.deepEqual(headless.titles, []);
  } finally {
    run.emit("session_shutdown");
    if (old === undefined) delete process.env.PI_TMUX_STATUS_FILE; else process.env.PI_TMUX_STATUS_FILE = old;
    rmSync(dir, {recursive: true});
  }
});

test("direct transport updates only its pane and preserves window styles", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "pi-direct-"));
  const socket = path.join(dir, "socket");
  const call = (...args) => execFileSync("tmux", ["-S", socket, ...args], {encoding: "utf8"}).trim();
  const old = {TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE, PI_TMUX_STATUS_FILE: process.env.PI_TMUX_STATUS_FILE};
  delete process.env.PI_TMUX_STATUS_FILE;
  let run;
  try {
    call("-f", "/dev/null", "new-session", "-d", "-s", "test");
    process.env.TMUX = socket + ",0,0";
    process.env.TMUX_PANE = call("display-message", "-p", "#{pane_id}");
    call("set-option", "-w", "window-status-style", "fg=green");
    run = setup(); run.emit("session_start"); run.emit("agent_start");
    assert.equal(call("show-option", "-pqv", "@ai-pane-working"), "1");
    run.emit("agent_end");
    assert.equal(call("show-option", "-pqv", "@ai-pane-unread"), "1");
    run.emit("input");
    assert.equal(call("show-option", "-pqv", "@ai-pane-unread"), "0");
    assert.equal(call("show-option", "-wqv", "window-status-style"), "fg=green");
  } finally {
    run?.emit("session_shutdown");
    call("kill-server");
    for (const [key,value] of Object.entries(old)) {if (value === undefined) delete process.env[key]; else process.env[key] = value;}
    rmSync(dir, {recursive: true});
  }
});

test("trusted helper delivery is awaited and serialized by lifecycle events", async () => {
  const old = {TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE};
  process.env.TMUX = "/tmp/fixture,0,0";
  process.env.TMUX_PANE = "%1";
  const calls = [];
  const run = setup(true, async name => {
    await new Promise(resolve => setTimeout(resolve, 10));
    calls.push(name);
  });
  try {
    await run.emit("session_start");
    await run.emit("agent_start");
    await run.emit("agent_end");
    assert.deepEqual(calls, ["ai-unread-clear", "ai-unread-clear", "ai-unread-set"]);
    await run.emit("input");
    assert.equal(calls.at(-1), "ai-unread-clear");
  } finally {
    await run.emit("session_shutdown");
    for (const [key,value] of Object.entries(old)) {if (value === undefined) delete process.env[key]; else process.env[key] = value;}
  }
});
