import { join } from "node:path";
import { Authenticator, escapeHtml, htmlResponse } from "./auth";
import { loadConfig } from "./config";
import { KestraApiError, KestraClient } from "./kestra";

const config = loadConfig();
const auth = new Authenticator(config);
const kestra = new KestraClient(config.kestra);
const clientDir = join(import.meta.dir, "..", "dist", "client");

function json(status: number, payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function serveStatic(pathname: string): Promise<Response | null> {
  const relative = pathname === "/" ? "index.html" : pathname.slice(1);
  if (relative.includes("..")) {
    return null;
  }
  const file = Bun.file(join(clientDir, relative));
  if (await file.exists()) {
    return new Response(file);
  }
  return null;
}

function signInPage(): Response {
  return htmlResponse(
    401,
    `You are not signed in. <a href="/auth/login">Sign in with Google</a>`,
  );
}

async function handleApi(request: Request, pathname: string): Promise<Response> {
  if (pathname === "/api/me" && request.method === "GET") {
    const session = auth.getSession(request);
    if (session === null) {
      return json(401, { error: "unauthenticated" });
    }
    return json(200, {
      email: session.email,
      namespace: config.kestra.namespace,
      flowIds: config.kestra.flowIds,
      kestraUrl: config.kestra.baseUrl,
    });
  }

  const session = auth.getSession(request);
  if (session === null) {
    return json(401, { error: "unauthenticated" });
  }

  try {
    if (pathname === "/api/executions" && request.method === "GET") {
      const executions = await kestra.listRecentExecutions(10);
      return json(200, { executions });
    }
    if (pathname === "/api/executions" && request.method === "POST") {
      const body = (await request.json()) as {
        flowId?: string;
        inputs?: Record<string, string>;
      };
      if (body.flowId === undefined || body.flowId === "") {
        return json(400, { error: "flowId is required" });
      }
      const execution = await kestra.triggerFlow(body.flowId, body.inputs ?? {});
      console.log(
        `[webconsole] ${session.email} triggered ${body.flowId} -> execution ${execution.id}`,
      );
      return json(201, { execution });
    }
    const logsMatch = pathname.match(/^\/api\/executions\/([A-Za-z0-9_-]+)\/logs$/);
    if (logsMatch !== null && request.method === "GET") {
      const logs = await kestra.fetchLogs(logsMatch[1]);
      return new Response(logs, {
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
    }
  } catch (error) {
    if (error instanceof KestraApiError) {
      console.error(`[webconsole] Kestra API error: ${error.message}`);
      return json(502, { error: `Kestra API error (HTTP ${error.status})` });
    }
    if (error instanceof Error && error.message.startsWith("Flow is not allowed")) {
      return json(400, { error: error.message });
    }
    console.error("[webconsole] unexpected error:", error);
    return json(500, { error: "internal error" });
  }
  return json(404, { error: "not found" });
}

const server = Bun.serve({
  port: config.port,
  idleTimeout: 60,
  async fetch(request) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    if (pathname === "/healthz") {
      return json(200, { status: "ok" });
    }
    if (pathname === "/auth/login") {
      return auth.loginRedirect();
    }
    if (pathname === "/auth/callback") {
      return auth.handleCallback(request);
    }
    if (pathname === "/auth/logout") {
      return auth.logout();
    }
    if (pathname.startsWith("/api/")) {
      return handleApi(request, pathname);
    }

    const session = auth.getSession(request);
    if (session === null) {
      return signInPage();
    }
    const staticResponse = await serveStatic(pathname);
    if (staticResponse !== null) {
      return staticResponse;
    }
    // SPA fallback for client-side routes.
    const index = await serveStatic("/");
    if (index !== null) {
      return index;
    }
    return htmlResponse(
      500,
      `Frontend build not found. Run <code>${escapeHtml("bun run build")}</code> first.`,
    );
  },
});

console.log(
  `[webconsole] listening on http://localhost:${server.port} ` +
    `(auth=${config.authMode}, kestra=${config.kestra.baseUrl}, namespace=${config.kestra.namespace})`,
);
