import { defineConfig, type Plugin } from "vite";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";

// The API the PWA talks to. Deployed builds read it from /config.json, which
// the server image writes at start (so one build serves staging and
// production); the dev and preview servers answer /config.json from here.
const apiUrl = process.env.QOT_API_URL ?? "http://localhost:4000";

function devConfig(): Plugin {
  const serve = (_req: unknown, res: { setHeader: Function; end: Function }) => {
    res.setHeader("content-type", "application/json");
    res.setHeader("cache-control", "no-cache");
    res.end(JSON.stringify({ apiUrl }));
  };
  return {
    name: "qot-dev-config",
    configureServer(server) {
      server.middlewares.use("/config.json", serve);
    },
    configurePreviewServer(server) {
      server.middlewares.use("/config.json", serve);
    },
  };
}

// The service worker precaches every file of this build, so the app opens
// offline after one visit. Its cache name is a hash of the build, so a new
// build replaces the old cache in one step.
function serviceWorker(): Plugin {
  return {
    name: "qot-service-worker",
    apply: "build",
    generateBundle(_options, bundle) {
      // The bundle, plus public/ (copied as is). sw.js adds config.json.
      const files = [
        ...Object.keys(bundle),
        ...readdirSync(new URL("./public", import.meta.url), { recursive: true }).map(String),
      ].filter((f) => !f.endsWith(".map") && f !== "config.json");
      const assets = ["/", ...files.map((f) => `/${f}`)].sort();
      const version = createHash("sha256").update(assets.join("\n")).digest("hex").slice(0, 12);
      const template = readFileSync(new URL("./src/sw.js", import.meta.url), "utf8");
      this.emitFile({
        type: "asset",
        fileName: "sw.js",
        source: template
          .replace("__VERSION__", version)
          .replace("__ASSETS__", JSON.stringify(assets)),
      });
    },
  };
}

export default defineConfig({
  plugins: [devConfig(), serviceWorker()],
  build: { target: "es2022", sourcemap: true },
  server: { port: 5173, strictPort: true },
  preview: { port: 4173, strictPort: true },
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
    setupFiles: ["tests/setup.ts"],
  },
} as Parameters<typeof defineConfig>[0]);
