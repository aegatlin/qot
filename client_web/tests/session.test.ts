import { describe, expect, test } from "vitest";
import { adoption, browserChoice } from "../src/session";
import type { Credentials } from "../src/store";

const creds = (email: string, userId = email, server = "https://api.example"): Credentials => ({
  server,
  email,
  userId,
  accessToken: "a",
  refreshToken: "r",
});

describe("the sign-in page's browser box", () => {
  test("a browser that isn't signed in is offered sign-in, ticked", () => {
    expect(browserChoice(undefined, "me@example.com", "https://api.example")).toEqual({
      kind: "sign_in",
      checked: true,
    });
  });

  test("already signed in as that account: nothing to tick", () => {
    expect(browserChoice(creds("Me@Example.com"), "me@example.com", "https://api.example").kind).toBe("already");
  });

  test("another account: switching is offered, never ticked by default", () => {
    expect(browserChoice(creds("other@example.com"), "me@example.com", "https://api.example")).toEqual({
      kind: "switch",
      from: "other@example.com",
      checked: false,
    });
  });

  test("credentials for another server don't count", () => {
    expect(browserChoice(creds("me@example.com", "u", "http://localhost:4000"), "me@example.com", "https://api.example").kind).toBe("sign_in");
  });
});

describe("adopting tokens", () => {
  test("keeps an existing session for the same user, switches for another", () => {
    expect(adoption(undefined, creds("a"))).toBe("save");
    expect(adoption(creds("a", "u1"), creds("a", "u1"))).toBe("keep");
    expect(adoption(creds("a", "u1"), creds("b", "u2"))).toBe("switch");
  });
});
