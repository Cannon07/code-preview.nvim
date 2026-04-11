// harness.ts — Invokes the OpenCode plugin hooks with mock data
//
// Usage:
//   npx tsx tests/backends/opencode/harness.ts <action> <socket> <project_dir> [args...]
//
// Actions:
//   edit_before   <socket> <dir> <file> <old> <new>
//   edit_after    <socket> <dir> <file>
//   write_before  <socket> <dir> <file> <content>
//   write_after   <socket> <dir> <file>
//   bash_before   <socket> <dir> <command>
//   bash_after    <socket> <dir>

import { resolve, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

async function main() {
  const action = process.argv[2]
  const socket = process.argv[3]
  const projectDir = process.argv[4]

  if (!action || !socket || !projectDir) {
    console.error("Usage: opencode_test_harness.ts <action> <socket> <dir> [args...]")
    process.exit(1)
  }

  process.env.NVIM_LISTEN_ADDRESS = socket

  // Dynamic import of the plugin (it's the default export)
  const pluginModule = await import(resolve(__dirname, "../../../backends/opencode/index.ts"))
  const pluginFactory = pluginModule.default

  // Initialize the plugin with the project directory
  const hooks = await pluginFactory({ directory: projectDir })

  const beforeHook = hooks["tool.execute.before"]
  const afterHook = hooks["tool.execute.after"]

  switch (action) {
    case "edit_before": {
      const filePath = process.argv[5]
      const oldString = process.argv[6]
      const newString = process.argv[7]
      await beforeHook(
        { tool: "edit" },
        { args: { filePath, oldString, newString, replaceAll: false } },
      )
      console.log("OK")
      break
    }

    case "edit_after": {
      const filePath = process.argv[5]
      await afterHook(
        { tool: "edit", args: { filePath } },
        {},
      )
      console.log("OK")
      break
    }

    case "write_before": {
      const filePath = process.argv[5]
      const content = process.argv[6]
      await beforeHook(
        { tool: "write" },
        { args: { filePath, content } },
      )
      console.log("OK")
      break
    }

    case "write_after": {
      const filePath = process.argv[5]
      await afterHook(
        { tool: "write", args: { filePath } },
        {},
      )
      console.log("OK")
      break
    }

    case "bash_before": {
      const command = process.argv[5]
      await beforeHook(
        { tool: "bash" },
        { args: { command } },
      )
      console.log("OK")
      break
    }

    case "bash_after": {
      await afterHook(
        { tool: "bash", args: {} },
        {},
      )
      console.log("OK")
      break
    }

    case "multi_before_before": {
      // Fire two before-hooks without any after-hooks.
      // Used to verify the diff queue state mid-lifecycle.
      const file1 = process.argv[5]
      const old1 = process.argv[6]
      const new1 = process.argv[7]
      const file2 = process.argv[8]
      const old2 = process.argv[9]
      const new2 = process.argv[10]

      await beforeHook(
        { tool: "edit" },
        { args: { filePath: file1, oldString: old1, newString: new1, replaceAll: false } },
      )
      await beforeHook(
        { tool: "edit" },
        { args: { filePath: file2, oldString: old2, newString: new2, replaceAll: false } },
      )
      console.log("OK")
      break
    }

    default:
      console.error(`Unknown action: ${action}`)
      process.exit(1)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
