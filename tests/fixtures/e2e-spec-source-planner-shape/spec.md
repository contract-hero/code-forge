# Counter dApp — Specification

## Vision

A minimal multi-user counter dApp on Sui. Users connect their wallet, increment a shared counter, and see a leaderboard of contributions. Educational rather than production: the goal is to exercise wallet connect → tx → on-chain state → off-chain display end-to-end.

## Target Users

Sui developers learning dapp-kit. The dApp ships a working example that maps each major piece (Move module, on-chain object, indexer, frontend) to one acceptance criterion.

## Core Features

- **F1 — Wallet connect.** Users connect a Sui wallet via `@mysten/dapp-kit`. Acceptance: connect button is reachable from any page; disconnected state shows a clear CTA; connected state shows the address.
- **F2 — Increment counter.** Connected users issue a `counter::increment` transaction. Acceptance: tx settles in <5s; UI updates the on-chain counter value within 2 seconds of settlement.
- **F3 — Leaderboard.** Per-user contribution counts surfaced via an indexer. Acceptance: top-10 list refreshes on tx settle; empty state when no contributions yet.

## Architecture Overview

- Move package `counter` with shared `Counter` object and per-call event emission.
- TypeScript frontend using `@mysten/dapp-kit` for wallet, `@mysten/sui` JSON-RPC client for reads.
- Off-chain indexer subscribes to events, maintains a per-address counter aggregate.

## UX Flows

- First visit → wallet picker → connect → land on `/dashboard` → see global counter.
- Increment → spinner → toast on settle → counter updates.
- Disconnect → return to landing.

## Non-Functional Requirements

- Connect → first interactive < 1s on warm cache.
- Increment tx settle observed in UI < 5s p95.
- Accessible: keyboard navigable, AA contrast.

## Out of Scope

- No mainnet deployment.
- No SDK 1.x compatibility (2.x only).

## Open Questions

- Indexer ownership: external service vs in-process worker?

## E2E Tests

```yaml
- id: E-001
  name: user signs in and sees the counter dashboard
  kind: ui
  preconditions:
    - app running on localhost:3000
    - mock wallet provisioned
  steps:
    - navigate to /
    - click button:has-text('Connect wallet')
    - select 'Mock Wallet'
    - approve in wallet UI
    - wait for url '/dashboard'
    - assert text 'Counter:' visible
  expected: Dashboard loads with the current counter visible
  covers_contract: [F1, F2]
  tooling: chrome-devtools-mcp

- id: E-002
  name: increment moves counter on settle
  kind: ui
  preconditions:
    - signed in (E-001 fixture)
  steps:
    - read counter value as N
    - click button:has-text('Increment')
    - wait for toast 'Settled'
    - read counter value as N+1
  expected: counter increases by exactly 1 within 5 seconds of click
  covers_contract: [F2]
  tooling: chrome-devtools-mcp

- id: E-003
  name: leaderboard shows the connected user
  kind: api
  preconditions:
    - one increment by current user (E-002 fixture)
  steps:
    - GET /api/leaderboard
    - assert response.users[0].address == current user
    - assert response.users[0].count >= 1
  expected: connected user appears in top-1 with at least one contribution
  covers_contract: [F3]
  tooling: null
```
