# Parity — Self-Funding LVR Firewall for Uniswap v4

> Submission for the **UHI10 Hookathon** (Uniswap v4 hooks track).

Parity turns LVR (*loss-versus-rebalancing*) from an unavoidable LP tax into a
self-funding insurance pool. Toxic flow is identified per-swapper, made
non-atomic, charged a premium, and — once the price move it predicted actually
materializes — paid out to the liquidity providers who bore the risk.

```
Swapper ──▶ ReputationLedger ──▶ ParityHook (v4 hook)
                                    │  Trusted   → instant execution, base fee
                                    │  Neutral   → ordering delay only
                                    │  Flagged   → ordering delay + 150 bps premium
                                    ▼
                               LVRReserve ◀── ChainlinkPriceAdapter
                                    │  N blocks later, settlePending():
                                    │  verified toxic   → pro-rata payout to LPs
                                    │  unverified       → donated to in-range LPs,
                                    │                     trains the EWMA noise floor
                                    │  oracle failure   → auto-unverifiable, donated
                                    ▼
                          LPs made whole via v4 `donate()`
```

## Why ordering delay kills the sandwich

Atomic arbitrage requires both sandwich legs in the same block. Parity's hook
reverts any swap that would land on the same block as a swapper's previous swap
(`DelayWindowActive(swapper, eligibleAt)`), with one extra block required on the
Flagged tier. Honest retail never notices; MEV bots lose their atomicity
guarantee *without being censored* — they can still trade, just not in the same
block twice.

## Verification: only confirmed toxicity pays

A flagged trade escrows its premium in `LVRReserve` together with:

- the pool's execution anchor (`sqrtPriceT0`, pre-trade),
- the Chainlink reference at that instant (`refPriceT0_18`),
- direction and active liquidity of the affected block.

After `verifyBlocks`, anyone can call `settlePending(i)`. The reserve compares
the realized drift against the pre-trade deviation plus an adaptive noise floor
(EWMA of recent observed drift, floored at `minNoiseBps`). Drift beyond noise,
in the swapper's favor ⇒ **verified**: the premium becomes a pro-rata payout.
Otherwise the premium is donated straight back to in-range LPs and the outcome
trains the threshold. Oracle downtime degrades safely: no reference ⇒
auto-unverifiable ⇒ donated, never stuck.

Pool prices are normalized across token decimal pairs
(`humanPrice = rawPrice · 10^(dec0−dec1)`) so mixed-decimal pools (e.g.
WETH/USDC-style 18/6 pairs) classify drift identically to 18/18 pools; the
conversion stages the square-root square through `Math.mulDiv` so pools priced
near `TickMath.MAX_SQRT_RATIO` cannot overflow.

## Identity: corroborated, never blindly trusted

Routers pass the end-user address in `hookData`. Parity honors a claimed
identity only when it is **corroborated**: the transaction originates from the
claimed EOA (`tx.origin == claimed`), or an explicitly authorized router
attests on the user's behalf (governance-managed via
`setRouterAuthorization`; deployment authorizes the canonical v4
PositionManager so smart-wallet LP attribution works). Uncorroborated claims
are discarded — flow resolves to the calling router contract, which accumulates
its own reputation — so no one can inherit a Trusted tier or dump signal
penalties onto a victim's score.

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/ParityHook.sol` | v4 hook: treatment matrix, delay gate, premium take, signal capture, corroborated identity resolution |
| `src/LVRReserve.sol` | Premium escrow, N-block verification with token-decimal normalization, payouts, donations, EWMA |
| `src/ReputationLedger.sol` | Per-swapper score decay, tiers, last-swap-block tracking |
| `src/libraries/SignalLib.sol` | Pure signal math (price impact, rapid-fire, size outliers) |
| `src/ChainlinkPriceAdapter.sol` | Feed normalization + staleness guard |
| `script/00_DeployParity.s.sol` | Full stack deployment incl. CREATE2-mined hook address |
| `test/` | Foundry suite (59 tests): unit, integration, verification, identity-spoofing, decimal-normalization, end-to-end |

## Quick start

```bash
forge install        # already vendored in lib/
forge test           # 59 tests across 7 suites

# Local deployment against Anvil:
anvil &
forge script script/00_DeployParity.s.sol:DeployParity \
    --rpc-url http://localhost:8545 --broadcast --private-key $KEY

# Production chains: point at canonical artifacts + a real feed
PARITY_POOL_MANAGER=0x... PARITY_FEED=0x... PARITY_NO_SEED=1 \
forge script script/00_DeployParity.s.sol:DeployParity --rpc-url $RPC --broadcast --private-key $KEY
```

The hook address is mined so its lower bits equal the declared permission flags
(before/after swap with return deltas, after add/remove liquidity), namespaced
with `"PA"` to avoid collisions. Deployment goes through Arachnid's
Deterministic Deployment Proxy, making addresses reproducible across chains.

## Partner technology integrations

1. **Uniswap v4 hooks** — the entire protocol surface.
   - Hook entry points: `_beforeSwap` / `_afterSwap`
     (`src/ParityHook.sol:166`, `src/ParityHook.sol:227`)
   - Premium extraction via `BeforeSwapDelta` on exact-input /
     `afterSwapHandler` settlement on exact-output
     (`src/ParityHook.sol:209`, `src/ParityHook.sol:227`)
   - LP registry maintained in `_afterAddLiquidity` / `_afterRemoveLiquidity`
     (`src/ParityHook.sol:289+`)
2. **Chainlink data streams** — `src/ChainlinkPriceAdapter.sol` wraps any
   `AggregatorV3Interface` feed: 18-decimal normalization, configurable
   staleness window, sentinel semantics on failure
   (`latestPrice18`, `src/ChainlinkPriceAdapter.sol:74`). The reserve treats an
   unavailable reference as *auto-unverifiable* (`LVRReserve.settlePending`),
   which is the safe default for LPs.
3. **Permit2** — used by the canonical v4 periphery for position management;
   the deploy script wires token approvals through Permit2 exactly like
   production integrators must (`script/00_DeployParity.s.sol`, `ParitySeeder`).

### Not integrated (deliberate scope)

- **Circle CCTP** was evaluated for cross-chain reserve rebalancing but is not
  part of this submission; single-chain reserves keep the trust model simple.
- **EigenLayer** restaking is roadmap: slashing-backed verification markets
  could replace the permissionless `settlePending` role in a future version.

## Originality statement

All contract code in `src/` was written from scratch for this hackathon. The
repository builds on official Uniswap v4 tooling (v4-core, v4-periphery,
hookmate artifacts) and standard open-source libraries (OpenZeppelin v5,
Solmate, Forge Standard Library) under their respective licenses. No code was
generated by copying existing hook examples beyond template wiring (deployer
harness, POSM helpers) retained from the hookmate scaffold.

## License

MIT — see [LICENSE](./LICENSE).
