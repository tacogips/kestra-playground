import { createHmac, timingSafeEqual } from "node:crypto";
import type { AppConfig } from "./config";

const SESSION_COOKIE = "kwc_session";
const STATE_COOKIE = "kwc_oauth_state";

export interface Session {
  email: string;
  expiresAt: number;
}

function base64UrlEncode(data: string): string {
  return Buffer.from(data).toString("base64url");
}

function base64UrlDecode(data: string): string {
  return Buffer.from(data, "base64url").toString();
}

function sign(payload: string, secret: string): string {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

function verifySigned(token: string, secret: string): string | null {
  const dotIndex = token.lastIndexOf(".");
  if (dotIndex <= 0) {
    return null;
  }
  const payload = token.slice(0, dotIndex);
  const signature = token.slice(dotIndex + 1);
  const expected = sign(payload, secret);
  const signatureBuffer = Buffer.from(signature);
  const expectedBuffer = Buffer.from(expected);
  if (
    signatureBuffer.length !== expectedBuffer.length ||
    !timingSafeEqual(signatureBuffer, expectedBuffer)
  ) {
    return null;
  }
  return base64UrlDecode(payload);
}

function parseCookies(request: Request): Record<string, string> {
  const header = request.headers.get("cookie") ?? "";
  const cookies: Record<string, string> = {};
  for (const part of header.split(";")) {
    const [name, ...rest] = part.trim().split("=");
    if (name !== "") {
      cookies[name] = rest.join("=");
    }
  }
  return cookies;
}

function cookieAttributes(config: AppConfig, maxAgeSeconds: number): string {
  const secure = config.appBaseUrl.startsWith("https://") ? "; Secure" : "";
  return `; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSeconds}${secure}`;
}

export class Authenticator {
  constructor(private readonly config: AppConfig) {}

  getSession(request: Request): Session | null {
    if (this.config.authMode === "disabled") {
      return { email: "dev@localhost", expiresAt: Number.MAX_SAFE_INTEGER };
    }
    if (this.config.authMode === "iap") {
      // With Cloud Run's IAP integration enabled (and allUsers invoker
      // removed), only IAP-proxied requests reach the container, so this
      // header is set by IAP after Google sign-in. The allowlist check is a
      // second enforcement layer on top of the IAP IAM policy.
      const header = request.headers.get("x-goog-authenticated-user-email");
      if (header === null) {
        return null;
      }
      const email = (header.split(":").pop() ?? "").toLowerCase();
      if (email === "" || !this.config.allowedEmails.includes(email)) {
        console.warn(`[auth] rejected IAP-authenticated user ${email}`);
        return null;
      }
      return { email, expiresAt: Number.MAX_SAFE_INTEGER };
    }
    const token = parseCookies(request)[SESSION_COOKIE];
    if (token === undefined) {
      return null;
    }
    const payload = verifySigned(token, this.config.sessionSecret);
    if (payload === null) {
      return null;
    }
    const session = JSON.parse(payload) as Session;
    if (session.expiresAt < Date.now()) {
      return null;
    }
    return session;
  }

  private redirectUri(): string {
    return `${this.config.appBaseUrl}/auth/callback`;
  }

  loginRedirect(): Response {
    if (this.config.authMode !== "google") {
      return new Response(null, { status: 302, headers: { Location: "/" } });
    }
    const state = crypto.randomUUID();
    const params = new URLSearchParams({
      client_id: this.config.googleClientId,
      redirect_uri: this.redirectUri(),
      response_type: "code",
      scope: "openid email",
      state,
      prompt: "select_account",
    });
    const stateToken = `${base64UrlEncode(state)}.${sign(base64UrlEncode(state), this.config.sessionSecret)}`;
    return new Response(null, {
      status: 302,
      headers: {
        Location: `https://accounts.google.com/o/oauth2/v2/auth?${params}`,
        "Set-Cookie": `${STATE_COOKIE}=${stateToken}${cookieAttributes(this.config, 600)}`,
      },
    });
  }

  async handleCallback(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const stateToken = parseCookies(request)[STATE_COOKIE];
    if (code === null || state === null || stateToken === undefined) {
      return htmlResponse(403, "Login failed: missing code or state.");
    }
    const expectedState = verifySigned(stateToken, this.config.sessionSecret);
    if (expectedState === null || expectedState !== state) {
      return htmlResponse(403, "Login failed: state mismatch.");
    }

    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: this.config.googleClientId,
        client_secret: this.config.googleClientSecret,
        redirect_uri: this.redirectUri(),
        grant_type: "authorization_code",
      }),
    });
    if (!tokenResponse.ok) {
      console.error("[auth] token exchange failed:", await tokenResponse.text());
      return htmlResponse(403, "Login failed: token exchange rejected.");
    }
    const tokenPayload = (await tokenResponse.json()) as { id_token?: string };
    if (tokenPayload.id_token === undefined) {
      return htmlResponse(403, "Login failed: no id_token returned.");
    }

    const claims = decodeIdTokenClaims(tokenPayload.id_token);
    if (
      claims === null ||
      claims.iss !== "https://accounts.google.com" ||
      claims.aud !== this.config.googleClientId ||
      claims.email === undefined ||
      claims.email_verified !== true ||
      (claims.exp ?? 0) * 1000 < Date.now()
    ) {
      return htmlResponse(403, "Login failed: invalid ID token.");
    }

    const email = claims.email.toLowerCase();
    if (!this.config.allowedEmails.includes(email)) {
      console.warn(`[auth] rejected login attempt from ${email}`);
      return htmlResponse(403, `Access denied for ${escapeHtml(email)}.`);
    }

    const session: Session = {
      email,
      expiresAt: Date.now() + this.config.sessionTtlSeconds * 1000,
    };
    const payload = base64UrlEncode(JSON.stringify(session));
    const sessionToken = `${payload}.${sign(payload, this.config.sessionSecret)}`;
    return new Response(null, {
      status: 302,
      headers: [
        ["Location", "/"],
        [
          "Set-Cookie",
          `${SESSION_COOKIE}=${sessionToken}${cookieAttributes(this.config, this.config.sessionTtlSeconds)}`,
        ],
        ["Set-Cookie", `${STATE_COOKIE}=${cookieAttributes(this.config, 0)}`],
      ],
    });
  }

  logout(): Response {
    if (this.config.authMode === "iap") {
      // Clears the IAP session cookie.
      return new Response(null, {
        status: 302,
        headers: { Location: "/?gcp-iap-mode=GCP_IAP_LOGOUT" },
      });
    }
    return new Response(null, {
      status: 302,
      headers: {
        Location: "/",
        "Set-Cookie": `${SESSION_COOKIE}=${cookieAttributes(this.config, 0)}`,
      },
    });
  }
}

interface IdTokenClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  email?: string;
  email_verified?: boolean;
}

// The id_token is received directly from Google's token endpoint over TLS in the
// authorization-code flow, so claim validation without local JWKS signature
// verification is sufficient here (OIDC Core 3.1.3.7 note).
function decodeIdTokenClaims(idToken: string): IdTokenClaims | null {
  const segments = idToken.split(".");
  if (segments.length !== 3) {
    return null;
  }
  try {
    return JSON.parse(base64UrlDecode(segments[1])) as IdTokenClaims;
  } catch {
    return null;
  }
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function htmlResponse(status: number, message: string): Response {
  const body = `<!doctype html><meta charset="utf-8"><title>Kestra Console</title>
<div style="font-family: sans-serif; max-width: 40rem; margin: 4rem auto;">
  <h1>Kestra Console</h1>
  <p>${message}</p>
  <p><a href="/">Back</a></p>
</div>`;
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}
