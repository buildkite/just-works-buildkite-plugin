# Contributing

Follow the [Buildkite plugin-writing guide](https://buildkite.com/docs/pipelines/integrations/plugins/writing)
and [plugin template](https://github.com/buildkite-plugins/template-buildkite-plugin).
Ask the maintainer before extending these practices or adding dependencies,
including development tools, test libraries, or CI plugins.

## Workflow

1. Create a branch or fork, and read [AGENTS.md](AGENTS.md).
2. Make the smallest change and preserve meaningful behavioral coverage.
3. Keep `plugin.yml`, hooks, tests, and README examples synchronized.
4. Run the checks below and open a pull request. Do not bypass branch protections.

Keep the README concise: defaults, overrides, disabling components, a brief
GitHub explanation, and the dependency table. Leave “Why this exists” blank for
the maintainer. ECR and SSM upstream READMEs provide usage precedents.

## Vendoring invariants

- Never patch, reformat, lint, or rewrite `vendor/`, including temporary/runtime
  copies. Dependencies must remain byte-identical to their pinned upstream files
  and actually execute, not serve as unused provenance snapshots.
- Minimize behavioral differences. First-party code composes configuration and
  adds requested diagnostics; it must not replace upstream implementations.
- Fix dependency bugs upstream. All current dependencies belong to
  `buildkite-plugins`. Follow upstream review/release rules and obtain approval
  before publishing upstream changes.
- Upgrade by copying exact files from a new immutable upstream commit. Preserve
  licenses, verify against upstream, and update the README pins and `vendor.sha256`
  together. Never regenerate checksums to bless a local patch.
- Exclude `vendor/` from every formatter/linter. Its checksum checks and execution
  in behavioral tests remain enabled; `.gitattributes` collapses it in GitHub diffs.

## Development and validation

The Buildkite pipeline uses Plugin Tester (Bats), Plugin Linter, and ShellCheck.
Run the same checks locally with Docker:

```sh
docker run --rm -v "$PWD:/plugin" buildkite/plugin-tester:v4.2.0
docker run --rm -e PLUGIN_ID=buildkite/just-works -v "$PWD:/plugin:ro" buildkite/plugin-linter:v2.1.0
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:v0.11.0 --exclude=SC1091 hooks/* lib/*
sha256sum --check vendor.sha256
```

Bats runs real hooks against fake AWS, Docker, and agent commands. It covers role
selection and diagnostics, regions, SSM mapping/batching/failures, Exchange, secret
tracing, and vendor integrity. Plugin Linter validates metadata and README examples.
ShellCheck checks only first-party code without following vendored sources.
No Node/npm or Python setup is required.

A real AWS/OIDC smoke test is still required before release.
