import { expect, test } from "vitest";
import { parseConfig } from "../src/config";

test("config names an http(s) API", () => {
  expect(parseConfig({ apiUrl: "https://api.example/" })).toEqual({ ok: true, value: { apiUrl: "https://api.example" } });
  expect(parseConfig({}).ok).toBe(false);
  expect(parseConfig({ apiUrl: "javascript:alert(1)" }).ok).toBe(false);
  expect(parseConfig(null).ok).toBe(false);
});
