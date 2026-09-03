export function formatAddress(address?: `0x${string}` | string | null): string {
  if (!address) return "—";
  const a = address.startsWith("0x") ? address : `0x${address}`;
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function formatUsd(price18?: bigint | null, decimals = 2): string {
  if (price18 === undefined || price18 === null) return "—";
  const asNumber = Number(price18) / 1e18;
  return `$${asNumber.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`;
}

export const TIER_LABELS = ["Trusted", "Neutral", "Flagged"] as const;
