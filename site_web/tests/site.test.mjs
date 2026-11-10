// Checks the built site in dist/ (run `npm run build` first): every page is
// there, every internal link resolves, and nothing loads from another origin.

// Plausible's script and event endpoint, which Caddy proxies to plausible.io
// (see Caddyfile): served from this origin, never built into dist/.
const PLAUSIBLE_SCRIPT =
  '<script defer data-domain="www.quantumofthought.com" data-api="/api/event" src="/js/script.js"></script>';
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

const dist = new URL("../dist/", import.meta.url).pathname;

function htmlFiles(dir = dist) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return htmlFiles(path);
    return entry.name.endsWith(".html") ? [path] : [];
  });
}

const pages = Object.fromEntries(
  htmlFiles().map((file) => [relative(dist, file), readFileSync(file, "utf8")]),
);

// Attribute values of every src= and href= in a page.
function urls(html) {
  return [...html.matchAll(/\s(?:src|href)="([^"]*)"/g)].map((m) => m[1]);
}

// What a path on the site serves, as Caddy will look it up: the file, then
// <path>.html, then <path>/index.html.
function resolves(path) {
  const clean = decodeURI(path.split(/[?#]/)[0]).replace(/^\//, "");
  if (clean === "") return existsSync(join(dist, "index.html"));
  return [clean, `${clean}.html`, join(clean, "index.html")].some((candidate) =>
    existsSync(join(dist, candidate)),
  );
}

const ROUTES = ["index.html", "install.html", "iphone.html", "support.html", "privacy.html", "terms.html", "404.html"];

test("every page is built", () => {
  for (const route of ROUTES) assert.ok(pages[route], `${route} is missing`);
});

test("every page has a title, a description and the footer's policy links", () => {
  for (const [route, html] of Object.entries(pages)) {
    assert.match(html, /<title>[^<]+<\/title>/, `${route}: no title`);
    assert.match(html, /<meta name="description" content="[^"]+"/, `${route}: no description`);
    assert.match(html, /<html lang="en"/, `${route}: no lang`);
    for (const href of ["/privacy", "/terms", "/support"]) {
      assert.ok(urls(html).includes(href), `${route}: no link to ${href}`);
    }
  }
});

test("every internal link and asset resolves", () => {
  for (const [route, html] of Object.entries(pages)) {
    for (const url of urls(html)) {
      if (/^(https?:|mailto:|#)/.test(url) || url === "/js/script.js") continue;
      assert.ok(url.startsWith("/"), `${route}: relative link ${url}`);
      assert.ok(resolves(url), `${route}: ${url} does not resolve`);
    }
  }
});

// The site is plain HTML and CSS: no JavaScript of its own, only Plausible's
// page-view counter from this origin, and nothing fetched from another origin
// (no trackers, fonts or CDNs). Links out are fine; loading something is not.
test("no scripts but Plausible's, and no third-party resources", () => {
  for (const [route, html] of Object.entries(pages)) {
    const scripts = html.match(/<script\b[^>]*>[\s\S]*?<\/script>/gi) ?? [];
    assert.deepEqual(scripts, [PLAUSIBLE_SCRIPT], `${route}: scripts other than Plausible's`);
    for (const tag of html.match(/<(img|link|iframe|source|video|audio)\b[^>]*>/gi) ?? []) {
      if (/^<link\b/i.test(tag) && /rel="(canonical|alternate)"/.test(tag)) continue;
      assert.doesNotMatch(tag, /(src|href)="(https?:)?\/\//, `${route}: loads ${tag}`);
    }
  }
});

test("the build ships no JavaScript files", () => {
  const files = readdirSync(dist, { recursive: true }).map(String);
  assert.deepEqual(files.filter((f) => /\.m?js$/.test(f)), []);
});

test("install shows both ways to get the CLI and the PWA's address", () => {
  const html = pages["install.html"];
  assert.match(html, /brew install aegatlin\/tap\/qot/);
  assert.match(
    html,
    /curl -LsSf https:\/\/github\.com\/aegatlin\/qot\/releases\/latest\/download\/qot_cli-installer\.sh \| sh/,
  );
  assert.ok(urls(html).includes("https://app.quantumofthought.com"));
});

test("the iPhone page names every way to capture", () => {
  const text = pages["iphone.html"].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  for (const fact of [
    /Capture a thought in qot/,
    /Action button/,
    /Control Center/,
    /Lock Screen/,
    /Latest Notes/,
    /Spotlight/,
    /Shortcuts/,
    /Back Tap/,
    /Apple Watch/,
    /dictat/i,
    /Sign in with Apple/,
    /iOS 26/,
  ]) {
    assert.match(text, fact, `iphone.html should mention ${fact}`);
  }
});

test("install and the home page link to the iPhone page", () => {
  assert.ok(urls(pages["install.html"]).includes("/iphone"));
  assert.ok(urls(pages["index.html"]).includes("/iphone"));
});

test("support says how to reach a person, export notes and delete the account", () => {
  const html = pages["support.html"];
  assert.ok(urls(html).some((u) => u.startsWith("mailto:contact@abstractsyntax.llc")));
  assert.match(html, /qot export/);
  assert.match(html, /qot delete-account/);
  assert.match(html, /web app, open the account menu and choose Delete account/);
  assert.doesNotMatch(html, /we'll do\s+it for you/);
});

test("the privacy policy says what the server stores", () => {
  const html = pages["privacy.html"];
  assert.match(html, /email address/i);
  assert.match(html, /end-to-end encrypt/i);
  assert.match(html, /Abstract Syntax LLC/);
});

test("the privacy policy names the website's analytics and says the apps send none", () => {
  const text = pages["privacy.html"].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  assert.match(text, /Plausible/);
  assert.match(text, /no cookies/i);
  assert.match(text, /apps send nothing to Plausible/);
});
