// nvim.ts — Neovim socket discovery and RPC helpers
//
// Finds running Neovim instances by scanning known socket locations
// (macOS, Linux, XDG_RUNTIME_DIR) and sends Lua commands via RPC.

import { existsSync, statSync, writeFileSync, unlinkSync } from "fs"
import { dirname, basename } from "path"
import { execSync } from "child_process"
import { platform } from "os"

function getPidCwd(pid: string): string | null {
  try {
    if (existsSync(`/proc/${pid}/cwd`)) {
      return execSync(`readlink /proc/${pid}/cwd`, { encoding: "utf-8", timeout: 2000 }).trim()
    }
    // macOS fallback
    const result = execSync(`lsof -a -p ${pid} -d cwd -Fn 2>/dev/null | grep '^n/' | head -1 | cut -c2-`, {
      encoding: "utf-8",
      timeout: 2000,
    }).trim()
    return result || null
  } catch {
    return null
  }
}

function isSocketAlive(socketPath: string): boolean {
  try {
    const st = statSync(socketPath)
    return st.isSocket()
  } catch {
    return false
  }
}

function isSocketResponsive(socketPath: string): boolean {
  try {
    execSync(`nvim --server "${socketPath}" --remote-expr "1"`, {
      timeout: 2000,
      stdio: "ignore",
    })
    return true
  } catch {
    return false
  }
}

function isPidAlive(pid: string): boolean {
  try {
    process.kill(parseInt(pid), 0)
    return true
  } catch {
    return false
  }
}

/**
 * Discover a running Neovim instance's RPC socket.
 * Prefers the instance whose cwd matches the given project directory.
 */
export function findNvimSocket(projectCwd: string): string | null {
  // 1. Check explicit env var — verify the socket is actually responsive
  const envSocket = process.env.NVIM_LISTEN_ADDRESS
  if (envSocket && isSocketAlive(envSocket) && isSocketResponsive(envSocket)) return envSocket

  // 2. Scan known socket locations
  const liveSockets: Array<{ pid: string; socket: string }> = []

  // macOS: /var/folders/*/*/T/nvim.*/*/nvim.*.0
  if (platform() === "darwin") {
    try {
      const result = execSync("ls /var/folders/*/*/T/nvim.*/*/nvim.*.0 2>/dev/null", {
        encoding: "utf-8",
        timeout: 5000,
      }).trim()
      for (const line of result.split("\n").filter(Boolean)) {
        const match = line.match(/nvim\.(\d+)\.0$/)
        if (match && isSocketAlive(line) && isPidAlive(match[1])) {
          liveSockets.push({ pid: match[1], socket: line })
        }
      }
    } catch {}
  }

  // Linux: /tmp/nvim.*/0
  try {
    const result = execSync("ls /tmp/nvim.*/0 2>/dev/null", {
      encoding: "utf-8",
      timeout: 3000,
    }).trim()
    for (const line of result.split("\n").filter(Boolean)) {
      const dirName = basename(dirname(line))
      const match = dirName.match(/nvim\.(\d+)/)
      if (match && isSocketAlive(line) && isPidAlive(match[1])) {
        liveSockets.push({ pid: match[1], socket: line })
      }
    }
  } catch {}

  // XDG_RUNTIME_DIR
  const xdgDir = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? ""}`
  try {
    const result = execSync(`ls ${xdgDir}/nvim.*.0 2>/dev/null`, {
      encoding: "utf-8",
      timeout: 3000,
    }).trim()
    for (const line of result.split("\n").filter(Boolean)) {
      const match = line.match(/nvim\.(\d+)\.0$/)
      if (match && isSocketAlive(line) && isPidAlive(match[1])) {
        liveSockets.push({ pid: match[1], socket: line })
      }
    }
  } catch {}

  if (liveSockets.length === 0) return null

  // Helper: get socket creation time (newer = more recent Neovim instance)
  const socketMtime = (s: string): number => {
    try { return statSync(s).ctimeMs } catch { return 0 }
  }

  // 3. Prefer socket whose Neovim cwd matches project (newest by ctime)
  if (projectCwd) {
    const matches = liveSockets.filter(({ pid }) => {
      const nvimCwd = getPidCwd(pid)
      return nvimCwd && (projectCwd === nvimCwd || projectCwd.startsWith(nvimCwd + "/"))
    })
    if (matches.length > 0) {
      matches.sort((a, b) => socketMtime(b.socket) - socketMtime(a.socket))
      return matches[0].socket
    }
  }

  // 4. Fallback to newest live socket
  liveSockets.sort((a, b) => socketMtime(b.socket) - socketMtime(a.socket))
  return liveSockets[0].socket
}

/** Escape a string for use inside a Lua single-quoted string literal. */
export function escapeLua(str: string): string {
  return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'")
}

/**
 * Send a Lua command to Neovim.
 * Writes to a temp file and uses `:luafile` to avoid command-line length
 * limits with --remote-send.
 */
export function nvimSend(socket: string, luaCmd: string): boolean {
  const tmpLua = `/tmp/claude-preview-nvim-cmd-${process.pid}-${Date.now()}.lua`
  try {
    writeFileSync(tmpLua, luaCmd)
    // Use --remote-expr with execute() so the call is synchronous —
    // Neovim runs the luafile and returns before we delete the temp file.
    execSync(
      `nvim --server "${socket}" --remote-expr "execute('luafile ${tmpLua}')"`,
      { timeout: 5000, stdio: "pipe" },
    )
    return true
  } catch {
    return false
  } finally {
    try { unlinkSync(tmpLua) } catch {}
  }
}
