import { useMemo } from "react";
import {
  Card,
  CardHeader,
  CardBody,
  Heading,
  Text,
  VStack,
  HStack,
  Button,
  Alert,
  AlertIcon,
  AlertDescription,
  Code,
  useToast,
  Skeleton,
} from "@chakra-ui/react";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import {
  PARITY_SEEDER_ADDRESS,
  POOL_SEEDER_ABI,
  ERC20_ABI,
  USDC_ADDRESS,
  WETH_ADDRESS,
  OWNER_ADDRESS,
} from "../contracts";
import { formatAddress } from "../utils/format";

// Live-price concentrated sizing (matches script/SeedParityPool.s.sol:SeedPool.run()).
const PRICE_TICK = -77880;
const SPACING = 60;
const LIQUIDITY = 100000000000n; // 1e11
// amount0 (USDC, 6-dec) and amount1 (WETH, 18-dec) for liquidity=1e11 around live price.
const AMOUNT0_MAX = 33230440157n; // ~$33.2k USDC (computed for the narrow band)
const AMOUNT1_MAX = 22719932n; // ~0.0227 WETH

export default function SeedPoolPanel() {
  const { address, isConnected } = useAccount();
  const toast = useToast();
  const isOwner = isConnected && address?.toLowerCase() === OWNER_ADDRESS.toLowerCase();

  const seederActive = PARITY_SEEDER_ADDRESS !== "0x0000000000000000000000000000000000000000";

  const { data: seeded } = useReadContract({
    address: PARITY_SEEDER_ADDRESS as `0x${string}`,
    abi: POOL_SEEDER_ABI as never,
    functionName: "seeded",
    query: { enabled: seederActive },
  });
  const { data: seederOwner } = useReadContract({
    address: PARITY_SEEDER_ADDRESS as `0x${string}`,
    abi: POOL_SEEDER_ABI as never,
    functionName: "owner",
    query: { enabled: seederActive },
  });
  const seederOwnerAddr = (seederOwner as unknown as string) ?? "0x";

  // Seeder's current token balances (so the owner sees whether it's funded).
  const { data: seederUsdc } = useReadContract({
    address: USDC_ADDRESS as `0x${string}`,
    abi: ERC20_ABI as never,
    functionName: "balanceOf",
    args: [PARITY_SEEDER_ADDRESS as `0x${string}`],
    query: { enabled: seederActive },
  });
  const { data: seederWeth } = useReadContract({
    address: WETH_ADDRESS as `0x${string}`,
    abi: ERC20_ABI as never,
    functionName: "balanceOf",
    args: [PARITY_SEEDER_ADDRESS as `0x${string}`],
    query: { enabled: seederActive },
  });

  const { writeContract: writePull, isPending: pulling } = useWriteContract();
  const { writeContract: writeSeed, isPending: seeding } = useWriteContract();

  const doPull = () =>
    writePull(
      {
        address: PARITY_SEEDER_ADDRESS as `0x${string}`,
        abi: POOL_SEEDER_ABI as never,
        functionName: "pull",
        args: [AMOUNT0_MAX, AMOUNT1_MAX],
      },
      {
        onSuccess: () => toast({ title: "Funded seeder", status: "success" }),
        onError: (e) => toast({ title: "Pull failed", description: e?.message ?? "error", status: "error" }),
      }
    );

  const doSeed = () =>
    writeSeed(
      {
        address: PARITY_SEEDER_ADDRESS as `0x${string}`,
        abi: POOL_SEEDER_ABI as never,
        functionName: "seed",
        args: [BigInt(PRICE_TICK - 3 * SPACING), BigInt(PRICE_TICK + 3 * SPACING), LIQUIDITY, AMOUNT0_MAX, AMOUNT1_MAX],
      },
      {
        onSuccess: (h) => toast({ title: "Pool seeded", description: h, status: "success" }),
        onError: (e) => toast({ title: "Seed failed", description: e?.message ?? "error", status: "error" }),
      }
    );

  const fundNeeded = useMemo(() => {
    if (!seederActive || seeded) return false;
    const usdcOk = seederUsdc !== undefined && seederUsdc >= AMOUNT0_MAX;
    const wethOk = seederWeth !== undefined && seederWeth >= AMOUNT1_MAX;
    return !(usdcOk && wethOk);
  }, [seederActive, seeded, seederUsdc, seederWeth]);

  if (!seederActive) {
    return (
      <Card>
        <CardHeader>
          <Heading size="md">Seed Pool (owner)</Heading>
        </CardHeader>
        <CardBody>
          <Alert status="warning">
            <AlertIcon />
            <AlertDescription>
              <Code>CanonicalPoolSeeder</Code> is not deployed yet. Run{" "}
              <Code>DeploySeeder</Code> (script/SeedParityPool.s.sol) and set{" "}
              <Code>PARITY_SEEDER_ADDRESS</Code>, then return here.
            </AlertDescription>
          </Alert>
        </CardBody>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <Heading size="md">Seed Pool (owner)</Heading>
      </CardHeader>
      <CardBody>
        {!isOwner ? (
          <Alert status="info">
            <AlertIcon />
            Only the hook owner ({formatAddress(OWNER_ADDRESS)}) can seed the pool.
          </Alert>
        ) : (
          <VStack align="stretch" spacing={4}>
            <HStack justify="space-between" fontSize="sm">
              <Text color="gray.500">Seeder</Text>
              <Text fontWeight="medium">{formatAddress(PARITY_SEEDER_ADDRESS)}</Text>
            </HStack>
            <HStack justify="space-between" fontSize="sm">
              <Text color="gray.500">Seeder owner</Text>
              <Text fontWeight="medium">{formatAddress(seederOwnerAddr)}</Text>
            </HStack>
            <HStack justify="space-between" fontSize="sm">
              <Text color="gray.500">State</Text>
              <Text fontWeight="medium">{seeded ? "seeded" : "not seeded"}</Text>
            </HStack>

            <HStack justify="space-between" fontSize="sm">
              <Text color="gray.500">Seeder USDC / WETH</Text>
              {seederUsdc !== undefined ? (
                <Text fontWeight="medium">
                  {(Number(seederUsdc) / 1e6).toFixed(2)} / {(Number(seederWeth ?? 0n) / 1e18).toFixed(4)}
                </Text>
              ) : (
                <Skeleton h={4} w={24} />
              )}
            </HStack>

            {seeded ? (
              <Alert status="success">
                <AlertIcon />
                Pool is seeded — live swaps will not revert.
              </Alert>
            ) : (
              <VStack align="stretch" spacing={3}>
                <Alert status="info">
                  <AlertIcon />
                  <AlertDescription>
                    Fund the seeder with <strong>USDC + WETH</strong> (~$33k USDC + 0.023 WETH for the
                    liquidity=1e11 band), then seed. Fund by transferring tokens to the seeder, or use the
                    pull button which pulls exactly the required amounts from your wallet.
                  </AlertDescription>
                </Alert>
                <HStack spacing={3}>
                  <Button flex="1" variant="outline" onClick={doPull} isLoading={pulling} isDisabled={seeded}>
                    1 · Pull funding in
                  </Button>
                  <Button flex="1" colorScheme="brand" onClick={doSeed} isLoading={seeding} isDisabled={seeded || fundNeeded}>
                    2 · Seed pool
                  </Button>
                </HStack>
                {fundNeeded && (
                  <Text fontSize="xs" color="orange.500">
                    Seeder is not fully funded for the target band yet.
                  </Text>
                )}
              </VStack>
            )}
          </VStack>
        )}
      </CardBody>
    </Card>
  );
}
