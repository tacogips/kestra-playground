export interface AppConfig {
  port: number;
  appBaseUrl: string;
  authMode: "google" | "disabled";
  googleClientId: string;
  googleClientSecret: string;
  allowedEmails: string[];
  sessionSecret: string;
  sessionTtlSeconds: number;
  kestra: KestraConfig;
}

export interface KestraConfig {
  baseUrl: string;
  tenant: string;
  namespace: string;
  flowIds: string[];
  /** flowId -> local tar.gz path attached as the flow's batch_bundle FILE input. */
  flowBundles: Record<string, string>;
  username: string;
  password: string;
}

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

export function loadConfig(): AppConfig {
  const authMode = optional("AUTH_MODE", "google");
  if (authMode !== "google" && authMode !== "disabled") {
    throw new Error(`AUTH_MODE must be "google" or "disabled", got: ${authMode}`);
  }
  if (authMode === "disabled") {
    console.warn(
      "[webconsole] AUTH_MODE=disabled: Google login is bypassed. Local development only.",
    );
  }

  const port = Number(optional("PORT", "8787"));
  const config: AppConfig = {
    port,
    appBaseUrl: optional("APP_BASE_URL", `http://localhost:${port}`),
    authMode,
    googleClientId: authMode === "google" ? required("GOOGLE_CLIENT_ID") : "",
    googleClientSecret: authMode === "google" ? required("GOOGLE_CLIENT_SECRET") : "",
    allowedEmails:
      authMode === "google"
        ? required("ALLOWED_EMAILS")
            .split(",")
            .map((email) => email.trim().toLowerCase())
            .filter((email) => email.length > 0)
        : [],
    sessionSecret: authMode === "google" ? required("SESSION_SECRET") : "dev-secret",
    sessionTtlSeconds: Number(optional("SESSION_TTL_SECONDS", "43200")),
    kestra: {
      baseUrl: required("KESTRA_URL").replace(/\/+$/, ""),
      tenant: optional("KESTRA_TENANT", "main"),
      namespace: optional("KESTRA_NAMESPACE", "playground.ecommerce"),
      flowIds: optional(
        "KESTRA_FLOW_IDS",
        [
          "generate_ecommerce_mock_data",
          "build_ecommerce_daily_report",
          "build_ecommerce_customer_segments",
        ].join(","),
      )
        .split(",")
        .map((flowId) => flowId.trim())
        .filter((flowId) => flowId.length > 0),
      flowBundles: Object.fromEntries(
        optional("KESTRA_FLOW_BUNDLES", "")
          .split(",")
          .map((pair) => pair.trim())
          .filter((pair) => pair.includes("="))
          .map((pair) => {
            const separator = pair.indexOf("=");
            return [pair.slice(0, separator), pair.slice(separator + 1)];
          }),
      ),
      username: optional("KESTRA_BASIC_AUTH_USERNAME", ""),
      password: optional("KESTRA_BASIC_AUTH_PASSWORD", ""),
    },
  };
  if (authMode === "google" && config.allowedEmails.length === 0) {
    throw new Error("ALLOWED_EMAILS must contain at least one email address");
  }
  return config;
}
