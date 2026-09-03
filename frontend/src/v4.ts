import type { Address } from "viem";
import {
  PARITY_HOOK_ADDRESS,
  PARITY_POOL_FEE,
  PARITY_POOL_TICK_SPACING,
  USDC_ADDRESS,
  WETH_ADDRESS,
} from "./contracts";

/**
 * Canonical Uniswap v4 PoolKey for the Parity WETH/USDC pool.
 * v4 requires currency0 < currency1 by address: USDC (0x036C…) < WETH (0x4200…),
 * so currency0 = USDC and currency1 = WETH.
 */
export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

export function buildParityPoolKey(): PoolKey {
  return {
    currency0: USDC_ADDRESS,
    currency1: WETH_ADDRESS,
    fee: PARITY_POOL_FEE,
    tickSpacing: PARITY_POOL_TICK_SPACING,
    hooks: PARITY_HOOK_ADDRESS,
  };
}

/**
 * Informational estimate of the WETH output for an exact USDC input, using the live
 * ETH/USD reference (18-dec) and a slippage tolerance. NOT an on-chain quote — used
 * only to prefill amountOutMin so a real swap could clear.
 */
export function approxPoolWethOut(
  usdcAmountIn: bigint, // 6-dec USDC
  usdcPerWeth18: bigint, // USDC-per-WETH price, 18-dec
  slippagePct: number // e.g. 0.5
): bigint {
  if (usdcAmountIn === 0n || usdcPerWeth18 === 0n) return 0n;
  // WETH_out_18 ≈ (USDC_in * 1e18) / usdcPerWeth18
  const wethOut18 = (usdcAmountIn * 1000000000000000000n) / usdcPerWeth18;
  const denom = 10000n;
  const numer = BigInt(Math.round((10000 - slippagePct * 100)));
  const min = (wethOut18 * numer) / denom;
  return min;
}
