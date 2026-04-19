// index.ts — OpenCode plugin entry point
//
// Thin adapter that translates OpenCode's hook format to the normalized
// JSON format and delegates to the unified core shell scripts.

import type { Plugin } from "@opencode-ai/plugin"
import { execSync } from "child_process"
import { readFileSync } from "fs"
import { resolve, dirname } from "path"
import { fileURLToPath } from "url"

// ── Resolve path to bin/ directory ───────────────────────────────

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

function binDir(): string {
  // When installed to .opencode/plugins/, bin-path.txt contains the
  // absolute path to the plugin's bin/ directory.
  try {
    return readFileSync(resolve(__dirname, "bin-path.txt"), "utf-8").trim()
  } catch {
    // Fallback for development: resolve relative to plugin source
    return resolve(__dirname, "../../bin")
  }
}

// ── Tool name mapping ────────────────────────────────────────────

const TOOL_MAP: Record<string, string> = {
  edit: "Edit",
  write: "Write",
  multiedit: "MultiEdit",
  bash: "Bash",
  apply_patch: "ApplyPatch",
}

// ── Format translation ──────────────────────────────────────────

function toNormalizedJson(
  tool: string,
  args: Record<string, any>,
  cwd: string,
): string | null {
  const toolName = TOOL_MAP[tool]
  if (!toolName) return null

  const toolInput: Record<string, any> = {}

  // Resolve file path (OpenCode may pass relative paths)
  if (args.filePath !== undefined) {
    const p = args.filePath as string
    toolInput.file_path = p && !p.startsWith("/") ? resolve(cwd, p) : p
  }

  // Edit fields (camelCase → snake_case)
  if (args.oldString !== undefined) toolInput.old_string = args.oldString
  if (args.newString !== undefined) toolInput.new_string = args.newString
  if (args.replaceAll !== undefined) toolInput.replace_all = args.replaceAll

  // Write fields
  if (args.content !== undefined) toolInput.content = args.content

  // MultiEdit fields
  if (args.edits !== undefined) {
    toolInput.edits = (args.edits as any[]).map((e) => ({
      old_string: e.oldString,
      new_string: e.newString,
    }))
  }

  // Bash fields
  if (args.command !== undefined) toolInput.command = args.command

  // ApplyPatch fields — handle both possible field names from different models
  if (args.patchText !== undefined) toolInput.patch_text = args.patchText
  if (args.patch !== undefined) toolInput.patch_text = args.patch

  return JSON.stringify({ tool_name: toolName, cwd, tool_input: toolInput })
}

// ── Core script execution ───────────────────────────────────────

function runCoreScript(script: string, json: string): void {
  const bin = binDir()
  try {
    execSync(`"${bin}/${script}"`, {
      input: json,
      env: { ...process.env, CODE_PREVIEW_BACKEND: "opencode" },
      timeout: 15000,
      stdio: ["pipe", "pipe", "pipe"],
    })
  } catch {
    // Errors are non-fatal — the diff preview is best-effort
  }
}

// ── Hook serialization ─────────────────────────────────────────
// OpenCode may fire tool.execute.after(file1) and tool.execute.before(file2)
// concurrently. Without serialization, the close_diff from file1's after-hook
// races with the show_diff from file2's before-hook, killing file2's preview.
// A simple queue ensures hooks execute one at a time.

let hookQueue: Promise<void> = Promise.resolve()

function enqueueHook(fn: () => void): Promise<void> {
  hookQueue = hookQueue.then(() => {
    try { fn() } catch { /* non-fatal */ }
  })
  return hookQueue
}

// ── Plugin entry point ──────────────────────────────────────────

const plugin: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      const args = output.args as Record<string, any>
      const json = toNormalizedJson(input.tool, args, directory)
      if (!json) return
      await enqueueHook(() => runCoreScript("core-pre-tool.sh", json))
    },

    "tool.execute.after": async (input, _output) => {
      const args = (input as any).args ?? {}
      const json = toNormalizedJson(input.tool, args, directory)
      if (!json) return
      await enqueueHook(() => runCoreScript("core-post-tool.sh", json))
    },
  }
}

export default plugin
