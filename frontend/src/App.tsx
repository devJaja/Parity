import {
  Box,
  ChakraProvider,
  extendTheme,
  ColorModeScript,
} from "@chakra-ui/react";
import { BrowserRouter as Router, Routes, Route } from "react-router-dom";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { config } from "./wagmi";
import Navbar from "./components/Navbar";
import Footer from "./components/Footer";
import Dashboard from "./pages/Dashboard";
import SwapDemo from "./pages/SwapDemo";
import LvrAnalysis from "./pages/LvrAnalysis";

const theme = extendTheme({
  colors: {
    brand: {
      50: "#f0f9ff",
      100: "#e0f2fe",
      200: "#bae6fd",
      300: "#7dd3fc",
      400: "#38bdf8",
      500: "#0ea5e9",
      600: "#0284c7",
      700: "#0369a1",
      800: "#075985",
      900: "#0c4a6e",
    },
  },
  config: {
    initialColorMode: "dark",
    useSystemColorMode: false,
  },
});

const queryClient = new QueryClient();

function AppInner() {
  return (
    <Router>
      <Box minH="100vh" display="flex" flexDirection="column" bg="gray.50" _dark={{ bg: "gray.900" }}>
        <Navbar />
        <Box as="main" flex="1" py={8}>
          <Routes>
            <Route path="/" element={<Dashboard />} />
            <Route path="/swap" element={<SwapDemo />} />
            <Route path="/analysis" element={<LvrAnalysis />} />
            <Route path="*" element={<Dashboard />} />
          </Routes>
        </Box>
        <Footer />
      </Box>
    </Router>
  );
}

function App() {
  return (
    <>
      <ColorModeScript initialColorMode={theme.config.initialColorMode} />
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <ChakraProvider theme={theme}>
            <AppInner />
          </ChakraProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </>
  );
}

export default App;
