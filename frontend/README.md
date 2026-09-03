# Parity — demo dashboard (frontend)

Minimal read-only dashboard + permissionless governance calls against the **live
Base Sepolia (84532)** deployment of the ParityHook. This is a *presentation
layer only* — the hook itself is fully on-chain and needs no frontend.

## Run

```bash
npm install
npm run dev        # http://localhost:5173
```

## What it shows

- **Deployed wiring** — hook ↔ LVRReserve ↔ ReputationLedger ↔ cross-pool oracle ↔ owner,
  plus the live 150 bps flag premium config.
- **Chainlink reference** — the live ETH/USD feed the reserve verifies against, its
  staleness guard, and the current price.
- **LVRReserve state** — verification window, pending records, active payouts.
- **Your reputation** — tier, score, last-swap block, and the treatment (delay / premium)
  Parity applies to the connected wallet.
- **Permissionless calls** — `settlePending(0)` and `distributeVerified(0)` buttons;
  these are open to any wallet once a verify window lapses.

## Notes

- Contract addresses live in `src/App.jsx`. Read calls use a public RPC
  (`sepolia.base.org`); writes go through the connected wallet's signer.
- Swapping itself is *not* in this UI by design — trades go through the standard
  Uniswap v4 router and are protected by the hook automatically. The demo focuses on
  the protection state and the verification/settlement plumbing a builder would surface.
