# Morpheus — SessionRouter day-lock scoping (multi-day session stipend recycle)

PoC for Morpheus Bug Bounty Program v2. Foundry test against the deployed Inference Diamond
on Base mainnet, pinned to a specific block.

## Run

```bash
export BASE_RPC_URL=https://mainnet.base.org   # any Base mainnet RPC
forge test --match-contract C1SessionRecycleForkTest -vv
```

Expected: `[PASS]` with logs showing
- `held onHold (locked)` = final-day consumption only (~13.6% of stake)
- `released same-tx` >= `(N-1)/N floor` (~86.4% of stake)
- `stipend drawn same-day on recycled stake (MOR)` > 0

## The bug

`_rewardUserAfterClose` locks only the consumption of the UTC day containing
`min(closedAt, endsAt)`: `userDuration_ = sessionEnd_ - openedAt.max(startOfEndDay_)`.
For a session spanning N UTC days, stake backing days 1..N-1 was already consumed
(stipend drawn each day) but is released at close while the closing epoch is still open.
The released stake opens a new session the same UTC day and draws a fresh stipend
against the same MOR.

Invariant from the incident record (patched 2026-07-31, PR #830/#833):
"Used consumer stake cannot be recycled inside the same UTC day to draw another stipend
against the same MOR." — satisfied only for N=1.
