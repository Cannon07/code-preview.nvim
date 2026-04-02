// index.ts — OpenCode plugin entry point
//
// Registers tool.execute.before and tool.execute.after hooks to intercept
// file edits and send diff previews to Neovim via RPC.

import type { Plugin } from "@opencode-ai/plugin"
import { writeFileSync, existsSync, unlinkSync } from "fs"
import { dirname, resolve, relative } from "path"
import { tmpdir } from "os"

import { findNvimSocket, escapeLua, nvimSend } from "./nvim.js"
import { applyEdit, applyMultiEdit, readFileOrEmpty } from "./edits.js"

// ── Temp file management ──────────────────────────────────────────

const ORIG_FILE = resolve(tmpdir(), "claude-diff-original")
const PROP_FILE = resolve(tmpdir(), "claude-diff-proposed")

function cleanupTempFiles(): void {
  try { unlinkSync(ORIG_FILE) } catch {}
  try { unlinkSync(PROP_FILE) } catch {}
}

// ── Tool name constants ───────────────────────────────────────────

const EDIT_TOOLS = new Set(["edit", "write", "multiedit", "apply_patch"])
const RM_PATTERN = /^(sudo\s+)?rm\s/

// ── Plugin entry point ────────────────────────────────────────────

const plugin: Plugin = async ({ directory }) => {
  const projectCwd = directory

  return {
    "tool.execute.before": async (input, output) => {
      const { tool } = input
      const args = output.args as Record<string, any>
      // ── Bash (rm detection) ───────────────────────────────
      if (tool === "bash") {
        const command: string = args.command ?? ""
        const subcmds = command.split(/[;&|]{1,2}/)
        const rmPaths: string[] = []

        for (const sub of subcmds) {
          const trimmed = sub.trim()
          if (!RM_PATTERN.test(trimmed)) continue

          const parts = trimmed
            .replace(/^(sudo\s+)?rm\s+/, "")
            .split(/\s+/)
            .filter((p) => !p.startsWith("-") && p.length > 0)

          for (const p of parts) {
            rmPaths.push(p.startsWith("/") ? p : resolve(projectCwd, p))
          }
        }

        if (rmPaths.length === 0) return

        const socket = findNvimSocket(projectCwd)
        if (!socket) return

        for (const rmPath of rmPaths) {
          nvimSend(socket, `require('claude-preview.changes').set('${escapeLua(rmPath)}', 'deleted')`)
        }
        nvimSend(socket, "pcall(function() require('claude-preview.neo_tree').refresh() end)")
        nvimSend(
          socket,
          `vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('${escapeLua(rmPaths[0])}') end) end, 300)`,
        )
        return
      }

      // ── Skip non-edit tools ───────────────────────────────
      if (!EDIT_TOOLS.has(tool)) return

      // ── Compute original and proposed content ─────────────
      let filePath: string
      let original: string
      let proposed: string

      // Resolve filePath — the hook fires with raw LLM args which may
      // contain a relative path.  The tool itself resolves it inside
      // execute(), but that happens *after* the hook, so we must do it
      // here too.
      const resolveFilePath = (p: string) =>
        p && !p.startsWith("/") ? resolve(projectCwd, p) : p

      switch (tool) {
        case "edit": {
          filePath = resolveFilePath(args.filePath)
          original = readFileOrEmpty(filePath)
          proposed = applyEdit(
            original,
            args.oldString ?? "",
            args.newString ?? "",
            args.replaceAll ?? false,
          )
          break
        }

        case "write": {
          filePath = resolveFilePath(args.filePath)
          original = readFileOrEmpty(filePath)
          proposed = args.content ?? ""
          break
        }

        case "multiedit": {
          filePath = resolveFilePath(args.filePath)
          original = readFileOrEmpty(filePath)
          proposed = applyMultiEdit(original, args.edits ?? [])
          break
        }

        case "apply_patch": {
          const patchText: string = args.patchText ?? ""
          const fileMatch = patchText.match(/^---\s+a\/(.+)$/m)
            ?? patchText.match(/^\+\+\+\s+b\/(.+)$/m)
          if (!fileMatch) return

          filePath = resolve(projectCwd, fileMatch[1])
          original = readFileOrEmpty(filePath)
          // TODO: Implement a proper unified diff parser for V2
          proposed = original
          return // Skip diff preview for apply_patch in V1
        }

        default:
          return
      }

      // ── Write temp files ──────────────────────────────────
      writeFileSync(ORIG_FILE, original)
      writeFileSync(PROP_FILE, proposed)

      // ── Send to Neovim ────────────────────────────────────
      const socket = findNvimSocket(projectCwd)
      if (!socket) return

      const displayName = relative(projectCwd, filePath) || filePath
      const changeStatus = existsSync(filePath) ? "modified" : "created"

      const origEsc = escapeLua(ORIG_FILE)
      const propEsc = escapeLua(PROP_FILE)
      const displayEsc = escapeLua(displayName)
      const filePathEsc = escapeLua(filePath)

      // Send all commands in a single pcall-wrapped block to avoid
      // one error blocking subsequent commands via --remote-send
      const revealCmd = changeStatus === "modified"
        ? `vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('${filePathEsc}') end) end, 300)`
        : (() => {
            let revealDir = dirname(filePath)
            while (!existsSync(revealDir) && revealDir !== "/") {
              revealDir = dirname(revealDir)
            }
            return `vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('${escapeLua(revealDir)}') end) end, 300)`
          })()

      const luaBlock = [
        `pcall(function() require('claude-preview.changes').set('${filePathEsc}', '${changeStatus}') end)`,
        `pcall(function() require('claude-preview.neo_tree').refresh() end)`,
        `pcall(function() ${revealCmd} end)`,
        `local ok, err = pcall(function() require('claude-preview.diff').show_diff('${origEsc}', '${propEsc}', '${displayEsc}') end)`,
        `if not ok then vim.notify('claude-preview show_diff error: ' .. tostring(err), vim.log.levels.ERROR) end`,
      ].join(" ")

      nvimSend(socket, luaBlock)
    },

    "tool.execute.after": async (input, _output) => {
      const { tool } = input
      // For bash (rm detection), only clear deletion markers
      if (tool === "bash") {
        const socket = findNvimSocket(projectCwd)
        if (!socket) return

        nvimSend(socket, [
          "pcall(function() require('claude-preview.changes').clear_by_status('deleted') end)",
          "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)",
        ].join(" "))
        return
      }

      if (!EDIT_TOOLS.has(tool)) return

      const socket = findNvimSocket(projectCwd)
      if (!socket) return

      const args = input.args as Record<string, any>
      const rawPath: string | undefined = args?.filePath
      const filePath = rawPath && !rawPath.startsWith("/") ? resolve(projectCwd, rawPath) : rawPath

      // Send all cleanup commands in a single batch
      const luaLines = [
        "pcall(function() require('claude-preview.changes').clear_all() end)",
        "pcall(function() require('claude-preview.diff').close_diff() end)",
      ]

      if (filePath) {
        const filePathEsc = escapeLua(filePath)
        luaLines.push(
          `vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').reveal('${filePathEsc}') end) end, 200) end, 200)`,
        )
      } else {
        luaLines.push(
          "vim.defer_fn(function() pcall(function() require('claude-preview.neo_tree').refresh() end) end, 200)",
        )
      }

      nvimSend(socket, luaLines.join(" "))

      cleanupTempFiles()
    },
  }
}

export default plugin
