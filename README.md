# C1 — SessionRouter day-lock scoping (multi-day session recycle) — PoC

Fork test against **Base mainnet live bytecode**, pinned at block `58461106`.

## Reproduce
```
export BASE_RPC_URL=https://mainnet.base.org
forge test --match-contract C1SessionRecycleForkTest -vv
```
Foundry standalone; no target repo compilation (interfaces only).

## What it proves
1. Close a 7-day session late on its final day: only ~12.5% of the stake is day-locked;
   **87.5% is returned in the same tx** (≥ (N−1)/N = 85.7% floor).
2. The recycled stake opens a **second full session the same UTC day**.
3. Warp past session 2's end → `claimForProvider` draws a fresh stipend from the funding
   account (**zero net new capital across both sessions**); user-side lock across both
   sessions is only the two final days.
