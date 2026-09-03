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
