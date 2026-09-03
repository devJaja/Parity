# Parity — demo frontend

A **Chakra UI + wagmi (viem) + react-router** dashboard for the live Base Sepolia
(84532) deployment of the ParityHook. Three pages:

- **Dashboard** — live wiring, reserve state, and the connected wallet's
  reputation tier + score (with a tier-band gauge).
- **Swap Demo** — the treatment Parity applies (delay / premium) plus the
  permissionless `settlePending(0)` / `distributeVerified(0)` reserve calls.
- **LVR Analysis** — the verification/EWMA decision explained, with live reserve
  parameters and the live ETH/USD Chainlink reference.

## Run

```bash
npm install
npm run dev        # http://localhost:5173
```

Connect a MetaMask/Rainbow wallet on **Base Sepolia (84532)** to see reputation
and run settlement calls.

> The hook itself is fully on-chain and needs no frontend — this dashboard is a
> presentation layer (and a judging aid) only. Swaps go through the standard
> Uniswap v4 router and are protected automatically.

## Contract addresses

All in `src/contracts.ts` (live Base Sepolia deployment).

## Notes

- Read calls use `https://sepolia.base.org`; writes go through the connected
  wallet's signer via wagmi.
- The live deploy currently has no seeded pool on-chain, so premium escrow is
  demonstrated via fork proofs (`test/HookLiveFork.t.sol` / `test/PushLivePool.t.sol`); the
  Swap Demo page states this honestly and surfaces pending records once a pool
  is seeded.
