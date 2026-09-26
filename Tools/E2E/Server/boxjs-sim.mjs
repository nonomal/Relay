// Runs the real BoxJS backend script (chavy.boxjs.js) under a mocked Surge runtime.
// `$persistentStore` is the in-memory `store`, and `$httpClient` answers from
// `fetchMap`; any other URL is a network error, as for an unreachable host.
import fs from "node:fs";
import vm from "node:vm";

export function createBox({ script, store = {}, fetchMap = {} }) {
  const source = fs.readFileSync(script, "utf8");

  const call = (method, path, body) => new Promise((resolve) => {
    const context = {
      console: { log() {}, error() {} },
      setTimeout, clearTimeout, Promise, JSON, Date, Math, Object, Array, String, Number, Boolean, RegExp, Error,
      $environment: { "surge-version": "5.20" },
      $persistentStore: {
        read: (key) => (key in store ? store[key] : null),
        // Surge stores text; other values are converted the way its JS bridge does.
        write: (value, key) => {
          store[key] = value === null || value === undefined || typeof value === "string" ? value : String(value);
          return true;
        },
      },
      $notification: { post() {} },
      $httpClient: {
        get(options, callback) {
          const url = (typeof options === "string" ? options : options.url).replace(/[?&]_=\d+$/, "");
          if (url in fetchMap) callback(null, { status: 200, statusCode: 200, headers: {} }, fetchMap[url]);
          else callback("network error", null, null);
        },
        post(options, callback) { callback("unsupported", null, null); },
      },
      $request: {
        url: `http://boxjs.com${path}`,
        method,
        headers: { Referer: "http://boxjs.com/" },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
      $done: (response) => resolve(response?.response?.body ?? response?.body),
    };
    context.globalThis = context;
    vm.createContext(context);
    vm.runInContext(source, context);
  });

  return { store, call };
}
