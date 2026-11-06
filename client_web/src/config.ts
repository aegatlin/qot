import { err, ok, type Result } from "./result";

export interface Config {
  /** The sync API, e.g. https://api.quantumofthought.com */
  apiUrl: string;
}

/** Pure: the parsed /config.json, or why it's unusable. */
export function parseConfig(body: unknown): Result<Config> {
  const apiUrl = (body as { apiUrl?: unknown } | null)?.apiUrl;
  if (typeof apiUrl !== "string" || !/^https?:\/\/[^/]/.test(apiUrl)) return err("config.json has no apiUrl");
  return ok({ apiUrl: apiUrl.replace(/\/+$/, "") });
}

export async function loadConfig(): Promise<Result<Config>> {
  try {
    const response = await fetch("/config.json", { cache: "no-cache" });
    if (!response.ok) return err(`config.json: HTTP ${response.status}`);
    return parseConfig(await response.json());
  } catch (e) {
    return err(`config.json: ${e instanceof Error ? e.message : String(e)}`);
  }
}
