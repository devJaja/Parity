import { http, createConfig } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected, metaMask, coinbaseWallet, walletConnect } from "wagmi/connectors";

export const WALLETCONNECT_PROJECT_ID =
  import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ?? "YOUR_PROJECT_ID";

export const config = createConfig({
  chains: [baseSepolia],
  connectors: [
    injected(),
    metaMask(),
    coinbaseWallet({
      appName: "Parity",
    }),
    walletConnect({
      projectId: WALLETCONNECT_PROJECT_ID,
      showQrModal: true,
      metadata: {
        name: "Parity — Self-Funding LVR Firewall",
        description: "Uniswap v4 hook demo on Base Sepolia",
        url: "https://parity.example",
        icons: [],
      },
    }),
  ],
  transports: {
    [baseSepolia.id]: http("https://sepolia.base.org", { batch: true }),
  },
  ssr: false,
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
