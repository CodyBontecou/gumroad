# OpenAPI auto-generation pipeline

This directory holds the scripts that build `docs/openapi.yaml` from the
codebase. The goal is to keep the public Gumroad API v2 spec in lockstep with
the controllers, models, and tests rather than letting it rot as a hand-edited
YAML file.

## Pipeline at a glance

```
config/routes.rb ──┐
                   ├─► routes_scraper.rb ─► tmp/openapi/routes.json
spec/controllers/  │                        tmp/openapi/coverage.md
  api/v2/**        │
                   ├─► run_rspec.sh ─────► tmp/openapi/from_rspec.yaml
                   │   (OPENAPI=1, slow,    (also cached in
                   │    rspec-openapi)       script/openapi/cached/)
app/models/**      │
                   ├─► as_json_extractor ─► tmp/openapi/from_serializers.yaml
                   │
spec/controllers/  │
  api/v2/**        ├─► static_specs.rb ───► tmp/openapi/from_specs.yaml
                   │
                   └─► merger.rb ─────────► docs/openapi.yaml
```

| Phase | Script | Loads Rails? | Notes |
| --- | --- | :---: | --- |
| A | `routes_scraper.rb` | yes | Scrapes Rails routes table for `api/v2/*`. Run via `bin/rails runner`. |
| B1 | `run_rspec.sh` | yes | Runs `spec/controllers/api/v2/` with `OPENAPI=1`, recording real responses. Slow (~2 min). |
| B2 | `as_json_extractor.rb` | no | Pure Prism AST walk over `app/models/**/*.rb`. |
| B3 | `static_specs.rb` | no | Pure Prism AST walk over `spec/controllers/api/v2/**/*.rb`. |
| C | `merger.rb` | no | Combines the four intermediate artifacts plus `docs/openapi.yaml.handwritten.bak` (for `info`/`servers`/`securitySchemes`) into the final spec. |
| D1 | `drift.rb` | no | Compares the generated spec against the handwritten backup and writes `tmp/openapi/drift_report.md`. |

All intermediates land in `tmp/openapi/`, which is gitignored. The only files
the pipeline checks into git are the final `docs/openapi.yaml` and the cached
rspec recording at `script/openapi/cached/from_rspec.yaml`.

## Running the pipeline locally

```sh
# Full pipeline including the slow rspec recording. ~2 minutes.
bundle exec rake openapi:generate

# Quick regen using the cached rspec recording. Set this when you've only
# touched routes, models, or specs and don't need to re-record HTTP responses.
bundle exec rake openapi:regen

# Verify the committed docs/openapi.yaml matches what the pipeline would
# produce. Exits 0 on match, 1 on drift (with a unified diff printed).
bundle exec rake openapi:check

# Print the drift report comparing the generated spec to the handwritten backup.
bundle exec rake openapi:drift
```

`rake openapi:generate` automatically updates `script/openapi/cached/from_rspec.yaml`
after a successful rspec run. Commit that file alongside any change that
affects an API serializer so CI can run the cheap `regen` flow without
re-recording specs.

## Cached rspec recording

`script/openapi/cached/from_rspec.yaml` is the committed output of
`run_rspec.sh`. The merger reads this file when `tmp/openapi/from_rspec.yaml`
isn't present (CI, fresh checkouts, or anyone who ran `rake openapi:regen`
without a prior full `generate`).

Update it whenever:
- An API v2 controller's response shape changes
- An `as_json` method on a model returned through the API changes
- A new v2 endpoint or status code lands

To refresh: `bundle exec rake openapi:generate` and commit the updated
`from_rspec.yaml` along with the regenerated `docs/openapi.yaml`.

## Reading the drift report

`rake openapi:drift` writes `tmp/openapi/drift_report.md` and prints it. The
report compares the generated `docs/openapi.yaml` against
`docs/openapi.yaml.handwritten.bak` (the snapshot of the original
hand-maintained spec) and highlights:

- Endpoints in routes but missing from the spec
- Endpoints documented in the handwritten spec but not in the generated one
- Schema fields that disagree (extra, missing, or differently typed)

Treat large deltas in either direction as something to investigate before
trusting the regenerated spec.

## CI behavior

`.github/workflows/openapi-drift.yml` runs on PRs that touch
`app/controllers/api/v2/**`, `app/models/**`, `config/routes.rb`, or
`script/openapi/**`. It runs `rake openapi:check` with `SKIP_RSPEC=1` (using
the committed cached recording) and posts a PR comment with the diff when
drift is detected.

The job is **non-blocking** for now: `continue-on-error: true` is set so a
drift result surfaces as a yellow check rather than a red one. We'll flip this
to a hard gate after a two-week soak period during which the team gets used to
running `rake openapi:generate` before pushing.
