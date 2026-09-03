import { Box, Container, Text, HStack, Link } from "@chakra-ui/react";
import { Link as RouterLink } from "react-router-dom";
import { PARITY_HOOK_ADDRESS } from "../contracts";
import { formatAddress } from "../utils/format";

export default function Footer() {
  return (
    <Box py={6} borderTop="1px" borderColor="gray.200" _dark={{ borderColor: "gray.700" }}>
      <Container maxW="7xl">
        <HStack justify="space-between" wrap="wrap" spacing={4}>
          <Text fontSize="sm" color="gray.500">
            Parity — self-funding LVR firewall for Uniswap v4 · live on Base Sepolia
          </Text>
          <HStack spacing={4} fontSize="sm" color="gray.500">
            <Text>Hook: {formatAddress(PARITY_HOOK_ADDRESS)}</Text>
            <Link as={RouterLink} to="/analysis">
              How it works
            </Link>
          </HStack>
        </HStack>
      </Container>
    </Box>
  );
}
