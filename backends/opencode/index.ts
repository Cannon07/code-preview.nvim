// index.ts — OpenCode plugin entry point.
//
// Thin transport layer: collects OpenCode's {tool, args, directory} per hook
// firing, JSON-encodes it, and pipes it into the shared generic hook entry
// (bin/hook-entry.{sh,ps1}), invoked as `opencode pre|post`, which performs
// socket discovery and RPCs the in-process orchestrator. Tool-name and
// camelCase→snake_case mapping live Lua-side (pre_tool.normalisers.opencode).
//
// See docs/adr/0008-one-hook-entry-per-os.md — OpenCode shares the same
// per-OS shim as the other agents rather than owning its own.

import type { Plugin } from "@opencode-ai/plugin"
import type { Plugin as V2Plugin } from "@opencode/plugin"
import { execSync } from "child_process"
import { existsSync, readFileSync } from "fs"
import { resolve, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const IS_WIN = process.platform === "win32"

// ── Hook-entry resolution ────────────────────────────────────────
// bin-path.txt (written by the installer) points at the plugin root; the shim
// lives at <root>/bin/hook-entry.{sh,ps1}. Re-run :CodePreviewInstallOpenCodeHooks
// after upgrading so bin-path.txt is refreshed.

function resolveHookEntry(): string | null {
  const root = readBinPath()
  if (!root) return null
  const name = IS_WIN ? "hook-entry.ps1" : "hook-entry.sh"
  const p = resolve(root, "bin", name)
  return existsSync(p) ? p : null
}

function readBinPath(): string | null {
  try {
    return readFileSync(resolve(__dirname, "bin-path.txt"), "utf-8").trim()
  } catch {
    // Development fallback: index.ts lives at <root>/backends/opencode/.
    return resolve(__dirname, "../..")
  }
}

// ── Tool allowlist ───────────────────────────────────────────────
// OpenCode tools as of 2026-05-19 the plugin previews: edit, write,
// multiedit, bash, apply_patch. Tools we deliberately ignore (fire-and-
// forget reads): read, glob, grep, list, todoread, todowrite, webfetch,
// websearch, task. Short-circuiting these here saves a bash fork + RPC per
// firing — OpenCode reads/greps prolifically.
//
// Symptom of forgetting to add a new structured-edit tool: no diff appears
// for it. Update this set and pre_tool.normalisers.opencode's tool map
// together.
const PREVIEW_TOOLS = new Set(["edit", "write", "multiedit", "bash", "apply_patch"])

// ── Shim invocation ──────────────────────────────────────────────

const HOOK_TIMEOUT_MS = 15000
// A genuine timeout takes ~HOOK_TIMEOUT_MS; the spurious libuv timeout below
// returns almost instantly. Anything faster than this is treated as spurious.
const SPURIOUS_TIMEOUT_MS = 2000
const MAX_HOOK_ATTEMPTS = 3

// Run `run` (a synchronous, throwing operation — here a spawnSync), retrying a
// SPURIOUS timeout.
//
// Why this exists: Node's spawnSync (used by execSync) derives its timeout
// deadline from libuv's *cached* loop time, which is only refreshed once per
// loop iteration. The first spawnSync that runs right after async work — here,
// the awaited enqueueHook in the tool hooks — sees a stale "now", so
// `now + timeout` is already in the past and libuv SIGTERMs the child the
// instant it spawns: a spurious ETIMEDOUT that returns in ~15ms instead of 15s.
// On Windows this drops the FIRST hook of a concurrent burst, so that file gets
// no diff/marker (issue #46; Unix is unaffected — it execs the .sh directly and
// doesn't hit this the same way).
//
// The fix: retry, but first `await` a turn of the event loop so libuv refreshes
// its cached time — a synchronous retry would re-read the same stale value and
// fail again (which is exactly why the *next* hook in a burst always succeeds).
// A genuine timeout takes ~HOOK_TIMEOUT_MS, far above SPURIOUS_TIMEOUT_MS, so it
// is never retried. `label` is used only for the diagnostic log. Exported so the
// retry behaviour can be exercised by the test harness (it's a Windows libuv
// quirk that can't otherwise be reproduced on CI).
export async function runWithSpuriousRetry(
  run: () => void,
  label = "hook-entry",
): Promise<void> {
  for (let attempt = 1; attempt <= MAX_HOOK_ATTEMPTS; attempt++) {
    const start = Date.now()
    try {
      run()
      return
    } catch (err: any) {
      const elapsed = Date.now() - start
      // A timeout-kill surfaces as code ETIMEDOUT and/or signal SIGTERM — Node
      // has historically reported one or the other depending on platform — so
      // match both, or the spurious-timeout retry could be missed where only
      // SIGTERM is set. Still gated on elapsed < SPURIOUS_TIMEOUT_MS below, so a
      // genuine ~15s hang (also SIGTERM'd) is never mistaken for spurious.
      const timedOut =
        !!err && (err.code === "ETIMEDOUT" || err.signal === "SIGTERM")
      if (timedOut && elapsed < SPURIOUS_TIMEOUT_MS && attempt < MAX_HOOK_ATTEMPTS) {
        // Yield so libuv refreshes its cached loop time before retrying.
        await new Promise<void>((resolve) => setImmediate(resolve))
        continue
      }
      // Abstain on any failure. Log a genuine timeout with elapsed ms so a real
      // hang (~15s) is distinguishable from exhausted spurious retries.
      if (timedOut) {
        // eslint-disable-next-line no-console
        console.debug(`[code-preview] ${label} timed out after ${elapsed}ms`)
      }
      return
    }
  }
}

async function runHook(event: "pre" | "post", payload: object): Promise<void> {
  const shim = resolveHookEntry()
  if (!shim) {
    // Surface enough breadcrumb that a misconfigured bin-path.txt isn't a
    // silently-broken plugin.
    // eslint-disable-next-line no-console
    console.debug(`[code-preview] could not resolve hook-entry shim`)
    return
  }
  // On Windows the .ps1 runs through PowerShell; on Unix the .sh runs directly.
  const cmd = IS_WIN
    ? `powershell -NoProfile -ExecutionPolicy Bypass -File "${shim}" opencode ${event}`
    : `"${shim}" opencode ${event}`

  await runWithSpuriousRetry(() => {
    execSync(cmd, {
      input: JSON.stringify(payload),
      env: { ...process.env, CODE_PREVIEW_BACKEND: "opencode" },
      timeout: HOOK_TIMEOUT_MS,
      stdio: ["pipe", "pipe", "pipe"],
    })
  }, `hook-entry ${event}`)
}

// ── Hook serialisation ───────────────────────────────────────────
// TS→nvim send-order preservation: OpenCode fires before(A) and after(B)
// concurrently; without this, RPCs can reorder during socket discovery and a
// post-tool close can land before its matching pre-tool open. The in-process
// Lua orchestrator serialises *within* nvim's main thread, but cannot fix
// out-of-order arrivals from the TS side.

let hookQueue: Promise<void> = Promise.resolve()

function enqueueHook(fn: () => void | Promise<void>): Promise<void> {
  hookQueue = hookQueue.then(async () => {
    try { await fn() } catch { /* non-fatal */ }
  })
  return hookQueue
}

// ── Plugin entry point ───────────────────────────────────────────

const plugin: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      if (!PREVIEW_TOOLS.has(input.tool)) return
      const args = (output.args as Record<string, any>) ?? {}
      const payload = { tool: input.tool, args, cwd: directory }
      await enqueueHook(() => runHook("pre", payload))
    },

    "tool.execute.after": async (input, _output) => {
      if (!PREVIEW_TOOLS.has(input.tool)) return
      // OpenCode's after-hook carries the tool args on `input` (the before-hook
      // carries them on `output`), confirmed on the live API (issue #46).
      const args = ((input as any).args as Record<string, any>) ?? {}
      const payload = { tool: input.tool, args, cwd: directory }
      await enqueueHook(() => runHook("post", payload))
    },
  }
}

// Type-only SDK imports keep the copied adapter free of runtime dependencies.
// V1 (1.18.29+) calls server; V2 calls setup.
export default {
  id: "code-preview",
  server: plugin,
  async setup(ctx) {
    for (const [hook, phase] of [
      ["execute.before", "pre"],
      ["execute.after", "post"],
    ] as const) {
      await ctx.tool.hook(hook, async (event) => {
        // V2 renamed these tools; keep the shared Lua payload compatible.
        const tool = event.tool === "patch" ? "apply_patch"
          : event.tool === "shell" ? "bash" : event.tool
        if (!PREVIEW_TOOLS.has(tool)) return
        await enqueueHook(async () => {
          // Use the session location rather than the plugin's load location.
          const session = await ctx.session.get({ sessionID: event.sessionID })
          await runHook(phase, {
            tool,
            args: event.input ?? {},
            cwd: session.location.directory,
          })
        })
      })
    }
  },
} satisfies V2Plugin.Plugin & { server: Plugin }
