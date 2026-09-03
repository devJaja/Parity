import {
  Box,
  Flex,
  Heading,
  HStack,
  Link,
  Text,
  IconButton,
  useColorMode,
  Button,
  Avatar,
  Menu,
  MenuButton,
  MenuList,
  MenuItem,
  useDisclosure,
  Drawer,
  DrawerOverlay,
  DrawerContent,
  DrawerHeader,
  DrawerBody,
  VStack,
  Divider,
  useToast,
  Modal,
  ModalOverlay,
  ModalContent,
  ModalHeader,
  ModalCloseButton,
  ModalBody,
} from "@chakra-ui/react";
import { MoonIcon, SunIcon, HamburgerIcon } from "@chakra-ui/icons";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { Link as RouterLink } from "react-router-dom";
import { formatAddress } from "../utils/format";

export default function Navbar() {
  const { colorMode, toggleColorMode } = useColorMode();
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const toast = useToast();
  const { isOpen, onOpen, onClose } = useDisclosure();
  const {
    isOpen: walletOpen,
    onOpen: openWallet,
    onClose: closeWallet,
  } = useDisclosure();

  const handleConnect = (connector: (typeof connectors)[number]) => {
    closeWallet();
    connect(
      { connector },
      {
        onError: (err) =>
          toast({
            title: "Connect failed",
            description: err?.message ?? "No wallet detected in this browser",
            status: "error",
            duration: 6000,
          }),
      }
    );
  };

  const injected = connectors.find((c) => c.id === "injected");
  const others = connectors.filter((c) => c.id !== "injected");

  const noInjectedWallet =
    typeof window !== "undefined" && !window.ethereum;

  const handleDisconnect = () => {
    disconnect();
    onClose();
  };

  return (
    <Box
      bg={colorMode === "light" ? "white" : "gray.900"}
      boxShadow="md"
      position="sticky"
      top={0}
      zIndex={1000}
    >
      <Flex h={16} alignItems="center" justifyContent="space-between" px={4} maxW="7xl" mx="auto">
        <Flex alignItems="center">
          <Heading as="h1" size="lg" color="brand.500" letterSpacing="-0.5px">
            Parity
          </Heading>
          <Box display={{ base: "none", md: "flex" }} ml={10}>
            <HStack spacing={4}>
              <Link as={RouterLink} to="/" fontWeight="medium">
                Dashboard
              </Link>
              <Link as={RouterLink} to="/swap" fontWeight="medium">
                Swap Demo
              </Link>
              <Link as={RouterLink} to="/analysis" fontWeight="medium">
                LVR Analysis
              </Link>
            </HStack>
          </Box>
        </Flex>

        <Flex alignItems="center">
          <IconButton
            aria-label="Toggle color mode"
            icon={colorMode === "light" ? <MoonIcon /> : <SunIcon />}
            onClick={toggleColorMode}
            variant="ghost"
            mr={2}
          />

          {isConnected && address ? (
            <Menu>
              <MenuButton
                as={Button}
                variant="outline"
                rightIcon={
                  <Avatar
                    size="sm"
                    name={address}
                    src={`https://api.dicebear.com/7.x/identicon/svg?seed=${address}`}
                  />
                }
              >
                {formatAddress(address)}
              </MenuButton>
              <MenuList>
                <MenuItem onClick={handleDisconnect}>Disconnect</MenuItem>
              </MenuList>
            </Menu>
          ) : (
            <Button colorScheme="brand" onClick={openWallet}>
              Connect Wallet
            </Button>
          )}

          <IconButton
            aria-label="Open menu"
            icon={<HamburgerIcon />}
            variant="ghost"
            display={{ base: "flex", md: "none" }}
            ml={2}
            onClick={onOpen}
          />
        </Flex>
      </Flex>

      <Drawer placement="right" onClose={onClose} isOpen={isOpen}>
        <DrawerOverlay />
        <DrawerContent>
          <DrawerHeader borderBottomWidth="1px">Menu</DrawerHeader>
          <DrawerBody>
            <VStack spacing={4} align="start">
              <Link as={RouterLink} to="/" onClick={onClose}>
                Dashboard
              </Link>
              <Link as={RouterLink} to="/swap" onClick={onClose}>
                Swap Demo
              </Link>
              <Link as={RouterLink} to="/analysis" onClick={onClose}>
                LVR Analysis
              </Link>
              <Divider />
              {isConnected && address ? (
                <Button variant="ghost" onClick={handleDisconnect}>
                  Disconnect
                </Button>
              ) : (
                <Button colorScheme="brand" onClick={openWallet}>
                  Connect Wallet
                </Button>
              )}
            </VStack>
          </DrawerBody>
        </DrawerContent>
      </Drawer>

      <Modal isOpen={walletOpen} onClose={closeWallet} isCentered>
        <ModalOverlay />
        <ModalContent>
          <ModalHeader>Connect a wallet</ModalHeader>
          <ModalCloseButton />
          <ModalBody pb={6}>
            {injected && (
              <Button
                width="full"
                mb={2}
                justifyContent="flex-start"
                colorScheme="brand"
                variant="outline"
                onClick={() => handleConnect(injected)}
              >
                Browser wallet (MetaMask / Coinbase / Pelagus)
              </Button>
            )}
            {others.map((c) => (
              <Button
                key={c.id}
                width="full"
                mb={2}
                justifyContent="flex-start"
                variant="outline"
                onClick={() => handleConnect(c)}
              >
                {c.name}
              </Button>
            ))}
            {noInjectedWallet && (
              <>
                <Text fontSize="sm" color="orange.500" mt={2}>
                  No browser wallet extension detected. Install MetaMask, Coinbase
                  Wallet, or enable your wallet's "Connect with apps" setting, or pick
                  WalletConnect above.
                </Text>
              </>
            )}
          </ModalBody>
        </ModalContent>
      </Modal>
    </Box>
  );
}
