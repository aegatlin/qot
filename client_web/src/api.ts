// The sync server's HTTP API (CLAUDE.md "Server"). Only I/O and parsing; the
// rules live in the core and in sync.ts.

import { fromBase64, toBase64 } from "./base64";
import { err, ok, type Result } from "./result";

export type ApiError =
  | { kind: "unauthorized" }
  | { kind: "offline"; message: string }
  | { kind: "rate_limited"; retryAfter: number | null }
  | { kind: "failed"; status: number; error: string };

export type ApiResult<T> = Promise<Result<T, ApiError>>;

export interface Tokens {
  accessToken: string;
  refreshToken: string;
  user: { id: string; email: string };
}

export interface DeviceStart {
  deviceCode: string;
  userCode: string;
  interval: number;
  expiresIn: number;
}

export type Poll = { status: "pending" } | { status: "done"; tokens: Tokens } | { status: "failed"; reason: string };

/** What approving an emailed link did. */
export type Approval =
  | { status: "signed_in"; tokens: Tokens }
  | { status: "approved" }
  | { status: "mismatch" }
  | { status: "unusable"; reason: string };

export interface PulledChange {
  seq: number;
  noteId: string;
  data: Uint8Array;
}

export interface Page {
  changes: PulledChange[];
  cursor: number;
  more: boolean;
}

export function describe(e: ApiError): string {
  switch (e.kind) {
    case "unauthorized":
      return "signed out";
    case "offline":
      return "offline";
    case "rate_limited":
      return e.retryAfter
        ? `too many sign-ins; try again in ${Math.ceil(e.retryAfter / 60)} min`
        : "too many sign-ins; try again later";
    case "failed":
      return e.error;
  }
}

type Body = Record<string, unknown>;

export class Api {
  readonly base: string;
  constructor(
    base: string,
    private readonly fetchFn: typeof fetch = (...args) => fetch(...args),
  ) {
    this.base = base.replace(/\/+$/, "");
  }

  private async call(
    method: string,
    path: string,
    { body, token }: { body?: Body; token?: string } = {},
  ): ApiResult<{ status: number; body: Body }> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body) headers["content-type"] = "application/json";
    if (token) headers.authorization = `Bearer ${token}`;
    let response: Response;
    try {
      response = await this.fetchFn(this.base + path, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch (e) {
      return err({ kind: "offline", message: e instanceof Error ? e.message : String(e) });
    }
    const parsed = (await response.json().catch(() => ({}))) as Body;
    if (response.status === 401) return err({ kind: "unauthorized" });
    if (response.status === 429) {
      const retry = Number(response.headers.get("retry-after"));
      return err({ kind: "rate_limited", retryAfter: Number.isFinite(retry) && retry > 0 ? retry : null });
    }
    return ok({ status: response.status, body: parsed });
  }

  private static failed(status: number, body: Body): Result<never, ApiError> {
    return err({ kind: "failed", status, error: String(body.error ?? `HTTP ${status}`) });
  }

  async startDeviceLogin(email: string): ApiResult<DeviceStart> {
    const r = await this.call("POST", "/api/auth/device", { body: { email } });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status !== 200) return Api.failed(status, body);
    return ok({
      deviceCode: String(body.device_code),
      userCode: String(body.user_code),
      interval: Number(body.interval),
      expiresIn: Number(body.expires_in),
    });
  }

  async pollDeviceLogin(deviceCode: string): ApiResult<Poll> {
    const r = await this.call("POST", "/api/auth/device/token", { body: { device_code: deviceCode } });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status === 200) return ok({ status: "done", tokens: tokens(body) });
    if (body.error === "authorization_pending") return ok({ status: "pending" });
    return ok({ status: "failed", reason: String(body.error ?? `HTTP ${status}`) });
  }

  /** Which account an emailed link signs in to; null if it can't be used. */
  async deviceLink(token: string): ApiResult<{ email: string } | { unusable: string }> {
    const r = await this.call("GET", `/api/auth/device/link?token=${encodeURIComponent(token)}`);
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status === 200) return ok({ email: String(body.email) });
    if (status === 404 || status === 410) return ok({ unusable: String(body.error) });
    return Api.failed(status, body);
  }

  async approve(token: string, userCode: string, signInBrowser: boolean): ApiResult<Approval> {
    const r = await this.call("POST", "/api/auth/device/approve", {
      body: { token, user_code: userCode, sign_in_browser: signInBrowser },
    });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status === 200)
      return ok(body.access_token ? { status: "signed_in", tokens: tokens(body) } : { status: "approved" });
    if (status === 422) return ok({ status: "mismatch" });
    if (status === 404 || status === 410) return ok({ status: "unusable", reason: String(body.error) });
    return Api.failed(status, body);
  }

  async refresh(refreshToken: string): ApiResult<string> {
    const r = await this.call("POST", "/api/auth/refresh", { body: { refresh_token: refreshToken } });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status !== 200 || typeof body.access_token !== "string") return Api.failed(status, body);
    return ok(body.access_token);
  }

  async logout(refreshToken: string): ApiResult<void> {
    const r = await this.call("POST", "/api/auth/logout", { body: { refresh_token: refreshToken } });
    return r.ok ? ok(undefined) : r;
  }

  async push(token: string, changes: { noteId: string; data: Uint8Array }[]): ApiResult<number> {
    const r = await this.call("POST", "/api/sync/push", {
      token,
      body: { changes: changes.map((c) => ({ note_id: c.noteId, data: toBase64(c.data) })) },
    });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status !== 200) return Api.failed(status, body);
    return ok(Number(body.cursor));
  }

  async pull(token: string, since: number): ApiResult<Page> {
    const r = await this.call("GET", `/api/sync/pull?since=${since}`, { token });
    if (!r.ok) return r;
    const { status, body } = r.value;
    if (status !== 200) return Api.failed(status, body);
    const page = parsePage(body);
    return page.ok ? page : err({ kind: "failed", status, error: page.error });
  }

  /** The WebSocket endpoint Phoenix serves next to the API. */
  socketUrl(): string {
    return this.base.replace(/^http/, "ws") + "/socket";
  }
}

function tokens(body: Body): Tokens {
  const user = (body.user ?? {}) as Body;
  return {
    accessToken: String(body.access_token),
    refreshToken: String(body.refresh_token),
    user: { id: String(user.id), email: String(user.email) },
  };
}

/** A pull page, or why it is malformed. Never a partial page. */
export function parsePage(body: Body): Result<Page> {
  if (!Array.isArray(body.changes)) return err("no changes in reply");
  const changes: PulledChange[] = [];
  for (const c of body.changes as Body[]) {
    if (typeof c.seq !== "number" || typeof c.note_id !== "string" || typeof c.data !== "string")
      return err("malformed change in reply");
    try {
      changes.push({ seq: c.seq, noteId: c.note_id, data: fromBase64(c.data) });
    } catch {
      return err("bad change data in reply");
    }
  }
  if (typeof body.cursor !== "number" || typeof body.more !== "boolean") return err("no cursor in reply");
  return ok({ changes, cursor: body.cursor, more: body.more });
}
