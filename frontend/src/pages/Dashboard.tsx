import React from "react";
import {
  Container,
  Heading,
  Text,
  SimpleGrid,
  StatLabel,
  StatNumber,
  StatHelpText,
  Card,
  CardHeader,
  CardBody,
  Badge,
  Flex,
  Button,
  Divider,
  Alert,
  AlertIcon,
  VStack,
} from "@chakra-ui/react";
import { useAccount, useReadContract } from "wagmi";
import {
  LVR_RESERVE_ADDRESS,
  REPUTATION_LEDGER_ABI,
  LVR_RESERVE_ABI,
  PARITY_HOOK_ABI,
  PARITY_HOOK_ADDRESS,
} from "../contracts";
import { Shield, TrendingUp, Users, Activity } from "lucide-react";
import { Link as RouterLink } from "react-router-dom";
import { formatAddress, TIER_LABELS } from "../utils/format";
import ReputationChart from "../components/ReputationChart";

export default function Dashboard() {
  const { address, isConnected } = useAccount();

  // Reputation reads (deployed ledger is discovered from the hook).
  const { data: ledgerAddr } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "ledger",
  });

  const { data: reserveAddr } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "reserve",
  });

  const { data: ownerAddr } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "owner",
  });

  const { data: premiumBps } = useReadContract({
    address: PARITY_HOOK_ADDRESS,
    abi: PARITY_HOOK_ABI,
    functionName: "flaggedPremiumBps",
  });

  const ledgerAddress = (ledgerAddr as `0x${string}`) ?? "0x";

  const { data: rawTier } = useReadContract({
    address: ledgerAddress as `0x${string}`,
    abi: REPUTATION_LEDGER_ABI,
    functionName: "tierOf",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(isConnected && address && ledgerAddress !== "0x") },
  });

  const { data: rawScore } = useReadContract({
    address: ledgerAddress as `0x${string}`,
    abi: REPUTATION_LEDGER_ABI,
    functionName: "scoreOf",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(isConnected && address && ledgerAddress !== "0x") },
  });

  const { data: lastSwapBlock } = useReadContract({
    address: ledgerAddress as `0x${string}`,
    abi: REPUTATION_LEDGER_ABI,
    functionName: "lastSwapBlock",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(isConnected && address && ledgerAddress !== "0x") },
  });

  // Reserve state
  const { data: reserveConfig } = useReadContract({
    address: LVR_RESERVE_ADDRESS,
    abi: LVR_RESERVE_ABI,
    functionName: "config",
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

  const tier = rawTier === undefined ? null : Number(rawTier);

  return (
    <Container maxW="7xl">
      <Flex direction={{ base: "column", md: "row" }} align="baseline" justify="space-between" mb={6}>
        <div>
          <Heading size="xl">Protocol Dashboard</Heading>
          <Text color="gray.500">
            Live state of the deployed ParityHook on Base Sepolia
          </Text>
        </div>
        {!isConnected && (
          <Alert status="info" mt={{ base: 3, md: 0 }} maxW="sm">
            <AlertIcon />
            Connect a wallet to see your reputation tier.
          </Alert>
        )}
      </Flex>

      <SimpleGrid columns={{ base: 1, sm: 2, lg: 4 }} spacing={5} mb={8}>
        <StatCard
          icon={<Shield size={20} />}
          label="Your Tier"
          value={tier === null ? "—" : TIER_LABELS[tier] ?? "Unknown"}
          help={isConnected ? `last swap block ${lastSwapBlock?.toString() ?? "—"}` : "connect to view"}
          badge
          tier={tier ?? undefined}
        />
        <StatCard
          icon={<Activity size={20} />}
          label="Reputation Score"
          value={rawScore === undefined ? "—" : rawScore.toString()}
          help={isConnected ? "live from ReputationLedger" : "connect to view"}
        />
        <StatCard
          icon={<TrendingUp size={20} />}
          label="Flag Premium"
          value={premiumBps === undefined ? "—" : `${premiumBps} bps`}
          help="charged on flagged exact-input swaps"
        />
        <StatCard
          icon={<Users size={20} />}
          label="Pending / Payouts"
          value={`${pendingLen?.toString() ?? "—"} / ${payoutLen?.toString() ?? "—"}`}
          help={`verify window ${reserveConfig?.[0]?.toString() ?? "—"} blocks`}
        />
      </SimpleGrid>

      <SimpleGrid columns={{ base: 1, lg: 2 }} spacing={6}>
        <Card>
          <CardHeader>
            <Heading size="md">Deployed Wiring</Heading>
          </CardHeader>
          <CardBody>
            <VStack align="stretch" spacing={3} divider={<Divider />}>
              <WireRow label="ParityHook" value={formatAddress(PARITY_HOOK_ADDRESS)} href />
              <WireRow label="LVRReserve" value={formatAddress(reserveAddr?.toString())} href />
              <WireRow label="ReputationLedger" value={formatAddress(ledgerAddr?.toString())} href />
              <WireRow label="Owner" value={formatAddress(ownerAddr?.toString())} />
            </VStack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>
            <Heading size="md">Your Reputation</Heading>
          </CardHeader>
          <CardBody>
            {!isConnected || !address ? (
              <VStack spacing={3}>
                <Text color="gray.500">Connect to see how Parity treats your swaps.</Text>
                <Button as={RouterLink} to="/swap" colorScheme="brand">
                  Go to Swap Demo
                </Button>
              </VStack>
            ) : (
              <ReputationChart
                score={rawScore === undefined ? 0n : (rawScore as bigint)}
                tier={tier ?? 0}
              />
            )}
          </CardBody>
        </Card>
      </SimpleGrid>
    </Container>
  );
}

function StatCard({
  icon,
  label,
  value,
  help,
  badge,
  tier,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  help: string;
  badge?: boolean;
  tier?: number;
}) {
  const tierColor = tier === 2 ? "red" : tier === 1 ? "yellow" : "green";
  return (
    <Card>
      <CardBody>
        <Flex align="center" gap={2} mb={2}>
          {icon}
          <StatLabel>{label}</StatLabel>
        </Flex>
        {badge ? (
          <Badge colorScheme={tierColor} fontSize="xl" px={3} py={1} borderRadius="md">
            {value}
          </Badge>
        ) : (
          <StatNumber fontSize="2xl">{value}</StatNumber>
        )}
        <StatHelpText mb={0}>{help}</StatHelpText>
      </CardBody>
    </Card>
  );
}

function WireRow({ label, value, href }: { label: string; value: string; href?: boolean }) {
  return (
    <Flex justify="space-between">
      <Text fontWeight="medium" color="gray.500">
        {label}
      </Text>
      {href && value !== "—" ? (
        <Text fontWeight="medium" color="brand.500">
          {value}
        </Text>
      ) : (
        <Text fontWeight="medium">{value}</Text>
      )}
    </Flex>
  );
}
