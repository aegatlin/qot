// The website, www.quantumofthought.com: plain HTML and CSS, no JavaScript of its own
// (Plausible's page-view script is proxied by Caddy, not built).
// React is used only to render components (the shadcn/ui ones shared with the
// Abstract Syntax site) at build time; nothing is hydrated.
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import react from "@astrojs/react";
import tailwindcss from "@tailwindcss/vite";
import { readdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// @astrojs/react emits its client renderer even when no component is
// hydrated. Nothing references it; drop it so the site ships no JavaScript
// (tests/site.test.mjs checks).
const noClientJs = {
  name: "no-client-js",
  hooks: {
    "astro:build:done": async ({ dir }) => {
      const assets = new URL("_astro/", dir);
      for (const file of await readdir(assets)) {
        if (/\.m?js$/.test(file)) await rm(fileURLToPath(new URL(file, assets)));
      }
    },
  },
};

export default defineConfig({
  site: "https://www.quantumofthought.com",
  // /privacy is privacy.html; the server tries <path>.html (see Caddyfile).
  build: { format: "file", inlineStylesheets: "never" },
  trailingSlash: "never",
  integrations: [mdx(), react(), noClientJs],
  vite: { plugins: [tailwindcss()] },
  devToolbar: { enabled: false },
  // Compression drops the space between a line of text and an inline tag on
  // the next line ("after<code>qot</code>"); Caddy compresses the response.
  compressHTML: false,
});
