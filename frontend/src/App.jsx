import { useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, formatUnits } from "ethers";
import {
  ParityHookAbi,
  LVRReserveAbi,
  ReputationLedgerAbi,
  ChainlinkAdapterAbi,
  AggregatorV3Abi,
} from "./abi.js";

const CHAIN_ID = 84532;
const PARITY_HOOK = "0x95E4a3Aa11c44EB8de369830E9f956703F5585cC";
const LVR_RESERVE = "0x07fabE011c4BB617a12E33098258586fD066EcDF";
const CHAINLINK_ADAPTER = "0x81e9bb58e41888E4c3f9b4523d4c62290F2AAa46";
const BASE_SEPOLIA_RPC = "https://sepolia.base.org";

const ETHERSCAN = (addr) => `https://sepolia.basescan.org/address/${addr}`;
const TIERS = ["Trusted", "Neutral", "Flagged"];

function short(addr) {
  if (!addr) return "";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export default function App() {
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [account, setAccount] = useState(null);
  const [chain, setChain] = useState(0);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState("");
  const [refreshKey, setRefreshKey] = useState(0);
  const [toast, setToast] = useState(null);

  // ---- read-only chain state ----
  const [state, setState] = useState(null);

  const readContract = useMemo(() => {
    if (!provider) return null;
    return new Contract(PARITY_HOOK, ParityHookAbi, provider);
  }, [provider]);

  const refresh = () => setRefreshKey((k) => k + 1);

  async function connect() {
    try {
      const eth = window.ethereum;
      if (!eth) throw new Error("No EIP-1193 wallet found (install MetaMask/Rainbow)");
      const p = new BrowserProvider(eth);
      const accounts = await eth.request({ method: "eth_requestAccounts" });
      const s = await p.getSigner(accounts[0]);
      const net = await p.getNetwork();
      setProvider(p);
      setSigner(s);
      setAccount(accounts[0]);
      setChain(Number(net.chainId));
    } catch (e) {
      setError(e.message);
    }
  }

  // Load all live state when a read provider is available.
  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!readContract) return;
      try {
        const [ledgerAddr, reserveAddr, oracle, owner, premiumBps, gap] = await Promise.all([
          readContract.ledger(),
          readContract.reserve(),
          readContract.crossPoolOracle(),
          readContract.owner(),
          readContract.flaggedPremiumBps(),
          readContract.flaggedExtraGapBlocks(),
        ]);
        const reserve = new Contract(reserveAddr, LVRReserveAbi, provider);
        const chainlinkAdapter = new Contract(CHAINLINK_ADAPTER, ChainlinkAdapterAbi, provider);
        const [feedAddr, maxStaleness, cell] = await Promise.all([
          chainlinkAdapter.feed(),
          chainlinkAdapter.maxStalenessSeconds(),
          chainlinkAdapter.latestPrice18(),
        ]);
        const [price18, updatedAt] = cell;
        const feed = new Contract(feedAddr, AggregatorV3Abi, provider);
        const [feedDecimals, feedDesc] = await Promise.all([
          feed.decimals(),
          feed.description(),
        ]);
        const priceDisplay = price18 > 0n
          ? parseFloat(formatUnits(price18, 18)).toFixed(2)
          : null;
        const [pendingLen, payoutLen] = await Promise.all([
          reserve.pendingsLength(),
          reserve.payoutsLength(),
        ]);
        const cfg = await reserve.config();

        // per-wallet view
        let ledger = null;
        let wallet = null;
        if (account) {
          ledger = new Contract(ledgerAddr, ReputationLedgerAbi, provider);
          const [score, tier, lastBlock, hasHistory] = await Promise.all([
            ledger.scoreOf(account),
            ledger.tierOf(account),
            ledger.lastSwapBlock(account),
            ledger.hasHistory(account),
          ]);
          wallet = {
            score,
            tier: Number(tier),
            lastBlock: Number(lastBlock),
            hasHistory,
          };
        }

        if (!cancelled) {
          setState({
            ledgerAddr,
            reserveAddr,
            oracle,
            owner,
            premiumBps: Number(premiumBps),
            gap: Number(gap),
            feedAddr,
            maxStaleness: Number(maxStaleness),
            feedDecimals: Number(feedDecimals),
            feedDesc,
            price18,
            priceDisplay,
            updatedAt: Number(updatedAt),
            pendingLen: Number(pendingLen),
            payoutLen: Number(payoutLen),
            config: {
              verifyBlocks: Number(cfg[0]),
              minNoiseBps: Number(cfg[1]),
              maxNoiseBps: Number(cfg[2]),
            },
            wallet,
          });
        }
      } catch (e) {
        if (!cancelled) setError(`Load failed: ${e.message}`);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [readContract, provider, account, refreshKey]);

  async function tx(fn, label) {
    try {
      setError(null);
      setToast({ kind: "pending", text: `Submitting: ${label}` });
      setBusy(label);
      await fn();
      setToast({ kind: "ok", text: `Done: ${label}` });
      refresh();
    } catch (e) {
      const msg = e?.shortMessage || e?.info?.error?.message || e.message;
      setToast({ kind: "err", text: `${label} failed: ${msg}` });
    } finally {
      setBusy("");
      setTimeout(() => setToast(null), 8000);
    }
  }

  async function settle(i) {
    const reserve = new Contract(LVR_RESERVE, LVRReserveAbi, signer);
    const txr = await reserve.settlePending(i);
    await txr.wait();
  }

  async function distribute(i, batch = 100) {
    const reserve = new Contract(LVR_RESERVE, LVRReserveAbi, signer);
    const txr = await reserve.distributeVerified(i, batch);
    await txr.wait();
  }

  // ---- render ----
  return (
    <div className="wrap">
      <header>
        <div>
          <h1>Parity</h1>
          <p className="tagline">Self-funding LVR firewall for Uniswap v4 · live on Base Sepolia</p>
        </div>
        <button className="connect" onClick={connect}>
          {account ? short(account) : "Connect wallet"}
        </button>
      </header>

      {chain !== 0 && chain !== CHAIN_ID && (
        <p className="warn">Wrong network — switch MetaMask to Base Sepolia (chain {CHAIN_ID}).</p>
      )}
      {error && <p className="err">{error}</p>}
      {toast && <p className={`toast ${toast.kind}`}>{toast.text}</p>}

      <main>
        <Section title="Deployed wiring">
          <Row k="ParityHook" v={<a href={ETHERSCAN(PARITY_HOOK)}>{short(PARITY_HOOK)}</a>} />
          <Row k="LVRReserve" v={state && <a href={ETHERSCAN(state.reserveAddr)}>{short(state.reserveAddr)}</a>} />
          <Row k="ReputationLedger" v={state && <a href={ETHERSCAN(state.ledgerAddr)}>{short(state.ledgerAddr)}</a>} />
          <Row k="Cross-pool oracle" v={state && (state.oracle === "0x0000000000000000000000000000000000000000" ? "—" : <a href={ETHERSCAN(state.oracle)}>{short(state.oracle)}</a>)} />
          <Row k="Owner" v={state && short(state.owner)} />
          <Row k="Flagged premium" v={state ? `${state.premiumBps} bps (+${state.gap} extra gap block)` : "…"} />
        </Section>

        <Section title="Chainlink reference (non-circular anchor)">
          <Row k="Feed (ETH/USD)" v={state && <a href={ETHERSCAN(state.feedAddr)}>{short(state.feedAddr)}</a>} />
          <Row k="Description" v={state?.feedDesc} />
          <Row k="Live price" v={state ? `$${state.priceDisplay}` : "…"} />
          <Row k="Staleness guard" v={state ? `${state.maxStaleness}s` : "…"} />
        </Section>

        <Section title="LVRReserve (verification)">
          <Row
            k="Verify window"
            v={state ? `${state.config.verifyBlocks} blocks · noise ${state.config.minNoiseBps}–${state.config.maxNoiseBps} bps` : "…"}
          />
          <Row k="Pending records" v={state ? String(state.pendingLen) : "…"} />
          <Row k="Active payouts" v={state ? String(state.payoutLen) : "…"} />

          <div className="actions">
            <button disabled={!signer || busy || !state?.pendingLen} onClick={() => tx(() => settle(0), "settlePending(0)")}>
              settlePending(0)
            </button>
            <button disabled={!signer || busy || !state?.payoutLen} onClick={() => tx(() => distribute(0), "distributeVerified(0)")}>
              distributeVerified(0)
            </button>
            <button className="ghost" disabled={!readContract} onClick={refresh}>↻ refresh</button>
          </div>
          <p className="hint">settlePending / distributeVerified are permissionless — any wallet can settle a lapsed window or pay out eligible LPs.</p>
        </Section>

        <Section title="Your reputation on this pool">
          {account ? (
            state?.wallet ? (
              <>
                <Row k="Tier" v={<TierBadge tier={state.wallet.tier} />} />
                <Row k="Score" v={String(state.wallet.score)} />
                <Row k="Last swap block" v={String(state.wallet.lastBlock)} />
                <Row k="Treatment" v={treatmentLabel(state.wallet, state)} />
              </>
            ) : (
              <p className="hint">Loading your on-chain reputation…</p>
            )
          ) : (
            <p className="hint">Connect a wallet to see the tier Parity assigns and the delay applied to your swaps.</p>
          )}
        </Section>
      </main>

      <footer>
        <p>
          Read-only dashboard + permissionless governance calls. Swapping itself goes through the
          standard Uniswap v4 router and is protected by the hook automatically — no frontend required.
        </p>
      </footer>
    </div>
  );
}

function treatmentLabel(w, state) {
  const tier = TIERS[w.tier];
  if (tier === "Trusted") return "instant execution, no fee";
  if (tier === "Flagged") return `delayed + ${state.premiumBps} bps premium`;
  return "delayed 1 block";
}

function TierBadge({ tier }) {
  const cls = TIERS[tier]?.toLowerCase();
  return <span className={`badge ${cls}`}>{TIERS[tier] ?? "Unknown"}</span>;
}

function Section({ title, children }) {
  return (
    <div className="card">
      <h2>{title}</h2>
      <div className="rows">{children}</div>
    </div>
  );
}

function Row({ k, v }) {
  return (
    <div className="row">
      <span className="k">{k}</span>
      <span className="v">{v ?? "…"}</span>
    </div>
  );
}
