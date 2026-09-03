import { type Address } from "viem";

// ---- Live Base Sepolia (84532) deployment ----
export const PARITY_HOOK_ADDRESS: Address =
  "0x95E4a3Aa11c44EB8de369830E9f956703F5585cC";
export const LVR_RESERVE_ADDRESS: Address =
  "0x07fabE011c4BB617a12E33098258586fD066EcDF";
export const CHAINLINK_ADAPTER_ADDRESS: Address =
  "0x81e9bb58e41888E4c3f9b4523d4c62290F2AAa46";
export const OWNER_ADDRESS: Address =
  "0x664C1791ad9189ebAEB63716d29EeCaA405c732D";

export const CHAIN_ID = 84532;
export const RPC_URL = "https://sepolia.base.org";

// ---- Canonical Uniswap v4 + Circle addresses on Base Sepolia (84532) ----
export const V4_POOL_MANAGER_ADDRESS: Address =
  "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408";
export const V4_SWAP_ROUTER_ADDRESS: Address =
  "0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9";
export const PERMIT2_ADDRESS: Address =
  "0x000000000022D473030F116dDEE9F6B43aC78BA3";
export const USDC_ADDRESS: Address =
  "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; // 6-decimal FiatToken
export const WETH_ADDRESS: Address =
  "0x4200000000000000000000000000000000000006"; // 18-dec

// Canonical Parity WETH/USDC pool: currency0 (USDC) < currency1 (WETH).
export const PARITY_POOL_FEE = 3000;
export const PARITY_POOL_TICK_SPACING = 60;

export const PARITY_HOOK_ABI = [
  {
    type: "function",
    name: "ledger",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "reserve",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "crossPoolOracle",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "owner",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "flaggedPremiumBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "flaggedExtraGapBlocks",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint32" }],
  },
] as const;

export const REPUTATION_LEDGER_ABI = [
  {
    type: "function",
    name: "scoreOf",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "int256" }],
  },
  {
    type: "function",
    name: "tierOf",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "lastSwapBlock",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "hasHistory",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "bool" }],
  },
] as const;

export const LVR_RESERVE_ABI = [
  {
    type: "function",
    name: "hook",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "priceAdapter",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "config",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint32", name: "verifyBlocks" },
      { type: "uint256", name: "minNoiseBps" },
      { type: "uint256", name: "maxNoiseBps" },
      { type: "uint64", name: "ewmaNum" },
      { type: "uint64", name: "ewmaDen" },
    ],
  },
  {
    type: "function",
    name: "pendingsLength",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getPending",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [
      { type: "bytes32", name: "poolId" },
      { type: "address", name: "currency" },
      { type: "uint256", name: "amount" },
      { type: "uint160", name: "sqrtPriceT0" },
      { type: "uint256", name: "refPriceT0_18" },
      { type: "bool", name: "zeroForOne" },
      { type: "uint128", name: "liquidityAtBlock" },
      { type: "uint64", name: "recordedBlock" },
    ],
  },
  {
    type: "function",
    name: "settlePending",
    stateMutability: "nonpayable",
    inputs: [{ type: "uint256" }],
    outputs: [{ type: "bool", name: "verified" }],
  },
  {
    type: "function",
    name: "payoutsLength",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "activePayouts",
    stateMutability: "view",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "escrowedBalance",
    stateMutability: "view",
    inputs: [{ type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "distributeVerified",
    stateMutability: "nonpayable",
    inputs: [
      { type: "uint256" },
      { type: "uint256", name: "maxBatch" },
    ],
    outputs: [
      { type: "uint256", name: "paid" },
      { type: "bool", name: "complete" },
    ],
  },
] as const;

export const CHAINLINK_ADAPTER_ABI = [
  {
    type: "function",
    name: "feed",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "maxStalenessSeconds",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "latestPrice18",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint256", name: "price18" },
      { type: "uint256", name: "updatedAt" },
    ],
  },
] as const;

export const AGGREGATOR_V3_ABI = [
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
  {
    type: "function",
    name: "description",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint80", name: "roundId" },
      { type: "int256", name: "answer" },
      { type: "uint256", name: "startedAt" },
      { type: "uint256", name: "updatedAt" },
      { type: "uint80", name: "answeredInRound" },
    ],
  },
] as const;

// ---- Canonical Uniswap v4 router (IUniswapV4Router04 single-pool) ----
export const V4_SWAP_ROUTER_ABI = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { type: "uint256", name: "amountIn" },
      { type: "uint256", name: "amountOutMin" },
      { type: "bool", name: "zeroForOne" },
      {
        type: "tuple",
        components: [
          { type: "address", name: "currency0" },
          { type: "address", name: "currency1" },
          { type: "uint24", name: "fee" },
          { type: "int24", name: "tickSpacing" },
          { type: "address", name: "hooks" },
        ],
        name: "poolKey",
      },
      { type: "bytes", name: "hookData" },
      { type: "address", name: "receiver" },
      { type: "uint256", name: "deadline" },
    ],
    outputs: [{ type: "int128" }, { type: "int128" }],
  },
] as const;

// ---- Permit2 AllowanceTransfer (approve + transferFrom) ----
export const PERMIT2_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { type: "address", name: "token" },
      { type: "address", name: "spender" },
      { type: "uint160", name: "amount" },
      { type: "uint48", name: "expiration" },
    ],
    outputs: [],
  },
] as const;

// ---- Generic ERC20 (approve, allowance, balanceOf) ----
export const ERC20_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { type: "address", name: "spender" },
      { type: "uint256", name: "amount" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { type: "address", name: "owner" },
      { type: "address", name: "spender" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ type: "address", name: "account" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
] as const;

