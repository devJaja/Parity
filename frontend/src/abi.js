// Minimal ABIs for the live Base Sepolia (84532) Parity deployment.
// Field/return layouts mirror src/ exactly.

export const ParityHookAbi = [
  "function ledger() view returns (address)",
  "function reserve() view returns (address)",
  "function crossPoolOracle() view returns (address)",
  "function owner() view returns (address)",
  "function flaggedPremiumBps() view returns (uint24)",
  "function flaggedExtraGapBlocks() view returns (uint32)",
];

export const LVRReserveAbi = [
  "function hook() view returns (address)",
  "function priceAdapter() view returns (address)",
  "function config() view returns (uint32 verifyBlocks,uint256 minNoiseBps,uint256 maxNoiseBps,uint64 ewmaNum,uint64 ewmaDen)",
  "function pendingsLength() view returns (uint256)",
  "function getPending(uint256 i) view returns (bytes32 poolId,address currency,uint256 amount,uint160 sqrtPriceT0,uint256 refPriceT0_18,bool zeroForOne,uint128 liquidityAtBlock,uint64 recordedBlock)",
  "function settlePending(uint256 i) returns (bool verified)",
  "function payoutsLength() view returns (uint256)",
  "function activePayouts(bytes32 poolId) view returns (uint256)",
  "function escrowedBalance(address currency) view returns (uint256)",
  "function distributeVerified(uint256 i,uint256 maxBatch) returns (uint256 paid,bool complete)",
];

export const ReputationLedgerAbi = [
  "function scoreOf(address) view returns (int256)",
  "function tierOf(address) view returns (uint8)",
  "function lastSwapBlock(address) view returns (uint64)",
  "function hasHistory(address) view returns (bool)",
];

export const ChainlinkAdapterAbi = [
  "function feed() view returns (address)",
  "function maxStalenessSeconds() view returns (uint256)",
  "function latestPrice18() view returns (uint256 price18,uint256 updatedAt)",
];

export const AggregatorV3Abi = [
  "function decimals() view returns (uint8)",
  "function description() view returns (string)",
  "function latestRoundData() view returns (uint80 roundId,uint256 answer,int256 startedAt,uint256 updatedAt,uint80 answeredInRound)",
];
