import { render } from "preact";
import init from "./core/qot_wasm";
import { Api } from "./api";
import { App } from "./app";
import { loadConfig } from "./config";
import { openStore } from "./store";
import "./styles.css";

async function boot() {
  const root = document.getElementById("app")!;
  const fail = (message: string) => {
    root.innerHTML = "";
    const p = document.createElement("p");
    p.className = "fatal";
    p.textContent = `qot couldn't start: ${message}`;
    root.append(p);
  };

  if (import.meta.env.PROD && "serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => undefined);
  }

  const config = await loadConfig();
  if (!config.ok) return fail(config.error);
  try {
    await init();
  } catch (e) {
    return fail(`the note engine didn't load (${e instanceof Error ? e.message : e})`);
  }
  let store;
  try {
    store = await openStore();
  } catch (e) {
    return fail(`this browser's storage is unavailable (${e instanceof Error ? e.message : e})`);
  }
  render(<App api={new Api(config.value.apiUrl)} store={store} />, root);
}

boot();
