// Starts the Phoenix server for the specs and drives the CLI.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("../..", import.meta.url).pathname;
export const API = "http://localhost:4000";
export const APP = "http://localhost:4173";

export class Server {
  log = "";
  private proc?: ChildProcess;

  async start() {
    const env = { ...process.env, APP_URL: APP, MIX_ENV: "dev" };
    // Run through `mise run e2e:web`, mise's tools are already on PATH.
    const setup = spawnSync("mix", ["do", "ecto.create", "--quiet", "+", "ecto.migrate", "--quiet"], {
      cwd: join(root, "server_web"),
      env,
      encoding: "utf8",
    });
    if (setup.status !== 0) throw new Error(`database setup failed:\n${setup.stderr}${setup.stdout}`);
    this.proc = spawn("mix", ["phx.server"], { cwd: join(root, "server_web"), env, detached: true });
    this.proc.stdout!.on("data", (d) => (this.log += d));
    this.proc.stderr!.on("data", (d) => (this.log += d));
    await waitFor(async () => (await fetch(`${API}/health`).catch(() => null))?.ok === true, 60_000, () => this.log);
  }

  stop() {
    if (this.proc?.pid) process.kill(-this.proc.pid, "SIGTERM");
  }

  /** The newest sign-in link emailed to `email`. */
  async signInLink(email: string): Promise<string> {
    let link: string | undefined;
    await waitFor(
      () => {
        const at = this.log.lastIndexOf(email);
        const m = at >= 0 ? this.log.slice(at).match(/(http:\/\/localhost:4173\/auth\/device\?token=[A-Za-z0-9_-]+)/) : null;
        link = m?.[1];
        return !!link;
      },
      15_000,
      () => this.log.slice(-2000),
    );
    return link!;
  }
}

export async function waitFor(check: () => boolean | Promise<boolean>, ms: number, context?: () => string) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await check()) return;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`timed out${context ? `:\n${context()}` : ""}`);
}

/** A CLI device: its own data dir. */
export class Cli {
  readonly dir = mkdtempSync(join(tmpdir(), "qot-e2e-"));
  static readonly bin = join(root, "target", "debug", "qot");

  run(...args: string[]) {
    return spawnSync(Cli.bin, args, { env: { ...process.env, QOT_DATA_DIR: this.dir }, encoding: "utf8" });
  }

  /** `qot login` in the background; resolves with its output once it exits. */
  login(email: string) {
    const proc = spawn(Cli.bin, ["login", email, "--server", API], { env: { ...process.env, QOT_DATA_DIR: this.dir } });
    let out = "";
    proc.stdout.on("data", (d) => (out += d));
    proc.stderr.on("data", (d) => (out += d));
    const exited = new Promise<{ code: number | null; out: string }>((resolve) => proc.on("exit", (code) => resolve({ code, out })));
    const code = (async () => {
      await waitFor(() => /[A-Z]{4}-[A-Z]{4}/.test(out), 15_000, () => out);
      return out.match(/[A-Z]{4}-[A-Z]{4}/)![0];
    })();
    return { code, exited };
  }
}
