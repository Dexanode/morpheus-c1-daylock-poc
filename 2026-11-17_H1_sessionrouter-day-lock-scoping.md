# H-1: SessionRouter day-lock covers only the final day of a multi-day session — recycled stake draws fresh stipends with zero net new capital

**Date:** 2026-11-17
**Severity claimed:** High (direct over-issuance of MOR stipends from the Compute pool)
**Affected:** SessionRouter facet, deployed diamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base mainnet, live bytecode at block 58461106)
**Reference code:** `contracts/diamond/facets/SessionRouter.sol` ~L306 (`userDuration_ = sessionEnd_ - session.openedAt.max(startOfEndDay_)`), L305–315 (lock + inline remainder transfer), L406–414 (`stipendToStake`)
**Related history:** July 2026 "SessionRouter Stipend Leak" incident; patch PRs #830/#833

## TARGET
Morpheus Compute lane — MOR stipends paid from the funding account for session consumption, collateralized by user MOROFT stakes.

## INVARIANT
*Consumer stake already used to draw a stipend for UTC days 1..N−1 of a multi-day session must not be freed and re-used to draw additional stipends before new capital backs it.*

## IMPACT
Direct MOR over-issuance. For a session spanning N UTC days, `(N−1)/N` of the stake is returned **in the same transaction** as `closeSession` (measured: 87.5% of 2000 MOR on a 7-day session, floor 85.7%), and that stake immediately funds a second full session the **same UTC day**. The second session draws its full stipend from the funding account while net new capital across both sessions is **zero**. This repeats every cycle — a compounding draw against the daily pool budget, not a one-shot.

Honest bound: per-cycle over-draw is capped at the recycled fraction (≤ (N−1)/N, N ≤ 7 days by `maxSessionDuration`), amortized by the declining daily pool draw (~11.9k MOR/day at current emission; funding account currently holds 85,131 MOR ≈ $61k at MOR ≈ $0.72 — verified live). Sustained self-dealing cycles can extract a large share of the remaining Compute pool ahead of honest consumers.

## PRECONDITIONS
- Any user with MOROFT stake (self-dealing via own bid/provider registration — risk-free, no counterparty).
- Session duration > 1 UTC day (config allows up to 7).
- No privilege, no oracle dependency, no third party.

## ATTACK
1. Register provider + model + bid (self-deal).
2. `openSession` with stake S, duration ≈ stipend(S)/price → spans N UTC days (PoC: N=7).
3. Consume days 1..N−1 (stipend for those days is drawn against S).
4. Late on day N, `closeSession`: day-lock (PR #830) only covers `startOfEndDay_` — the final day. The other N−1 days' stake-equivalent is transferred back **in the same tx**.
5. Same UTC day: `openSession` again with the returned stake (PoC: sessionId2 succeeds while session 1's hold is still locked).
6. Warp past session 2's end → `claimForProvider(session2)` pays a fresh stipend from the funding account with zero net new capital (PoC: 5.11 MOR drawn; repeatable every cycle).

## POC
Foundry fork test against **live Base bytecode** (pinned block 58461106), executed via two independent methods:
- **Method A** — standalone forge test (interfaces only, no target-repo compilation): `forge test --match-contract C1SessionRecycleForkTest -vv` → PASS. Logs: stake 2000e18; held onHold 250.18e18 (12.5%); released same-tx 1749.82e18 (87.5% ≥ 85.7% floor); session 2 opened same UTC day; session 2 stipend drawn 5.11e18; locked-after-both-sessions 0.
- **Method B** — raw `cast` calldata against an anvil fork of Base: full chain of txs status 1 (register → open 584327s → warp → close → hold 271.49e18, inline refund ~1729.5e18 → session #2 opened same day_start 1795392000 → claimForProvider success).

Repo (reproduce with `BASE_RPC_URL=https://mainnet.base.org forge test --match-contract C1SessionRecycleForkTest -vv`): attached / [gist to be pasted].

## FIX
Scope the day-lock to the **entire stipend-eligible period**, not only the final day: `userDuration_ = sessionEnd_ - session.openedAt` (lock the full used-stipend equivalent until the last drawn epoch's release), or track per-day consumption so each drawn day's stake-equivalent stays locked until its own epoch closes. `stipendToStake(userInitialLock_, startOfEndDay_)` at L305–315 anchors only to the final day — that is the single-line root cause.

## Notes for triage
- We do **not** claim that the immediate return of unused stake is a bug (that is the #830 design, runbook step 5). The single claim is: **#830's lock only reaches the final day of a multi-day session, so stake used on days 1..N−1 — whose stipends were already drawn — is freely recycled the same day and can draw again.**
- We acknowledge that a stake whose epoch has already closed may legitimately be released; the violation is that days 1..N−1 **within the closed session** drew stipends yet their stake-equivalent is not held until the next UTC boundary.
- PoC runs against post-cut live bytecode (`getUserStakesOnHold > 0` behavior observed on the live fork confirms the #830 cut is deployed).
