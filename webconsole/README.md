# Kestra Batch Web Console

A small Cloud Run web console that calls the on-premise Kestra API to run the
ecommerce batch flows and inspect the ten most recent executions with their
logs.

- Runtime: Bun (`Bun.serve`) serving both the JSON API and the built frontend
- Frontend: SolidJS + Bulma, built with Vite
- Sign-in: Google OAuth 2.0 authorization-code flow enforced by the Bun server;
  only the email addresses listed in `ALLOWED_EMAILS` may sign in
- Kestra access: Basic Auth against `KESTRA_URL`, tenant `main`

Configuration is environment-only. Locally it comes from `webconsole/.env`
(ignored by git; start from `.env.example`). On Cloud Run every sensitive value
(allowed emails, OAuth client, session secret, Kestra URL and credentials) is
mounted from Secret Manager by `scripts/deploy-webconsole.sh`.

## Local development

```bash
cd webconsole
bun install
cp .env.example .env        # AUTH_MODE=disabled bypasses Google login locally
bun run build
bun run serve               # http://localhost:8787
```

With a local Kestra (see repository README) the console can trigger
`playground.ecommerce` flows and stream execution logs immediately.

To exercise the real Google login locally, create an OAuth web client with
redirect URI `http://localhost:8787/auth/callback`, then set
`AUTH_MODE=google`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
`ALLOWED_EMAILS`, and `SESSION_SECRET` in `.env`.

## Deploy to Cloud Run

One-time: create a Google OAuth 2.0 **Web application** client in the GCP
console (APIs & Services > Credentials). After the first deploy, add the
printed `https://<service-url>/auth/callback` as an authorized redirect URI.

```bash
# 1. Register runtime values in Secret Manager (values from kinko/env, not git)
kinko exec --env PROJECT_ID,WEBCONSOLE_ALLOWED_EMAILS,WEBCONSOLE_GOOGLE_CLIENT_ID,WEBCONSOLE_GOOGLE_CLIENT_SECRET,WEBCONSOLE_KESTRA_URL,WEBCONSOLE_KESTRA_BASIC_AUTH_USERNAME,WEBCONSOLE_KESTRA_BASIC_AUTH_PASSWORD -- \
  task webconsole:secrets

# 2. Build and deploy from source (Cloud Build + Cloud Run)
kinko exec --env PROJECT_ID -- task webconsole:deploy
```

The deploy defaults target the live GKE topology: namespace
`playground.remote_batch` with the `export_database_to_csv_routed` and
`parse_application_logs_routed` flows. The deploy script rebuilds the
remote-batch source bundles into `webconsole/bundles/` (ignored by git) and
bakes them into the image so the console can supply each flow's
`batch_bundle` FILE input. Override `KESTRA_NAMESPACE`, `KESTRA_FLOW_IDS`,
and `KESTRA_FLOW_BUNDLES` at deploy time for other targets.

The service allows unauthenticated ingress at the platform layer because the
application performs Google sign-in itself and rejects any account not present
in the `webconsole-allowed-emails` secret.

## Environment variables

| Variable | Purpose |
| --- | --- |
| `AUTH_MODE` | `google` (default) or `disabled` (local dev only) |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | OAuth 2.0 web client |
| `ALLOWED_EMAILS` | Comma-separated allowed Google account emails |
| `SESSION_SECRET` | HMAC key for session cookies |
| `SESSION_TTL_SECONDS` | Session lifetime (default 43200) |
| `APP_BASE_URL` | Public base URL, used for the OAuth redirect URI |
| `KESTRA_URL` | On-premise Kestra API base URL |
| `KESTRA_TENANT` | Kestra tenant (default `main`) |
| `KESTRA_NAMESPACE` | Flow namespace (default `playground.ecommerce`) |
| `KESTRA_FLOW_IDS` | Comma-separated flows the console may trigger |
| `KESTRA_FLOW_BUNDLES` | Optional `flowId=path` pairs; the tar.gz is attached as that flow's `batch_bundle` FILE input |
| `KESTRA_BASIC_AUTH_USERNAME` / `KESTRA_BASIC_AUTH_PASSWORD` | Kestra Basic Auth |
| `PORT` | Listen port (Cloud Run injects 8080) |
