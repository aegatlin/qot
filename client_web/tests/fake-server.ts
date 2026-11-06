// An in-memory stand-in for the sync server's HTTP API, as a `fetch`: one
// user's append-only log with gap-free seqs, tokens that can expire.

export class FakeServer {
  log: { seq: number; note_id: string; data: string }[] = [];
  validAccess = new Set(["access-1"]);
  validRefresh = new Set(["refresh-1"]);
  offline = false;
  pageSize = 500;
  refreshes = 0;
  private issued = 1;

  expireAccessTokens() {
    this.validAccess.clear();
  }

  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    if (this.offline) throw new TypeError("Failed to fetch");
    const url = new URL(String(input));
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    const auth = new Headers(init?.headers).get("authorization")?.replace("Bearer ", "");
    const json = (status: number, data: unknown) =>
      new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

    switch (`${init?.method ?? "GET"} ${url.pathname}`) {
      case "POST /api/auth/refresh":
        if (!this.validRefresh.has(body.refresh_token)) return json(401, { error: "Invalid" });
        this.refreshes++;
        this.issued++;
        this.validAccess.add(`access-${this.issued}`);
        return json(200, { access_token: `access-${this.issued}` });
      case "POST /api/auth/logout":
        this.validRefresh.delete(body.refresh_token);
        return json(200, { message: "ok" });
      case "POST /api/sync/push":
        if (!auth || !this.validAccess.has(auth)) return json(401, { error: "unauthorized" });
        for (const c of body.changes) this.log.push({ seq: this.log.length + 1, ...c });
        return json(200, { cursor: this.log.length });
      case "GET /api/sync/pull": {
        if (!auth || !this.validAccess.has(auth)) return json(401, { error: "unauthorized" });
        const since = Number(url.searchParams.get("since"));
        const changes = this.log.filter((c) => c.seq > since).slice(0, this.pageSize);
        const cursor = changes.length ? changes[changes.length - 1]!.seq : since;
        return json(200, { changes, cursor, more: cursor < this.log.length });
      }
      default:
        return json(404, { error: "not found" });
    }
  };
}
