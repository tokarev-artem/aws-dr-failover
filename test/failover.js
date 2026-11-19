// Steady stream of numbered writes against the failover name. One JSON line per request.
// k6 run -e RUN=exp1 -e DURATION=15m failover.js --console-output results/raw/exp1.jsonl
import http from "k6/http";
import exec from "k6/execution";

const URL = __ENV.URL || "https://dr.tokarevartem.cloud";
const RUN = __ENV.RUN || "manual";

export const options = {
  // ttl 0: k6 does not cache DNS itself, so every new connection asks the OS resolver,
  // which honours the record TTL (60 s for an ALB alias) like a browser would.
  dns: { ttl: "0", select: "random", policy: "preferIPv4" },
  noConnectionReuse: __ENV.NO_REUSE === "1",
  discardResponseBodies: false,
  summaryTrendStats: ["p(50)", "p(95)", "p(99)", "max"],
  scenarios: {
    writes: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RATE || 10), timeUnit: "1s",
      duration: __ENV.DURATION || "10m",
      preAllocatedVUs: 20, maxVUs: 200,
    },
  },
};

export default function () {
  const seq = exec.scenario.iterationInTest + 1;
  const t = Date.now();
  const r = http.post(`${URL}/api/orders?run=${RUN}&seq=${seq}`, null, { timeout: "5s", tags: { name: "order" } });
  console.log(JSON.stringify({ t, seq, s: r.status, r: r.headers["X-Region"] || "", ms: Math.round(r.timings.duration), e: r.error_code || 0 }));
}
