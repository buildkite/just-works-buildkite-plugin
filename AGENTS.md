# Repository invariants

- Follow Buildkite's official plugin-writing guide and plugin template for
  development practices. Ask the user before extending those practices or adding
  any dependency, including development tools, test libraries, and CI plugins.
  Do not substitute an unapproved dependency in another language.
- Never modify vendored plugins. Every file under `vendor/` must remain
  byte-for-byte identical to the upstream file at the revision pinned in README.md.
  This applies to humans, agents, formatters, generators and runtime hooks.
- Do not patch, reformat, or rewrite vendored files, including temporary/runtime
  copies. Keep them genuine runtime dependencies, not unused provenance snapshots.
- Minimize changes to upstream behavior. Limit first-party integration to the
  requested defaults, configuration composition and diagnostics; do not add
  unrequested hardening or features. Moving a patch or replacement implementation
  into `lib/` does not make behavioral divergence acceptable.
- Fix dependency bugs upstream, not here. Check current upstream first, contribute
  the smallest fix if needed, then adopt a pinned upstream revision. Explain any
  remaining requirement gap instead of silently replacing dependency behavior.
- All current vendored plugins are owned by `buildkite-plugins`; their repositories
  are linked in README.md. Upstream contribution is the expected path. Verify
  current access and follow upstream review/release rules; ownership is not
  authorization to push, merge or release without the user's approval.
- A dependency upgrade may replace snapshots only with exact files from a new
  immutable upstream commit. Preserve licenses, verify every copied file against
  that commit, and update the README pins and `vendor.sha256` together. Never
  refresh checksums merely to bless a local vendor modification.

## Verification

- Follow [CONTRIBUTING.md](CONTRIBUTING.md) for the Plugin Tester (Bats), Plugin
  Linter, and ShellCheck commands mirrored by `.buildkite/pipeline.yml`.
- Keep first-party linting scoped to `hooks/` and `lib/`. Do not follow sourced
  files into `vendor/`, or pass vendored files to any linter or formatter.
- Keep `vendor/` excluded from all current and future formatting/linting tools.
  Vendor checksum checks and execution in behavioral tests are not linting.
- Run `sha256sum --check vendor.sha256`; it detects local drift but is not a
  substitute for comparison with upstream when changing dependency pins.
- Keep contributor rules in CONTRIBUTING.md and here, linked from the README.
- Keep the README concise and leave “Why this exists” blank for the maintainer.
