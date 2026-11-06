// Every test runs against the real core, compiled to WASM.
import "fake-indexeddb/auto";
import { readFileSync } from "node:fs";
import { initSync } from "../src/core/qot_wasm";

initSync({ module: readFileSync(new URL("../src/core/qot_wasm_bg.wasm", import.meta.url)) });
