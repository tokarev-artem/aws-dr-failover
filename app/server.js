import http from "node:http";
import { DynamoDBClient, GetItemCommand, PutItemCommand, QueryCommand } from "@aws-sdk/client-dynamodb";
import { NodeHttpHandler } from "@smithy/node-http-handler";

const REGION = process.env.APP_REGION || "eu-central-1";
const TABLE = process.env.TABLE_NAME || "dr-demo";
const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || "dev";

// Fail fast: a slow dependency should fail the request (and the deep health check), not hang it.
const db = new DynamoDBClient({
  region: REGION,
  maxAttempts: 2,
  requestHandler: new NodeHttpHandler({ connectionTimeout: 1000, requestTimeout: 1500 }),
});

const send = (res, status, body, type = "application/json") => {
  res.writeHead(status, { "content-type": type, "x-region": REGION, "cache-control": "no-store" });
  res.end(type === "application/json" ? JSON.stringify(body) : body);
};

async function handle(req, res) {
  const url = new URL(req.url, "http://x");

  // Shallow: the process is up. Says nothing about DynamoDB.
  if (url.pathname === "/api/health") return send(res, 200, { ok: true, region: REGION });

  // Deep: the process is up AND it can read from DynamoDB in this region.
  if (url.pathname === "/api/health/deep") {
    try {
      await db.send(new GetItemCommand({ TableName: TABLE, Key: { pk: { S: "health" }, sk: { N: "0" } } }));
      return send(res, 200, { ok: true, region: REGION, dynamodb: "ok" });
    } catch (e) {
      return send(res, 503, { ok: false, region: REGION, dynamodb: e.name });
    }
  }

  // Write one numbered order. The load test sends seq 1, 2, 3, ... so we can count losses later.
  if (url.pathname === "/api/orders" && req.method === "POST") {
    const run = url.searchParams.get("run") || "manual";
    const seq = url.searchParams.get("seq") || String(Date.now());
    try {
      await db.send(new PutItemCommand({
        TableName: TABLE,
        Item: {
          pk: { S: `run#${run}` }, sk: { N: seq },
          region: { S: REGION }, ts: { N: String(Date.now()) },
        },
      }));
      return send(res, 201, { ok: true, region: REGION, run, seq: Number(seq) });
    } catch (e) {
      return send(res, 503, { ok: false, region: REGION, error: e.name });
    }
  }

  if (url.pathname === "/api/orders" && req.method === "GET") {
    const run = url.searchParams.get("run") || "manual";
    try {
      const out = await db.send(new QueryCommand({
        TableName: TABLE, KeyConditionExpression: "pk = :p",
        ExpressionAttributeValues: { ":p": { S: `run#${run}` } },
        ScanIndexForward: false, Limit: 5,
      }));
      return send(res, 200, { region: REGION, latest: out.Items.map((i) => ({ seq: +i.sk.N, region: i.region.S })) });
    } catch (e) {
      return send(res, 503, { ok: false, region: REGION, error: e.name });
    }
  }

  if (url.pathname === "/") {
    const name = REGION === "eu-central-1" ? "Frankfurt" : REGION === "eu-west-1" ? "Ireland" : REGION;
    const color = REGION === "eu-central-1" ? "#2563eb" : "#0f766e";
    return send(res, 200, `<!doctype html><meta charset="utf-8"><title>DR demo</title>
<style>body{font-family:system-ui;margin:0;display:grid;place-items:center;min-height:100vh;background:${color};color:#fff}
main{text-align:center}h1{font-size:64px;margin:0}p{font-size:22px;opacity:.85}code{background:#0003;padding:2px 8px;border-radius:6px}</style>
<main><p>Served from</p><h1>${name}</h1><p><code>${REGION}</code> · version <code>${VERSION}</code></p></main>`, "text/html");
  }

  send(res, 404, { error: "not found" });
}

http.createServer((req, res) => handle(req, res).catch((e) => send(res, 500, { error: e.message })))
  .listen(PORT, "0.0.0.0", () => console.log(`dr-demo ${VERSION} listening on ${PORT} in ${REGION}`));
