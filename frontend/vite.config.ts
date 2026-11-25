/// <reference types="node" />
/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwind from "@tailwindcss/vite";

// The SPA only ever talks to our API, same-origin via this proxy.
export default defineConfig({
  plugins: [react(), tailwind()],
  test: { environment: "jsdom", globals: true, setupFiles: ["./src/test/setup.ts"], css: false },
  server: {
    port: 5173,
    proxy: { "/api": { target: process.env.API_TARGET ?? "http://localhost:3000", changeOrigin: true } },
    watch: { usePolling: true },
  },
});
