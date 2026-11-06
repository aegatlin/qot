// Checks the built site in dist/ (run `npm run build` first): every page is
// there, every internal link resolves, and nothing loads from another origin.
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

const ROUTES = ["index.html", "install.html", "support.html", "privacy.html", "terms.html", "404.html"];

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
      if (/^(https?:|mailto:|#)/.test(url)) continue;
      assert.ok(url.startsWith("/"), `${route}: relative link ${url}`);
      assert.ok(resolves(url), `${route}: ${url} does not resolve`);
    }
  }
});

// The site is plain HTML and CSS: no JavaScript of its own, and nothing
// fetched from another origin (no trackers, fonts or CDNs). Links out are
// fine; loading something is not.
test("no scripts and no third-party resources", () => {
  for (const [route, html] of Object.entries(pages)) {
    assert.doesNotMatch(html, /<script/i, `${route}: has a script`);
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

test("support says how to reach a person, export notes and delete the account", () => {
  const html = pages["support.html"];
  assert.ok(urls(html).some((u) => u.startsWith("mailto:contact@abstractsyntax.llc")));
  assert.match(html, /qot export/);
  assert.match(html, /qot delete-account/);
});

test("the privacy policy says what the server stores", () => {
  const html = pages["privacy.html"];
  assert.match(html, /email address/i);
  assert.match(html, /end-to-end encrypt/i);
  assert.match(html, /Abstract Syntax LLC/);
});
