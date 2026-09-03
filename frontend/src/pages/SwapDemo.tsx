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
  Divider,
  Alert,
  AlertIcon,
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
          setResult(`distributeVerified(0) tx: ${h}`);
          toast({ title: "Distributed", description: h, status: "success" });
        },
      }
    );

  return (
    <Container maxW="7xl">
      <Heading size="xl" mb={1}>
        Swap Demo
      </Heading>
      <Text color="gray.500" mb={6}>
        How Parity treats a swapper — and the permissionless verification/settlement calls anyone can run.
      </Text>

      {!isConnected && (
        <Alert status="info" mb={6}>
          <AlertIcon />
          Connect a wallet to see your tier and run settlement calls.
        </Alert>
      )}

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
                No pending record yet — the deployed reserve is idle until a flagged swap is driven live.
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
        <Alert status="success">
          <AlertIcon />
          <Text fontSize="sm">{result}</Text>
        </Alert>
      )}

      <Box mb={8}>
        <SeedPoolPanel />
      </Box>

      <Box mb={8}>
        <SwapCard />
      </Box>
    </Container>
  );
}
