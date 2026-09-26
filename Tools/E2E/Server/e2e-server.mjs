// BoxJS for Relay's end-to-end UI tests: the real backend script (chavy.boxjs.js from
// chavyleung/scripts), holding data the way the web UI, scripts and older clients
// leave it, served over HTTP.
//
//   GET  /__e2e/subs/<file>   subscription sources, for the app's own fetch
//   POST /__e2e/reset         back to the initial data (?reachable=1: every source reachable)
//   GET  /__e2e/log           writes received since the last reset
//   anything else             BoxJS
//
// Usage: BOXJS_SCRIPT=/path/to/box/chavy.boxjs.js node e2e-server.mjs [port]
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createBox } from "./boxjs-sim.mjs";

const script = process.env.BOXJS_SCRIPT;
if (!script || !fs.existsSync(script)) {
  console.error("BOXJS_SCRIPT must point at chavy.boxjs.js");
  process.exit(2);
}
const port = Number(process.argv[2] || 8124);
const origin = `http://127.0.0.1:${port}`;
const fixtures = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const sourceURL = (file) => `${origin}/__e2e/subs/${file}`;

// BoxJS fetches sources through its mocked client, the app over HTTP: same bytes.
// Decoding keeps a leading byte-order mark, exactly as proxy tools hand it to BoxJS.
const sources = Object.fromEntries(
  fs.readdirSync(fixtures).map((file) => [sourceURL(file), fs.readFileSync(path.join(fixtures, file))]),
);
const fetchMap = Object.fromEntries(Object.entries(sources).map(([url, bytes]) => [url, bytes.toString("utf8")]));
const MISSING_URL = sourceURL("missing.boxjs.json");                 // the host answers 404
fetchMap[MISSING_URL] = "404: Not Found";
const UNREACHABLE_URL = "https://unreachable.invalid/sub.boxjs.json"; // BoxJS gets a network error

async function initialStore({ reachable }) {
  const box = createBox({ script, fetchMap });
  const subscriptions = [["e2e", "relay-e2e.boxjs.json"], ["plain", "plain.boxjs.json"], ["missing", null]];
  for (const [id, file] of subscriptions) {
    await box.call("POST", "/api/addAppSub", { id, url: file ? sourceURL(file) : MISSING_URL, enable: true });
  }
  const { store } = box;
  const cfg = JSON.parse(store.chavy_boxjs_userCfgs);
  if (!reachable) cfg.appsubs.push({ id: "gone", url: UNREACHABLE_URL, enable: true });
  cfg.isMute = "true";                                   // a script's $.setdata('true', '@chavy_boxjs_userCfgs.isMute')
  cfg.favapps = ["BoxSetting", null, "BoxGist", "e2e.settings"];
  store.chavy_boxjs_userCfgs = JSON.stringify(cfg);
  store.chavy_boxjs_sessions = JSON.stringify([
    // From an older client: numeric createTime, an entry without val, a field Relay does not model.
    { id: "legacy-session", name: "旧版会话", appId: "e2e.settings", appName: "E2E 设置", createTime: 1767225600000,
      datas: [{ key: "e2e_cookie", val: "cookie-B" }, { key: "e2e_unset" }], custom: "keep-me" },
  ]);
  store.chavy_boxjs_cur_sessions = JSON.stringify({ Gone: null });
  store.e2e_cookie = "cookie-A";
  store.e2e_options = JSON.stringify([{ key: "x", label: "选项X" }, { key: "y", label: "选项Y" }]);
  return store;
}

const initial = {
  reachable: await initialStore({ reachable: true }),
  unreachable: await initialStore({ reachable: false }),
};
let box;
let writes;
function reset({ reachable }) {
  box = createBox({ script, fetchMap, store: structuredClone(reachable ? initial.reachable : initial.unreachable) });
  writes = [];
}
reset({ reachable: false });

http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", async () => {
    const send = (status, data, type = "application/json; charset=utf-8") => {
      response.writeHead(status, { "Content-Type": type });
      response.end(data);
    };
    const text = Buffer.concat(chunks).toString("utf8");
    const body = text ? JSON.parse(text) : undefined;
    const { pathname, search } = new URL(request.url, origin);

    if (pathname.startsWith("/__e2e/subs/")) {
      const source = sources[origin + pathname];
      return source ? send(200, source) : send(404, "404: Not Found", "text/plain");
    }
    if (pathname === "/__e2e/reset") {
      reset({ reachable: search.includes("reachable=1") });
      return send(200, "{}");
    }
    if (pathname === "/__e2e/log") return send(200, JSON.stringify(writes));

    if (request.method === "POST") writes.push({ path: request.url, body: body ?? null });
    send(200, (await box.call(request.method, request.url, body)) ?? "null");
  });
}).listen(port, "127.0.0.1", () => console.log(`Relay E2E BoxJS listening on ${origin}`));
