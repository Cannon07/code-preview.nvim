// edits.ts — Edit computation helpers
//
// Pure functions that compute proposed file content by applying
// find-and-replace edits. Mirrors the logic in bin/apply-edit.lua
// and bin/apply-multi-edit.lua.

import { readFileSync } from "fs"

/** Apply a single find-and-replace edit to content. */
export function applyEdit(
  content: string,
  oldString: string,
  newString: string,
  replaceAll = false,
): string {
  if (oldString === "") return content

  if (replaceAll) {
    return content.split(oldString).join(newString)
  }

  const idx = content.indexOf(oldString)
  if (idx === -1) return content
  return content.substring(0, idx) + newString + content.substring(idx + oldString.length)
}

/** Apply multiple sequential find-and-replace edits to content. */
export function applyMultiEdit(
  content: string,
  edits: Array<{ oldString: string; newString: string; replaceAll?: boolean }>,
): string {
  for (const edit of edits) {
    const old = edit.oldString ?? ""
    const replacement = edit.newString ?? ""
    if (old === "") {
      content = replacement + content
    } else {
      const idx = content.indexOf(old)
      if (idx !== -1) {
        content = content.substring(0, idx) + replacement + content.substring(idx + old.length)
      }
    }
  }
  return content
}

/** Read a file's content, returning empty string if it doesn't exist. */
export function readFileOrEmpty(filePath: string): string {
  try {
    return readFileSync(filePath, "utf-8")
  } catch {
    return ""
  }
}
