// retry_test.ts — Unit guard for runWithSpuriousRetry (issue #46).
//
// The Windows libuv quirk — the first spawnSync after async work spuriously
// times out because libuv's cached loop time is stale — can't be reproduced on
// CI. So we test the retry logic directly by injecting a `run` that throws a
// fast ETIMEDOUT / SIGTERM. Cheap insurance against someone later "simplifying"
// the retry (or the SIGTERM match) away. No nvim required.
//
// Run via: bun retry_test.ts   (or)   npx tsx retry_test.ts
// Prints "ALL OK" and exits 0 on success; exits 1 on any failed check.

import { resolve, dirname } from "path"
import { fileURLToPath, pathToFileURL } from "url"

const __dirname = dirname(fileURLToPath(import.meta.url))

type RunWithSpuriousRetry = (run: () => void, label?: string) => Promise<void>

// Build an error shaped like Node's timeout-kill: ETIMEDOUT via `code`, or a
// SIGTERM kill via `signal` (platform-dependent — see the retry's `timedOut`).
function timeoutErr(kind: "code" | "signal"): Error {
  const e = new Error("simulated timeout") as any
  if (kind === "code") e.code = "ETIMEDOUT"
  else e.signal = "SIGTERM"
  return e
}

let failures = 0
function check(name: string, cond: boolean): void {
  console.log(`${cond ? "ok  " : "FAIL"} - ${name}`)
  if (!cond) failures++
}

async function main(): Promise<void> {
  // pathToFileURL so the dynamic import works with Windows absolute paths too
  // (the bare `D:\…` path is rejected by the ESM loader as an unsupported scheme).
  const indexPath = resolve(__dirname, "../../../backends/opencode/index.ts")
  const mod = await import(pathToFileURL(indexPath).href)
  // Exposed as `retry.runWithSpuriousRetry` (a property on a const object, not a
  // bare function export — see backends/opencode/index.ts).
  const runWithSpuriousRetry = mod.retry.runWithSpuriousRetry as RunWithSpuriousRetry

  // Success on the first attempt → run called exactly once.
  {
    let calls = 0
    await runWithSpuriousRetry(() => { calls++ })
    check("success on first attempt runs once", calls === 1)
  }

  // The core case: a fast ETIMEDOUT recovers on retry (the libuv quirk).
  {
    let calls = 0
    await runWithSpuriousRetry(() => { calls++; if (calls === 1) throw timeoutErr("code") })
    check("fast ETIMEDOUT recovers on retry (runs twice)", calls === 2)
  }

  // Platform variance: a SIGTERM-only fast kill must also recover (review fix).
  {
    let calls = 0
    await runWithSpuriousRetry(() => { calls++; if (calls === 1) throw timeoutErr("signal") })
    check("fast SIGTERM recovers on retry (runs twice)", calls === 2)
  }

  // A non-timeout error must NOT be retried — abstain after one attempt.
  {
    let calls = 0
    await runWithSpuriousRetry(() => {
      calls++
      const e = new Error("nope") as any
      e.code = "ENOENT"
      throw e
    })
    check("non-timeout error is not retried (runs once)", calls === 1)
  }

  // A persistent fast timeout must be bounded at MAX_HOOK_ATTEMPTS — no infinite
  // loop if every attempt spuriously times out.
  {
    let calls = 0
    await runWithSpuriousRetry(() => { calls++; throw timeoutErr("code") })
    check("persistent fast timeout is bounded (runs 3x)", calls === 3)
  }

  if (failures > 0) {
    console.log(`RETRY GUARD FAILED (${failures})`)
    process.exit(1)
  }
  console.log("ALL OK")
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
