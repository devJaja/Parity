import { http, createConfig } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected } from "@wagmi/core";

export const config = createConfig({
  chains: [baseSepolia],
  connectors: [injected()],
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
