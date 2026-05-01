---
name: gumroad-api-meta
description: >
  Discover what an OAuth token can do against Gumroad's API by calling GET /v2/meta. Use
  when planning or debugging any Gumroad API integration: deciding which endpoint to call,
  why a /v2/* request returned 401 or 403, what scopes a token has, who the token belongs
  to, or what OAuth application minted it. Triggers on: "what scopes does this token have",
  "why am I getting 403 from gumroad", "what can this gumroad token do", "introspect this
  token", "what user owns this token", before calling any /v2/* endpoint for the first
  time, or when designing a multi-step workflow against Gumroad's public API.
---

# Gumroad API meta

`GET /v2/meta` is the token-introspection endpoint for Gumroad's v2 API. One round trip tells you everything you need to plan a workflow.

## When to call it

- **Before any other v2 call.** Cheaper to discover scopes once than to branch on 403s after the fact.
- **On 403 from a known endpoint.** Confirm the token actually has the required scope. If it doesn't, surface a precise "this token lacks the `X` scope" message instead of a generic auth error.
- **When stitching multi-step flows.** If a flow needs `view_sales` for step 1 and `edit_products` for step 2, check both up front — fail fast.

## Finding a token

Never ask the user to paste a token if one is already discoverable. Check these sources in order:

1. **`$GUMROAD_ACCESS_TOKEN` environment variable** (explicit override, same convention the gumroad-cli uses).

2. **gumroad-cli stored credentials.** If the CLI has been used to authenticate, the token is saved at:
   - `$XDG_CONFIG_HOME/gumroad/config.json` (if `XDG_CONFIG_HOME` is set), otherwise
   - `~/.config/gumroad/config.json` on macOS/Linux
   - `%APPDATA%\gumroad\config.json` on Windows

   The file is JSON-shaped `{"access_token": "..."}` with `0600` permissions. Read it with:
   ```bash
   jq -r .access_token "${XDG_CONFIG_HOME:-$HOME/.config}/gumroad/config.json"
   ```
   The CLI refuses to load it if permissions are wider than `0600`; agents should not loosen them.

3. **Bootstrap auth via the CLI** if neither source has a token. Tell the user:
   > "Run `gumroad auth login` — it'll open your browser. Reply when you've approved access."

   This starts the gumroad-cli's OAuth PKCE flow, which writes the token to the path in step 2. If the CLI isn't installed, suggest `brew install antiwork/cli/gumroad` (macOS) or the install script at `https://gumroad.com/install-cli.sh`. Then return to step 2.

4. **Last resort:** ask the user to paste a token in the chat. Only if nothing above works.

For non-production hosts, also check `$GUMROAD_API_URL` (defaults to `https://api.gumroad.com`). Use it as the base URL for `/v2/meta` and any other API calls.

## Request

```bash
curl -sS -H "Authorization: Bearer $TOKEN" https://api.gumroad.com/v2/meta
```

The endpoint is also reachable at `https://gumroad.com/api/v2/meta`. In local dev, the API mounts at root and the path is `http://127.0.0.1:3000/v2/meta`.

## Response

```json
{
  "success": true,
  "user": { "id": "<external_id>" },
  "token": {
    "scopes": ["view_sales", "edit_products"],
    "application_name": "<oauth_app_name_or_null>"
  },
  "api": {
    "version": "v2",
    "documentation_url": "https://app.gumroad.com/api"
  }
}
```

- `user.id` is the external ID (obfuscated). Never a database ID.
- `token.scopes` lists every scope the token holds. Match against the scope listed in the docs for whichever endpoint you intend to call.
- `token.application_name` is `null` for tokens not associated with an OAuth application.

## Status codes

| Status | Meaning |
|---|---|
| 200 | Token is valid and has at least one public scope. |
| 401 | No `Authorization` header, or the token is unknown / revoked. |
| 403 | Token has only private scopes (e.g. `mobile_api`). Treat as "wrong tool for this surface". |

## Public scopes you may see

`account`, `edit_products`, `view_sales`, `mark_sales_as_shipped`, `edit_sales`, `revenue_share`, `ifttt`, `view_profile`, `view_payouts`, `view_tax_data`, `view_public`.

The `account` scope is a superset — every other public-scope endpoint accepts it. If you see only `account`, you can call any v2 public endpoint.

## What this endpoint deliberately does NOT return

- The user's email, name, or profile details. Those are scope-gated on `/v2/user`.
- A list of available endpoints. Use the OpenAPI spec (when published) for that.
- The token's expiration. Gumroad access tokens do not expire (`access_token_expires_in nil` in the Doorkeeper config).

If you need email or profile data, call `/v2/user` after `/v2/meta` confirms you have `view_profile` (or any higher scope).

## Source

- Controller: `app/controllers/api/v2/meta_controller.rb`
- Route: `config/routes.rb` (inside `api_routes` → `scope "v2"`)
- Spec: `spec/controllers/api/v2/meta_controller_spec.rb`
