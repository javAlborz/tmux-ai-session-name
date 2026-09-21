import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// One lifecycle implementation, with file delivery for sandboxes and direct
// delivery through the shared renderer for ordinary host sessions.
export default function tmuxSessionStatus(pi: ExtensionAPI, helperOverride?: (name: string) => Promise<void>) {
	let state = "idle";
	let revision = 0;
	let dialogs = 0;
	let context: ExtensionContext | undefined;
	let timer: ReturnType<typeof setInterval> | undefined;
	let identity = "";
	const wrapped = new WeakSet<ExtensionUIContext>();
	const statusFile = process.env.PI_TMUX_STATUS_FILE;
	const clean = (value: string) => value.replace(/[\x00-\x1f\x7f-\x9f#]/g, "").slice(0, 200);

	let delivered = "";
	let delivery = Promise.resolve();
	function publish(ctx: ExtensionContext) {
		if (!ctx.hasUI) return;
		context = ctx;
		identity = JSON.stringify([ctx.sessionManager.getSessionId(), pi.getSessionName()]);
		const name = clean(pi.getSessionName() || "");
		const cwd = clean(path.basename(ctx.cwd));
		const title = name ? `π - ${name} - ${cwd}` : `π - ${cwd}`;
		ctx.ui.setTitle(dialogs ? `Action Required · ${title}` : state === "working" ? `⠋ ${title}` : title);
        const snapshot = { id: ctx.sessionManager.getSessionId(), name,
            state: dialogs ? "waiting" : state, revision: ++revision };
        if (!statusFile) {
            if (!process.env.TMUX || !process.env.TMUX_PANE) return;
            const current = JSON.stringify([snapshot.id, snapshot.state]);
            if (delivered === current) return;
            delivered = current;
            if (helperOverride) {
                const name = snapshot.state === "waiting" ? "ai-waiting-set" :
                    snapshot.state === "done" ? "ai-unread-set" : "ai-unread-clear";
                delivery = delivery.then(() => helperOverride(name)).catch(() => {});
                return;
            }
            const helper = fileURLToPath(new URL("../status/ai-status.py", import.meta.url));
            const event = snapshot.state === "working" ? "start" : snapshot.state === "waiting" ? "waiting" :
                snapshot.state === "done" ? "stop" : "idle";
            try {
                spawnSync("python3", [helper, event], { input: "{}", timeout: 2000, stdio: ["pipe", "ignore", "ignore"] });
            } catch { /* Terminal integration must remain optional. */ }
            return;
        }
		try {
			writeFileSync(statusFile, JSON.stringify(snapshot), { mode: 0o600 });
		} catch {
			// Status delivery must never interrupt a session.
		}
	}

	function wrapDialogs(ui: ExtensionUIContext) {
		if (wrapped.has(ui)) return;
		wrapped.add(ui);
		async function during<T>(action: () => Promise<T>): Promise<T> {
			dialogs++;
			if (context) publish(context);
			try {
				return await action();
			} finally {
				dialogs--;
				if (context) publish(context);
			}
		}
		const select = ui.select.bind(ui);
		const confirm = ui.confirm.bind(ui);
		const input = ui.input.bind(ui);
		const custom = ui.custom.bind(ui);
		const editor = ui.editor.bind(ui);
		ui.select = (...args) => during(() => select(...args));
		ui.confirm = (...args) => during(() => confirm(...args));
		ui.input = (...args) => during(() => input(...args));
		ui.custom = (factory, options) => during(() => custom(factory, options));
		ui.editor = (...args) => during(() => editor(...args));
	}

	pi.on("session_start", (_event, ctx) => {
		state = "idle";
		if (ctx.hasUI) wrapDialogs(ctx.ui);
		publish(ctx);
		if (ctx.hasUI && !timer) {
			timer = setInterval(() => {
				if (context && identity !== JSON.stringify([context.sessionManager.getSessionId(), pi.getSessionName()])) {
					publish(context);
				}
			}, 250);
			timer.unref();
		}
	});
	pi.on("input", (_event, ctx) => { state = "idle"; publish(ctx); });
	pi.on("agent_start", (_event, ctx) => { state = "working"; publish(ctx); });
	pi.on("agent_end", (_event, ctx) => { state = "done"; publish(ctx); });
	pi.on("session_shutdown", (_event, ctx) => {
		state = "closed"; publish(ctx);
		if (timer) clearInterval(timer);
		timer = undefined;
	});

	pi.registerTool({
		name: "ask_user",
		label: "Ask user",
		description: "Ask the user for information required to continue. Use only when work is blocked on their answer.",
		parameters: Type.Object({
			question: Type.String(),
			options: Type.Optional(Type.Array(Type.String())),
		}),
		async execute(_id, params, _signal, _update, ctx) {
			if (ctx.mode !== "tui") {
				return { content: [{ type: "text", text: "User interaction is unavailable outside interactive mode." }], details: {} };
			}
			const choices = (params.options || []).map((item) => item.trim()).filter(Boolean);
			const customChoice = "Type something…";
			let answer = choices.length ? await ctx.ui.select(params.question, [...choices, customChoice]) :
				await ctx.ui.input("Input required", params.question);
			if (answer === customChoice) answer = await ctx.ui.input(params.question);
			return { content: [{ type: "text", text: answer?.trim() || "The user did not provide an answer." }], details: {} };
		},
	});
}

