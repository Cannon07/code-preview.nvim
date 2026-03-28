// nvim.ts — Neovim socket discovery and RPC helpers
//
// Finds running Neovim instances by scanning known socket locations
// (macOS, Linux, XDG_RUNTIME_DIR) and sends Lua commands via RPC.

import { existsSync, statSync } from "fs"
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
  // 1. Check explicit env var
  const envSocket = process.env.NVIM_LISTEN_ADDRESS
  if (envSocket && isSocketAlive(envSocket)) return envSocket

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

  // 3. Prefer socket whose Neovim cwd matches project
  if (projectCwd) {
    for (const { pid, socket } of liveSockets) {
      const nvimCwd = getPidCwd(pid)
      if (nvimCwd && (projectCwd === nvimCwd || projectCwd.startsWith(nvimCwd + "/"))) {
        return socket
      }
    }
  }

  // 4. Fallback to first live socket
  return liveSockets[0].socket
}

/** Escape a string for use inside a Lua single-quoted string literal. */
export function escapeLua(str: string): string {
  return str.replace(/\\/g, "\\\\").replace(/'/g, "\\'")
}

/** Send a Lua command to Neovim via --remote-send. */
export function nvimSend(socket: string, luaCmd: string): boolean {
  try {
    execSync(
      `nvim --server "${socket}" --remote-send ":lua ${luaCmd}<CR>"`,
      { timeout: 5000, stdio: "ignore" },
    )
    return true
  } catch {
    return false
  }
}
