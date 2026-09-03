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
| `src/ParityHook.sol` | v4 hook: treatment matrix, delay gate, premium take, signal capture, corroborated identity resolution, permissionless LP-registry pruning |
| `src/LVRReserve.sol` | Premium escrow, N-block verification with token-decimal normalization, payouts, donations, EWMA, native + ERC20 idle-fund transfers, active-payout guard |
| `src/ReputationLedger.sol` | Per-swapper score decay, tiers, last-swap-block tracking |
| `src/libraries/SignalLib.sol` | Pure signal math (price impact, rapid-fire, size outliers) |
| `src/ChainlinkPriceAdapter.sol` | Feed normalization + staleness guard |
| `src/circle/CctpBridge.sol` | Circle CCTP (canonical V2) integration: burns reserve idle USDC to another domain via `TokenMessengerV2.depositForBurn`, sweeps minted USDC back into the reserve |
| `src/eigenlayer/ParityCrossPoolOracle.sol` | EigenLayer AVS consumer: quorum-verified cross-pool reputation attestations (ECDSAStakeRegistry `isValidSignature`), monotonic nonce replay protection |
| `src/eigenlayer/IECDSAStakeRegistry.sol` | ABI-faithful consumer view of EigenLayer middleware's ECDSAStakeRegistry |
| `script/00_DeployParity.s.sol` | Full stack deployment incl. CREATE2-mined hook address; optional partner modules via env vars |
| `test/` | Foundry suite (75 unit/integration tests + 2 canonical-CCTP fork tests): unit, integration, verification, identity-spoofing, decimal-normalization, CCTP rebalancing, AVS seeding, LP pruning, end-to-end |

## Quick start

```bash
forge install        # already vendored in lib/
forge test           # 75 tests across 11 suites (+2 canonical-CCTP fork tests skipped without RPC)

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

### Live deployment — Base Sepolia (testnet · chain 84532)

Deployed and verified on-chain with the canonical Circle CCTP V2 integration:

| Contract | Address |
|---|---|
| `ParityHook` | `0x95E4a3Aa11c44EB8de369830E9f956703F5585cC` |
| `LVRReserve` | `0x07fabE011c4BB617a12E33098258586fD066EcDF` |
| `ChainlinkPriceAdapter` | `0x81e9bb58e41888E4c3f9b4523d4c62290F2AAa46` |
| `CctpBridge` (V2) | `0xc3127A26Bf8f21a58e4AA5b851C886Ad6CF00Ee6` |
| PoolManager (v4) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Chainlink ETH/USD feed | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |
| Circle TokenMessengerV2 | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| USDC (Base Sepolia) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

Owner: `0x664C1791ad9189ebAEB63716d29EeCaA405c732D`. The `CctpBridge` is
authorized on the `LVRReserve` and wired to the real canonical `TokenMessengerV2`,
so `rebalance()` originates genuine CCTP V2 burns for cross-chain compensation
capital movement.

> **CCTP V2 fee-oracle robustness.** Base Sepolia's canonical `TokenMessengerV2`
> reverts its fee accessors (`getMinFeeAmount` / `minFee`) on `staticcall`.
> `CctpBridge.rebalance` therefore sizes `maxFee` via a safe `staticcall` and, when
> the oracle reverts, falls back to an owner-configured `fallbackMaxFeeFraction`
> per destination domain (a `maxFee` ceiling is always enforced strictly below
> `amount`). This is verified live by `test/CircleLiveFork.t.sol`
> (`forge test --match-path test/CircleLiveFork.t.sol --fork-url $BASE_RPC`),
> which drives the *deployed* bridge through a real `rebalance(→ Ethereum domain 0)`
> against the live messenger.

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

### Circle (CCTP, canonical V2) — integrated

`src/circle/CctpBridge.sol` rebalances the reserve's idle USDC across chains
via Circle's canonical `TokenMessengerV2` burn-and-mint transfer protocol:
`rebalance()` pulls only balances above the escrow watermark
(`LVRReserve.escrowedBalance`, enforced in `transferIdleToBridge`) and calls
`TokenMessengerV2.depositForBurn(amount, destDomain, mintRecipient, burnToken,
destinationCaller, maxFee, minFinalityThreshold)` — the current CCTP canonical
contract (CCTP V1 is legacy and phases out July 31, 2026). On arrival,
`sweepMintedUsdc()` forwards freshly minted USDC back into the reserve. No
bridge liquidity pools, custodians, or wrapped assets are trusted.

The locally-declared `ITokenMessengerV2` mirrors Circle's audited ABI exactly
(`circlefin/evm-cctp-contracts`, `docs/abis/cctp/v2.1/TokenMessengerV2.json`).
`test/CircleFork.t.sol` proves ABI compatibility against the real deployed
canonical `TokenMessengerV2` (same address on every EVM CCTP domain,
0x28b5a0e9...c8168cf5d):
- a static selector assertion runs in every CI run (no RPC required), and
- live fork assertions (`tokenMessengerV2 is live and decodes`, `USDC is
  canonical`) run when supplied a fork URL:
  `forge test --match-path test/CircleFork.t.sol --fork-url <ETH_RPC_URL>`.

The reserve's `transferIdleToBridge` separately handles native ETH via a
low-level call (the ERC20 path uses `CurrencyLibrary.transfer`), so a native
idle balance is never mis-routed through `IERC20.transfer`. Deployments wire
per-chain addresses via `PARITY_USDC` + `PARITY_TOKEN_MESSENGER` env vars;
destination domains are opened with `setDestinationDomain`. Covered by
`test/Circle.t.sol` (mock-based rebalancing, escrow-watermark protection,
native-ETH transfer) and `test/CircleFork.t.sol` (real canonical CCTP).

### EigenLayer (AVS consumer) — consumer-side integrated

Cross-pool reputation aggregation (roadmap item 1): operators of the Parity
AVS co-sign reputation attestations, and `src/eigenlayer/ParityCrossPoolOracle.sol`
verifies them on-chain against the AVS's ECDSAStakeRegistry — stake-weighted
quorum at a recent reference block, domain-separated digests
(`chainid, this, subject, score, refBlock`) so nothing replays across
deployments. A per-attestation monotonic nonce additionally prevents an old
message from being re-delivered to refresh its freshness timestamp or
overwrite a newer score (`attestReputation`, `test_replayed_attestation_is_rejected`).
The hook seeds the ledger of addresses **with no local history**
once from fresh attestations (`ReputationLedger.seedExternalScore`); locally
observed behavior always wins afterwards. The operator network itself (task
management, off-chain services) is EigenLayer infrastructure and not part of
this repo — tests simulate quorum responses against a faithful registry double
(`test/EigenLayer.t.sol`, `test/mocks/MockStakeRegistry.sol`). Production
wiring: deploy with `PARITY_STAKE_REGISTRY` pointing at the AVS's
ECDSAStakeRegistry proxy.

**Live deployment (Base Sepolia, 84532):** `ParityCrossPoolOracle` deployed at
`0xf69cb6937452B8A2110528895d4eCb72bB07283C` (owner `0x664C…c732D`,
`freshnessBlocks = 50`), via `script/03_DeployEigenLayer.s.sol`.

**ABI / live-fork wiring proof:** `test/EigenLayerLiveFork.t.sol` mirrors the
`CircleFork` proof standard. Base Sepolia is EigenLayer *destination-only* and
the full EigenLayer v1.9.0-rc.0 build (default solc 0.8.27 vs `^0.8.29` core,
tangled nested libs) cannot compile into this 0.8.30 repo, so a functional
staked quorum cannot run there; instead the test hardcodes the **audited**
registry ABI — `isValidSignature(bytes32,bytes)` → `0x1626ba7e`,
`getLastCheckpointTotalWeight()`, and the `(address[], bytes[], uint32)`
signature-data layout — and asserts our `IECDSAStakeRegistry` interface and the
oracle's digest/encoding are byte-for-byte identical, then drives a full
`attestReputation → quorum verify → seed` round through the faithful double.
Run fork-independent with `forge test --match-path test/EigenLayerLiveFork.t.sol`.

#### EigenLayer evidence (verifiable artifacts)

On-chain (Base Sepolia, 84532 — all live, tx status `0x1` success):

| Artifact | Value |
| --- | --- |
| `ParityCrossPoolOracle` | `0xf69cb6937452B8A2110528895d4eCb72bB07283C` |
| Deployment tx | `0x7b499ffababf3849577a618eb8b02c39037382611c81102ed6da7d5528a31c22` (block `0x2c2e41a`) |
| Owner | `0x664C1791ad9189ebAEB63716d29EeCaA405c732D` |
| `freshnessBlocks` | `50` |

ABI compatibility with the **audited** EigenLayer `ECDSAStakeRegistry`
(asserted by `test/EigenLayerLiveFork.t.sol`, all pass):

| Selector / layout | Value |
| --- | --- |
| `isValidSignature(bytes32,bytes)` | `0x1626ba7e` (ERC-1271 valid) |
| `getLastCheckpointTotalWeight()` | `0x314f3a49` |
| signatureData encoding | `(address[], bytes[], uint32)` |

Re-run the proof anytime: `forge test --match-path test/EigenLayerLiveFork.t.sol`
(fork-independent; suite: 79 passed / 0 failed / 3 skipped).

> **Honest scope.** This proves the AVS-*consumer* integration end-to-end:
> the oracle verifies quorum signatures using the real audited registry ABI and
> the exact encoding EigenLayer consumes. A *functional staked operator quorum*
> is operator-network infrastructure that cannot run on Base Sepolia (EigenLayer
> **destination-only** — no DelegationManager/operator staking there); the full
> real-quorum proof belongs on an Ethereum testnet (Holesky), where EigenLayer
> core is live.

### Not integrated (deliberate scope)

- **Circle Wallets / Programmable Wallets** (off-chain API products): payout
  custody stays fully on-chain by design; only the CCTP token-transfer layer
  is integrated.
- Slashing-backed verification markets replacing the permissionless
  `settlePending` role remain future work.

## Originality statement

All contract code in `src/` was written from scratch for this hackathon. The
repository builds on official Uniswap v4 tooling (v4-core, v4-periphery,
hookmate artifacts) and standard open-source libraries (OpenZeppelin v5,
Solmate, Forge Standard Library) under their respective licenses. No code was
generated by copying existing hook examples beyond template wiring (deployer
harness, POSM helpers) retained from the hookmate scaffold.

## License

MIT — see [LICENSE](./LICENSE).
