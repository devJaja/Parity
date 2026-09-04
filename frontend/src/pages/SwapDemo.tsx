import { useState } from "react";
import {
  Container,
  Heading,
  Text,
  Card,
  CardHeader,
  CardBody,
  SimpleGrid,
  VStack,
  HStack,
  Badge,
  Button,
  Code,
  Divider,
  Alert,
  AlertIcon,
  AlertDescription,
  Stat,
  StatLabel,
  StatNumber,
  StatHelpText,
  useToast,
  Box,
} from "@chakra-ui/react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
} from "wagmi";
import {
  PARITY_HOOK_ADDRESS,
  PARITY_HOOK_ABI,
  LVR_RESERVE_ADDRESS,
  LVR_RESERVE_ABI,
  REPUTATION_LEDGER_ABI,
} from "../contracts";
import { formatAddress, TIER_LABELS } from "../utils/format";
import SwapCard from "../components/SwapCard";
import SeedPoolPanel from "../components/SeedPoolPanel";

export default function SwapDemo() {
  const { address, isConnected } = useAccount();
  const toast = useToast();
  const [result, setResult] = useState<string | null>(null);

  const { data: ledgerAddr } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "ledger",
  });
  const { data: premiumBps } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "flaggedPremiumBps",
  });

  const ledgerAddress = (ledgerAddr as `0x${string}`) ?? "0x";
  const hasWallet = Boolean(isConnected && address && ledgerAddress !== "0x");

  const { data: rawTier } = useReadContract({
    address: ledgerAddress as `0x${string}`,
    abi: REPUTATION_LEDGER_ABI,
    functionName: "tierOf",
    args: [address as `0x${string}`],
    query: { enabled: hasWallet },
  });
  const { data: lastSwapBlock } = useReadContract({
    address: ledgerAddress as `0x${string}`,
    abi: REPUTATION_LEDGER_ABI,
    functionName: "lastSwapBlock",
    args: [address as `0x${string}`],
    query: { enabled: hasWallet },
  });

  const { data: pendingLen } = useReadContract({
    address: LVR_RESERVE_ADDRESS,
    abi: LVR_RESERVE_ABI,
    functionName: "pendingsLength",
  });
  const { data: payoutLen } = useReadContract({
    address: LVR_RESERVE_ADDRESS,
    abi: LVR_RESERVE_ABI,
    functionName: "payoutsLength",
  });
  const { data: pending0 } = useReadContract({
    address: LVR_RESERVE_ADDRESS,
    abi: LVR_RESERVE_ABI,
    functionName: "getPending",
    args: [0n],
    query: { enabled: Boolean(pendingLen && pendingLen > 0n) },
  });

  const tier = rawTier === undefined ? null : Number(rawTier);
  const treatment =
    tier === null
      ? "—"
      : tier === 0
      ? "Trusted → instant execution, no fee"
      : tier === 1
      ? "Neutral → ordering delay (1 block)"
      : `Flagged → delay + ${premiumBps?.toString() ?? "150"} bps premium`;

  const { writeContract: writeSettle, isPending: settling } = useWriteContract();
  const { writeContract: writeDistribute, isPending: distributing } = useWriteContract();

  const doSettle = () =>
    writeSettle(
      {
        address: LVR_RESERVE_ADDRESS,
        abi: LVR_RESERVE_ABI,
        functionName: "settlePending",
        args: [0n],
      },
      {
        onError: (e) => toast({ title: "Settle failed", description: e?.message ?? "Unknown error", status: "error" }),
        onSuccess: (h) => {
          setResult(`settlePending(0) tx: ${h}`);
          toast({ title: "Settled", description: h, status: "success" });
        },
      }
    );

  const doDistribute = () =>
    writeDistribute(
      {
        address: LVR_RESERVE_ADDRESS,
        abi: LVR_RESERVE_ABI,
        functionName: "distributeVerified",
        args: [0n, 100n],
      },
      {
        onError: (e) => toast({ title: "Distribute failed", description: e?.message ?? "Unknown error", status: "error" }),
        onSuccess: (h) => {
          setResult(`distributeVerified(0,100) tx: ${h}`);
          toast({ title: "Distributed", description: h, status: "success" });
        },
      }
    );

  return (
    <Container maxW="7xl">
      <Heading size="xl" mb={1}>
        Treatment &amp; Settlement
      </Heading>
      <Text color="gray.500" mb={6}>
        How Parity treats swappers — and the permissionless verification/settlement anyone can run.
      </Text>

      {/* ── Hero: Live Proof ───────────────────────────────────────── */}
      <Card mb={8} borderLeft="4px solid" borderColor="green.400">
        <CardHeader pb={2}>
          <HStack>
            <Heading size="md">Live Proof — Fork Tests</Heading>
            <Badge colorScheme="green">verified on Base Sepolia</Badge>
          </HStack>
        </CardHeader>
        <CardBody pt={0}>
          <Text fontSize="sm" color="gray.500" mb={3}>
            Every test below drives the <strong>deployed</strong> ParityHook / LVRReserve / ReputationLedger
            with <strong>real canonical WETH/USDC</strong> on a Base Sepolia fork. No mocks.
          </Text>
          <SimpleGrid columns={{ base: 1, md: 3 }} spacing={3}>
            <ProofCard
              title="HookLiveFork"
              items={[
                "Flagged swap escrows 150 bps premium",
                "Same-block re-entry rejected by delay gate",
                "Settlement pays LP after verify window",
              ]}
            />
            <ProofCard
              title="SeedPoolLiveFork"
              items={[
                "Seeds real canonical WETH/USDC pool",
                "Post-seed swap succeeds (no revert)",
                "Proves live swaps are functional",
              ]}
            />
            <ProofCard
              title="PushLivePool"
              items={[
                "Full treatment: flag → swap → escrow → settle",
                "Real Chainlink ETH/USD feed",
                "LP payout after verified drift",
              ]}
            />
          </SimpleGrid>
          <Text fontSize="xs" color="gray.400" mt={3}>
            Run all three:{" "}
            <Code fontSize="xs">forge test --fork-url $BASE_RPC -vv</Code>{" "}
            — 86 unit/integration + 6 fork proofs pass.
          </Text>
        </CardBody>
      </Card>

      {/* ── Treatment + Settlement ─────────────────────────────────── */}
      <SimpleGrid columns={{ base: 1, md: 2 }} spacing={6} mb={8}>
        <Card>
          <CardHeader>
            <Heading size="md">Your Treatment</Heading>
          </CardHeader>
          <CardBody>
            <VStack align="stretch" spacing={4} divider={<Divider />}>
              <Stat>
                <StatLabel>Tier</StatLabel>
                <StatNumber>
                  {tier === null ? (
                    "—"
                  ) : (
                    <Badge
                      colorScheme={tier === 2 ? "red" : tier === 1 ? "yellow" : "green"}
                      fontSize="xl"
                      px={3}
                      py={1}
                      borderRadius="md"
                    >
                      {TIER_LABELS[tier]}
                    </Badge>
                  )}
                </StatNumber>
                <StatHelpText>
                  last swap block: {lastSwapBlock?.toString() ?? "—"}
                </StatHelpText>
              </Stat>
              <VStack align="stretch" spacing={1}>
                <Text fontWeight="semibold">Applied treatment</Text>
                <Text>{treatment}</Text>
              </VStack>
              <VStack align="stretch" spacing={1}>
                <Text fontWeight="semibold">Why it matters</Text>
                <Text fontSize="sm" color="gray.500">
                  A neutral/flagged swapper can still trade, but not twice in the same block — so both
                  sandwich legs cannot be atomic. Flagged exact-input swaps also pay a{" "}
                  <strong>{premiumBps?.toString() ?? "150"} bps</strong> premium that is escrowed for
                  verification.
                </Text>
              </VStack>
            </VStack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>
            <Heading size="md">Reserve Verification / Settlement</Heading>
          </CardHeader>
          <CardBody>
            <SimpleGrid columns={2} spacing={4} mb={4}>
              <Stat>
                <StatLabel>Pending records</StatLabel>
                <StatNumber>{pendingLen?.toString() ?? "—"}</StatNumber>
              </Stat>
              <Stat>
                <StatLabel>Active payouts</StatLabel>
                <StatNumber>{payoutLen?.toString() ?? "—"}</StatNumber>
              </Stat>
            </SimpleGrid>

            {pendingLen && pendingLen > 0n && pending0 ? (
              <VStack align="stretch" spacing={1} mb={4} fontSize="sm">
                <Text fontWeight="semibold">Pending #0</Text>
                <Text color="gray.500">
                  currency {formatAddress((pending0[1] as `0x${string}`)?.toLowerCase() as `0x${string}`)} ·{" "}
                  amount {pending0[2].toString()} · recorded block {pending0[7].toString()}
                </Text>
              </VStack>
            ) : (
              <Text color="gray.500" fontSize="sm" mb={4}>
                No pending record yet — the deployed reserve records premium escrows from flagged swaps
                on the live pool.
              </Text>
            )}

            <HStack spacing={3} wrap="wrap">
              <Button
                colorScheme="brand"
                onClick={doSettle}
                isLoading={settling}
                isDisabled={!isConnected || !pendingLen || pendingLen === 0n}
              >
                settlePending(0)
              </Button>
              <Button
                colorScheme="teal"
                onClick={doDistribute}
                isLoading={distributing}
                isDisabled={!isConnected || !payoutLen || payoutLen === 0n}
              >
                distributeVerified(0)
              </Button>
            </HStack>
            <Text mt={3} fontSize="xs" color="gray.500">
              Both calls are permissionless — any wallet can settle a lapsed verification window or pay
              out eligible LPs.
            </Text>
          </CardBody>
        </Card>
      </SimpleGrid>

      {result && (
        <Alert status="success" mb={6}>
          <AlertIcon />
          <Text fontSize="sm">{result}</Text>
        </Alert>
      )}

      {/* ── Canonical V4 Swap (ready for when pool is seeded) ──── */}
      <Box mb={8}>
        <Card>
          <CardHeader>
            <Heading size="md">Canonical V4 Swap — Ready for Live Pool</Heading>
          </CardHeader>
          <CardBody>
            <Alert status="info" mb={4}>
              <AlertIcon />
              <AlertDescription>
                This swap form is fully wired to the live canonical Uniswap v4 router on Base Sepolia
                (real Permit2 + real router + real hookData). It will work the instant the pool is seeded
                via the owner-only Seed Pool panel below. The full flow is proven on fork.
              </AlertDescription>
            </Alert>
            <SwapCard />
          </CardBody>
        </Card>
      </Box>

      <Box mb={8}>
        <SeedPoolPanel />
      </Box>
    </Container>
  );
}

function ProofCard({ title, items }: { title: string; items: string[] }) {
  return (
    <VStack
      align="stretch"
      bg="gray.800"
      borderRadius="md"
      p={3}
      spacing={2}
    >
      <Text fontWeight="bold" fontSize="sm" color="green.300">
        {title}
      </Text>
      {items.map((item, i) => (
        <HStack key={i} align="start" spacing={2}>
          <Text color="green.400" fontSize="xs" mt="2px">✓</Text>
          <Text fontSize="xs" color="gray.300">{item}</Text>
        </HStack>
      ))}
    </VStack>
  );
}
