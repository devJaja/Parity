# Parity — 5-Minute Demo Video Storyboard

> Record in OBS/Loom, **real human voice only** (no AI voices — automatic
> disqualification). Keep under **5:00**. This script is ~4:30 of talking,
> leaving room for transitions.

**One-line summary to anchor everything:**
*"Parity turns LVR — loss-versus-rebalancing — from an unavoidable LP tax into a
self-funding insurance pool."*

---

## 0:00–0:45 — The problem (start on a slide)

**Visual:** title slide "Parity — Self-Funding LVR Firewall for Uniswap v4" +
the LVR diagram from README.

**Say:**
> "Every Uniswap V3/V4 LP pays a hidden tax called LVR — loss versus rebalancing.
> When ETH jumps, arbitrageurs flood in to rebalance the pool, and the LP bears
> the whole move while the arb pockets the profit. Our problem: can we make the
> extractors pay for the damage instead of the LPs?"

**Key point to land:** *"LVR is real, it's unavoidable today, and it's paid by
LPs."*

---

## 0:45–1:45 — How the hook works (slide + code peek)

**Visual:** the README flow diagram, then a 10s look at `src/ParityHook.sol`.

**Say:**
> "Parity is a Uniswap v4 hook in front of every swap. It classifies each
> swapper into a reputation tier — Trusted, Neutral, or Flagged.
> - A trusted swapper trades instantly, no fee.
> - A suspicious or flagged swapper is **de-timed**: we reject any swap that
>   would land in the same block as their previous swap — so a sandwich can no
>   longer be atomic.
> - A flagged **exact-input** swap also pays a 150 basis-point premium, which is
>   escrowed in our LVRReserve.
>
> N blocks later, we check the real Chainlink price. If the move the flagged
> trader predicted actually happened, the premium is paid pro-rata to the LPs
> who bore the risk. If it didn't, it's donated back into the pool."

**Land:** *"Extractors fund the insurance. LPs get made whole."*

---

## 1:45–3:00 — Unique execution (live repo + tests)

**Visual:** browser on the GitHub repo → `src/`, `test/`, `script/`.

**Say:**
> "This is built with the canonical Uniswap v4 periphery — real PoolManager,
> PositionManager, Permit2, and the v4 router. The verification is driven by a
> cross-pool **Chainlink** price adapter, so it works on real prices, not mocks.
>
> On top of the hook, there's a permissionless settlement layer and a
> reputation ledger that a swapper's history feeds back into — so the protocol
> learns who's toxic. We also integrated **Circle CCTP** so idle reserve USDC
> can be rebalanced across chains, and an **EigenLayer AVS consumer** that
> aggregates reputation across pools."

---

## 3:00–4:15 — Live demo (the receipts)

**Visual:** terminal running the fork tests, then the deployed frontend.

**Say:**
> "We deployed the hook, reserve, ledger and oracle live on Base Sepolia — every
> address is in the README and verified. Here's the proof, run against the
> **deployed** contracts with **real canonical WETH/USDC** and the **real**
> Chainlink feed — no mocks:"
>
> ```bash
> forge test --fork-url $BASE_RPC -vv
> HookLiveFork    — flagged swap escrows the 150bp premium; the same-block
>                   re-entry is rejected by the delay gate; settlement pays the LP.
> SeedPoolLiveFork — a real canonical pool is seeded and a real swap succeeds.
> PushLivePool     — full flow: flag → swap → escrow → settle → LP payout.
> ```
>
> "And here's the live frontend — it reads real on-chain state: your reputation
> tier, the 150bp premium, the live ETH/USD Chainlink feed, reserve config, and
> pending payouts."

---

## 4:15–4:50 — Why + close

**Visual:** impact slide.

**Say:**
> "Why this matters: parity of information shouldn't be paid for by ordinary
> LPs. Parity makes the extractors themselves fund the protection — one hook,
> self-funding, no new tokens, compatible with standard v4 routing. It turns
> LVR from a silent tax into a recoverable, LP-owned insurance pool."

**Close:** *"Parity — the self-funding LVR firewall. Thank you."*

---

## Recording checklist
- [ ] ≤ 5:00 total, human voice only
- [ ] Cover: problem / how it works / comparison / demo
- [ ] Show a real fork-test pass on screen
- [ ] Show the deployed frontend reading live state
- [ ] Say the repo is public (link in description)
- [ ] Upload to YouTube/Loom (unlisted/format accessible to judges)
