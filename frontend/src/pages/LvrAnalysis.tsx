import {
  Container,
  Heading,
  Text,
  Card,
  CardHeader,
  CardBody,
  SimpleGrid,
  VStack,
  Stat,
  StatLabel,
  StatNumber,
  Alert,
  AlertIcon,
} from "@chakra-ui/react";
import { useReadContract } from "wagmi";
import {
  LVR_RESERVE_ADDRESS,
  LVR_RESERVE_ABI,
  CHAINLINK_ADAPTER_ADDRESS,
  CHAINLINK_ADAPTER_ABI,
} from "../contracts";
import { formatUsd } from "../utils/format";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ReferenceLine,
  ResponsiveContainer,
  BarChart,
  Bar,
} from "recharts";

const STEPS = [
  {
    title: "1 · Flagged swap escrows premium",
    body: "A flagged exact-input swap books its premium + a snapshot (execution price, Chainlink reference, direction, active liquidity) into LVRReserve.",
  },
  {
    title: "2 · N-block verification window",
    body: "After verifyBlocks elapse, anyone calls settlePending(i). No re-entry is possible within the window (the delay gate already blocks same-block legs).",
  },
  {
    title: "3 · Drift vs noise floor (EWMA)",
    body: "The pool's realized drift is compared to the pre-trade deviation plus an adaptive noise floor — an EWMA of recent observed drift, clamped to [minNoiseBps, maxNoiseBps].",
  },
  {
    title: "4 · Verified → payout, else donated",
    body: "Drift beyond noise in the swapper's favor ⇒ verified: the escrow becomes a pro-rata payout to affected LPs. Otherwise it is donated back to in-range LPs and the outcome trains the threshold. Oracle failure ⇒ auto-unverified ⇒ donated, never stuck.",
  },
];

export default function LvrAnalysis() {
  const { data: cfg } = useReadContract({
    address: LVR_RESERVE_ADDRESS,
    abi: LVR_RESERVE_ABI,
    functionName: "config",
  });
  const { data: priceCell } = useReadContract({
    address: CHAINLINK_ADAPTER_ADDRESS,
    abi: CHAINLINK_ADAPTER_ABI,
    functionName: "latestPrice18",
  });
  const price18 = priceCell?.[0];

  const verifyBlocks = cfg?.[0]?.toString() ?? "—";
  const minNoise = cfg?.[1] === undefined ? 20 : Number(cfg[1]);
  const maxNoise = cfg?.[2]?.toString() ?? "—";
  const ewmaNum = cfg?.[3]?.toString() ?? "—";
  const ewmaDen = cfg?.[4]?.toString() ?? "—";

  // Illustrative EWMA noise-floor chart (constant params, conceptual).
  const noiseData = Array.from({ length: 30 }, (_, i) => ({
    block: i,
    threshold: 20 + Math.round(6 * Math.sin(i / 3)),
    observed: 15 + Math.round(14 * Math.sin((i + 1) / 2.5)),
  }));

  const verifiedBar = [
    { name: "in-window", verified: 0, unverified: 0 },
    { name: "drift > noise", verified: 1, unverified: 0 },
    { name: "drift ≤ noise", verified: 0, unverified: 1 },
  ];

  return (
    <Container maxW="7xl">
      <Heading size="xl" mb={1}>
        LVR Analysis
      </Heading>
      <Text color="gray.500" mb={6}>
        How Parity decides whether confirmed toxicity pays — live parameters from the deployed reserve.
      </Text>

      <Alert status="info" mb={6}>
        <AlertIcon />
        Verification is permissionless and oracle-anchored. Oracle downtime degrades to
        <strong>&nbsp;auto-unverified&nbsp;</strong> (donated), never stuck.
      </Alert>

      <SimpleGrid columns={{ base: 1, md: 4 }} spacing={5} mb={6}>
        <StatCard label="Verify window" value={`${verifyBlocks} blocks`} />
        <StatCard label="Noise floor (EWMA)" value={`${minNoise}–${maxNoise} bps`} />
        <StatCard label="EWMA alpha" value={`${ewmaNum}/${ewmaDen}`} />
        <StatCard label="ETH/USD (live)" value={formatUsd(price18)} />
      </SimpleGrid>

      <Card mb={6}>
        <CardHeader>
          <Heading size="md">The verification decision</Heading>
        </CardHeader>
        <CardBody>
          <VStack align="stretch" spacing={4}>
            {STEPS.map((s) => (
              <div key={s.title}>
                <Text fontWeight="semibold">{s.title}</Text>
                <Text fontSize="sm" color="gray.500">
                  {s.body}
                </Text>
              </div>
            ))}
          </VStack>
        </CardBody>
      </Card>

      <SimpleGrid columns={{ base: 1, lg: 2 }} spacing={6}>
        <Card>
          <CardHeader>
            <Heading size="md">Adaptive EWMA noise floor</Heading>
          </CardHeader>
          <CardBody h={300}>
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={noiseData}>
                <CartesianGrid strokeDasharray="3 3" stroke="#333" />
                <XAxis dataKey="block" stroke="#888" />
                <YAxis stroke="#888" />
                <Tooltip />
                <ReferenceLine y={Number(minNoise)} stroke="#0ea5e9" label="minNoiseBps" />
                <Area type="monotone" dataKey="threshold" stroke="#0ea5e9" fill="#0ea5e9" fillOpacity={0.25} name="noise threshold" />
                <Area type="monotone" dataKey="observed" stroke="#f59e0b" fill="#f59e0b" fillOpacity={0.2} name="observed drift" />
              </AreaChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>
            <Heading size="md">Outcome by classification</Heading>
          </CardHeader>
          <CardBody h={300}>
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={verifiedBar}>
                <CartesianGrid strokeDasharray="3 3" stroke="#333" />
                <XAxis dataKey="name" stroke="#888" />
                <YAxis stroke="#888" domain={[0, 2]} allowDecimals={false} />
                <Tooltip />
                <Bar dataKey="verified" stackId="a" fill="#2ea043" name="verified → payout" />
                <Bar dataKey="unverified" stackId="a" fill="#d29922" name="unverified → donated" />
              </BarChart>
            </ResponsiveContainer>
            <Text fontSize="xs" color="gray.500" mt={2}>
              Confirmed one-sided drift pays the LPs who bore the risk; natural volatility (bounded by the
              EWMA noise floor) is donated back and trains the threshold.
            </Text>
          </CardBody>
        </Card>
      </SimpleGrid>
    </Container>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <Card>
      <CardBody>
        <Stat>
          <StatLabel>{label}</StatLabel>
          <StatNumber fontSize="xl">{value}</StatNumber>
        </Stat>
      </CardBody>
    </Card>
  );
}
