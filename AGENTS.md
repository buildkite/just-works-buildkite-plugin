# Repository invariants

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

- Run `python3 tests/test_plugin.py` for behavioral tests and vendor checksums.
- Run `shellcheck -x -P SCRIPTDIR hooks/* lib/*` for first-party shell code.
- Run `sha256sum --check vendor.sha256`; it detects local drift but is not a
  substitute for comparison with upstream when changing dependency pins.
- Keep this invariant in the README's contributor guidance as well.
