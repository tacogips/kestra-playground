# Live Development Config

This directory is for generated local OpenTofu inputs. The generated `*.tfvars`
and `*.backend.hcl` files are intentionally ignored because they contain
environment-specific project, DNS, Cloudflare zone, and state bucket values.

Render the files from environment variables, usually injected by `kinko`:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET -- scripts/render-live-config.sh
```

The live deploy task renders these files automatically before running OpenTofu.
