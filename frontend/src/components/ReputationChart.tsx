import {
  Box,
  VStack,
  Text,
  HStack,
  Badge,
} from "@chakra-ui/react";

const TIER_COLOR = ["green", "yellow", "red"] as const;
const TIER_LABEL = ["Trusted", "Neutral", "Flagged"] as const;

export default function ReputationChart({
  score,
  tier,
}: {
  score: bigint;
  tier: number;
}) {
  const s = Number(score);
  // Map the arbitrary score domain onto 0..100 for the gauge.
  const LOW = -500;
  const HIGH = 1000;
  const pct = Math.min(100, Math.max(0, ((s - LOW) / (HIGH - LOW)) * 100));

  const flaggedBoundary = ((300 - LOW) / (HIGH - LOW)) * 100;
  const neutralBoundary = ((700 - LOW) / (HIGH - LOW)) * 100;

  return (
    <VStack align="stretch" spacing={4}>
      <HStack justify="space-between">
        <Text fontSize="lg" fontWeight="bold">
          {s}
        </Text>
        <Badge colorScheme={TIER_COLOR[tier]} fontSize="md" px={2}>
          {TIER_LABEL[tier] ?? "Unknown"}
        </Badge>
      </HStack>

      <Box position="relative" h={3} borderRadius="full" overflow="hidden">
        {/* tier bands */}
        <Box position="absolute" inset="0" bg="red.500" width={`${flaggedBoundary}%`} />
        <Box
          position="absolute"
          top="0"
          bottom="0"
          bg="yellow.500"
          left={`${flaggedBoundary}%`}
          width={`${neutralBoundary - flaggedBoundary}%`}
        />
        <Box
          position="absolute"
          top="0"
          bottom="0"
          bg="green.500"
          left={`${neutralBoundary}%`}
          width={`${100 - neutralBoundary}%`}
        />
        {/* score marker */}
        <Box
          position="absolute"
          top="-3px"
          bottom="-3px"
          width="4px"
          bg="white"
          boxShadow="0 0 0 2px rgba(0,0,0,0.4)"
          left={`calc(${pct}% - 2px)`}
          borderRadius="full"
        />
      </Box>

      <HStack justify="space-between" fontSize="xs" color="gray.500">
        <Text>Flagged &lt; 300</Text>
        <Text>Neutral ≥ 300</Text>
        <Text>Trusted ≥ 700</Text>
      </HStack>

      <Text fontSize="sm" color="gray.500">
        Swap behaviors (price impact, rapid-fire, size outliers) move this score. A confirmed one-sided
        drift in the flagged direction pays LPs; neutral &amp; flagged flow are ordering-delayed, and
        flagged exact-input swaps pay a premium. Identity is corroborated via <code>tx.origin</code> or an
        authorized router.
      </Text>
    </VStack>
  );
}
