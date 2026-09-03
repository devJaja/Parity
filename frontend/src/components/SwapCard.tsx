import { useState, useMemo } from "react";
import {
  Card,
  CardHeader,
  CardBody,
  Heading,
  Text,
  VStack,
  HStack,
  Input,
  Select,
  Button,
  Divider,
  Alert,
  AlertIcon,
  AlertDescription,
  Skeleton,
  useToast,
  Box,
} from "@chakra-ui/react";
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useBlockNumber,
} from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { approxPoolWethOut, buildParityPoolKey } from "../v4";
import {
  V4_SWAP_ROUTER_ADDRESS,
  V4_SWAP_ROUTER_ABI,
  PERMIT2_ADDRESS,
  PERMIT2_ABI,
  ERC20_ABI,
  USDC_ADDRESS,
  CHAINLINK_ADAPTER_ADDRESS,
  CHAINLINK_ADAPTER_ABI,
  PARITY_HOOK_ADDRESS,
} from "../contracts";
import { formatUsd } from "../utils/format";

const MAX_UINT256 =
  0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn;
const MAX_UINT160 =
  0xffffffffffffffffffffffffffffffffffffffffn;
const MAX_UINT48 = 0xffffffffffffn;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

function slippageValue(slippage: string): number {
  return Number(slippage.replace("%", "")) || 0.5;
}

export default function SwapCard() {
  const { address, isConnected } = useAccount();
  const toast = useToast();
  const { data: block } = useBlockNumber();

  const [amount, setAmount] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [hookTag, setHookTag] = useState("auto");
  const [lastTx, setLastTx] = useState<string | null>(null);

  const poolKey = buildParityPoolKey();

  // Live ETH/USD reference for a transparent estimate.
  const { data: priceCell } = useReadContract({
    address: CHAINLINK_ADAPTER_ADDRESS as `0x${string}`,
    abi: CHAINLINK_ADAPTER_ABI as never,
    functionName: "latestPrice18",
  });
  const price18 = priceCell?.[0];

  const amountUSD = useMemo(() => {
    try {
      if (!amount) return 0n;
      return parseUnits(amount, USDC_DECIMALS);
    } catch {
      return 0n;
    }
  }, [amount]);
  const hasInput = amountUSD > 0n && isConnected && Boolean(address);

  // Estimated WETH out (informational; assumes a seeded pool near feed price).
  const wethOutEstimate = useMemo(
    () => (hasInput && price18 ? approxPoolWethOut(amountUSD, price18, slippageValue(slippage)) : 0n),
    [hasInput, amountUSD, price18, slippage]
  );

  // Allowances: router + Permit2 must both have USDC spend permission (matches fork proof).
  const { data: routerAllowance } = useReadContract({
    address: USDC_ADDRESS as `0x${string}`,
    abi: ERC20_ABI as never,
    functionName: "allowance",
    args: [address as `0x${string}`, V4_SWAP_ROUTER_ADDRESS as `0x${string}`],
    query: { enabled: hasInput },
  });
  const { data: permit2Allowance } = useReadContract({
    address: USDC_ADDRESS as `0x${string}`,
    abi: ERC20_ABI as never,
    functionName: "allowance",
    args: [address as `0x${string}`, PERMIT2_ADDRESS as `0x${string}`],
    query: { enabled: hasInput },
  });

  const routerApproved = Boolean(routerAllowance !== undefined && routerAllowance > 0n);
  const permit2Approved = Boolean(permit2Allowance !== undefined && permit2Allowance > 0n);

  // --- Approvals ---
  const { writeContract: writeApproveErc20, isPending: approvingErc20 } = useWriteContract();
  const { writeContract: writeApprovePermit2, isPending: approvingPermit2 } = useWriteContract();
  // --- Swap ---
  const { writeContract: writeSwap, isPending: swapping } = useWriteContract();

  const doApproveRouter = () =>
    writeApproveErc20(
      {
        address: USDC_ADDRESS as `0x${string}`,
        abi: ERC20_ABI as never,
        functionName: "approve",
        args: [V4_SWAP_ROUTER_ADDRESS as `0x${string}`, MAX_UINT256],
      },
      {
        onSuccess: (h) => toast({ title: "Approved router", description: h, status: "success" }),
        onError: (e) => toast({ title: "Approve router failed", description: e?.message ?? "error", status: "error" }),
      }
    );

  const doApprovePermit2 = () =>
    writeApprovePermit2(
      {
        address: PERMIT2_ADDRESS as `0x${string}`,
        abi: PERMIT2_ABI as never,
        functionName: "approve",
        args: [USDC_ADDRESS as `0x${string}`, V4_SWAP_ROUTER_ADDRESS as `0x${string}`, MAX_UINT160, MAX_UINT48],
      },
      {
        onSuccess: (h) => toast({ title: "Approved Permit2", description: h, status: "success" }),
        onError: (e) => toast({ title: "Approve Permit2 failed", description: e?.message ?? "error", status: "error" }),
      }
    );

  const deadline = useMemo(
    () => (block ? block + 90n : 0n),
    [block]
  );

  const hookData = useMemo(() => {
    // Mirror the fork proof: hookData = abi.encode(wallet) so the hook trusts tx.origin/encoded swapper.
    if (!address) return "0x";
    return "0x" + (address.toLowerCase().slice(2).padStart(64, "0") as string);
  }, [address]);

  const doSwap = () =>
    writeSwap(
      {
        address: V4_SWAP_ROUTER_ADDRESS as `0x${string}`,
        abi: V4_SWAP_ROUTER_ABI as never,
        functionName: "swapExactTokensForTokens",
        args: [
          amountUSD,
          wethOutEstimate,
          true, // zeroForOne: input USDC (currency0) → WETH (currency1)
          poolKey,
          hookData,
          address as `0x${string}`,
          deadline,
        ],
      },
      {
        onSuccess: (h) => {
          setLastTx(h);
          toast({ title: "Swap submitted", description: h, status: "success" });
        },
        onError: (e) =>
          toast({ title: "Swap failed", description: e?.message ?? "Unknown on-chain error", status: "error" }),
      }
    );

  const readyToSwap = hasInput && routerApproved && permit2Approved;

  return (
    <Card>
      <CardHeader>
        <Heading size="md">Swap via canonical V4 router</Heading>
      </CardHeader>
      <CardBody>
        {!isConnected ? (
          <Alert status="info">
            <AlertIcon />
            Connect a wallet on Base Sepolia to approve and swap.
          </Alert>
        ) : (
          <VStack align="stretch" spacing={4}>
            <Box>
              <Text fontWeight="semibold" mb={1}>
                You pay (USDC)
              </Text>
              <Input
                placeholder="0.00"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                type="number"
                min={0}
                inputMode="decimal"
              />
            </Box>

            <HStack spacing={4} wrap="wrap">
              <Box flex="1">
                <Text fontWeight="semibold" mb={1} fontSize="sm">
                  Slippage
                </Text>
                <Select value={slippage} onChange={(e) => setSlippage(e.target.value)}>
                  <option value="0.5">0.5%</option>
                  <option value="1">1%</option>
                  <option value="2">2%</option>
                </Select>
              </Box>
              <Box flex="1">
                <Text fontWeight="semibold" mb={1} fontSize="sm">
                  hookData identity
                </Text>
                <Select value={hookTag} onChange={(e) => setHookTag(e.target.value)}>
                  <option value="auto">wallet (abi.encode)</option>
                </Select>
              </Box>
            </HStack>

            <HStack justify="space-between">
              <Text color="gray.500">Est. WETH out</Text>
              {hasInput ? (
                <Text fontWeight="bold">
                  {formatUnits(wethOutEstimate, WETH_DECIMALS)}
                </Text>
              ) : (
                <Text color="gray.400">—</Text>
              )}
            </HStack>
            {price18 ? (
              <Text fontSize="xs" color="gray.500">
                Based on live ETH/USD feed ({formatUsd(price18)}); actual execution depends on pool price.
              </Text>
            ) : (
              <Skeleton h={4} w="60%" />
            )}

            <Divider />

            <Alert status="warning">
              <AlertIcon />
              <AlertDescription>
                The live Base Sepolia deploy has <strong>no seeded pool</strong>, so a swap will revert on-chain
                (pool not initialized). The full premium/verification path is proven via fork tests (
                <code>HookLiveFork</code> / <code>PushLivePool</code>). This form stays wired so it works the
                instant a pool is seeded.
              </AlertDescription>
            </Alert>

            {lastTx && (
              <Alert status="success">
                <AlertIcon />
                <Text fontSize="sm">Last submit: {lastTx}</Text>
              </Alert>
            )}

            <VStack spacing={2}>
              <HStack w="full">
                <Button
                  flex="1"
                  variant="outline"
                  onClick={doApproveRouter}
                  isLoading={approvingErc20}
                  isDisabled={routerApproved || !hasInput}
                >
                  {routerApproved ? "Router approved" : "1 · Approve router"}
                </Button>
                <Button
                  flex="1"
                  variant="outline"
                  onClick={doApprovePermit2}
                  isLoading={approvingPermit2}
                  isDisabled={permit2Approved || !hasInput}
                >
                  {permit2Approved ? "Permit2 approved" : "2 · Approve Permit2"}
                </Button>
              </HStack>
              <Button
                w="full"
                colorScheme="brand"
                onClick={doSwap}
                isLoading={swapping}
                isDisabled={!readyToSwap}
              >
                Swap USDC → WETH
              </Button>
            </VStack>

            <Text fontSize="xs" color="gray.500">
              Pool: USDC/WETH · fee 3000 · tickSpacing 60 · hook {PARITY_HOOK_ADDRESS.slice(0, 10)}…
              <br />
              Router {V4_SWAP_ROUTER_ADDRESS.slice(0, 10)}… · Permit2 {PERMIT2_ADDRESS.slice(0, 10)}…
            </Text>
          </VStack>
        )}
      </CardBody>
    </Card>
  );
}
