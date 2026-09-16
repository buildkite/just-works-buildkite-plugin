# Just Works Buildkite Plugin

One plugin for the recurring AWS setup sequence, with no runtime code downloads:

1. Assume the conventional pipeline IAM role using Buildkite OIDC (`environment`).
2. Log into ECR, optionally using a separate role just for login (`environment`).
3. Load the pipeline's conventional SSM prefix into the command's environment
   using the workload role (`pre-command`).
4. Optionally exchange Buildkite OIDC for GitHub App authentication (`pre-command`).

Each component can be disabled independently. Failures stop the job, preserve the
tool's original stdout/stderr and exit status, and add a plain-English explanation
of what to check. A missing explicitly requested SSM parameter, or an entirely
empty prefix without explicit parameters, is an error. Discovery cannot detect one
missing leaf if other parameters exist: use explicit mappings when a particular
set of parameters is required.

## Status and installation

This directory is a self-contained plugin package, prepared for publication as
`buildkite/just-works-buildkite-plugin`. It is **not published or released** yet.
The intended usage after publication is `buildkite/just-works#<release-commit>`.
Use a full commit SHA for immutable consumer pinning: Git tags can be moved.

### All defaults

After publication (replace the placeholder with the actual release commit):

```yaml
steps:
  - command: ./run-tests
    plugins:
      - buildkite/just-works#<release-commit>: {}
```

For organization `buildkite`, pipeline `example`, and account `123456789012`:

- Role: `arn:aws:iam::123456789012:role/pipeline-buildkite-example`.
- ECR: the assumed role's account, in the inherited AWS region.
- SSM: immediate children of `/pipelines/buildkite/example/`, with decryption.
  `github_token` becomes `GITHUB_TOKEN`; `api-key` becomes `API_KEY`.

Account selection is `account-id`, then `AWS_ACCOUNT_ID`, then the ambient AWS
identity (`sts get-caller-identity`). **The ambient account must be the intended
target account.** On agents without ambient AWS credentials, supply `account-id`
or `role-arn`; Buildkite slugs cannot tell us the target account. An explicit ARN
bypasses account discovery. No alternate role is tried after a failed assumption.

### Overrides

```yaml
steps:
  - command: ./deploy
    plugins:
      - buildkite/just-works#<release-commit>:
          role-arn: arn:aws:iam::123456789012:role/app-deployer
          session-tags: [organization_slug, organization_id, pipeline_slug]
          ecr:
            role-arn: arn:aws:iam::210987654321:role/ci/ecr-reader
            accounts: ["210987654321", "999999999999"]
            region: eu-west-1
          ssm:
            prefix: /shared/example/
            region: us-east-2
```

For additional required parameters or aliases, supplement prefix discovery with:

```yaml
ssm:
  parameters:
    GITHUB_TOKEN: /pipelines/buildkite/example/github_token
    DATADOG_API_KEY: /deploy/DATADOG_API_KEY
```

`ssm.parameters` is unioned with the prefix by default. Explicit mappings win
when they target the same environment variable as a discovered parameter.
An empty prefix is allowed when explicit parameters are provided; a prefix access
error still fails the step. Every explicit parameter is required.

To load **only** specified parameters, without any prefix discovery:

```yaml
ssm:
  include-default-prefix: false
  parameters:
    GITHUB_TOKEN: /pipelines/buildkite/example/github_token
```

`include-default-prefix: false` disables discovery even when `ssm.prefix` is set.
If no explicit parameters are supplied in this mode, the plugin fails with a
configuration error; use `ssm.enabled: false` to disable SSM entirely.

For local development, run the hook tests below. If testing as a local-path
plugin inside a consuming repository, it only becomes available **after checkout**.
Use the remote plugin when authentication must happen before checkout. Put just-works
before Docker/Docker Compose or other plugins that consume its credentials.
SSM values are not available during checkout or earlier lifecycle hooks. Docker
plugins still need their usual environment forwarding configuration.

The workload role stays active through checkout, SSM loading and the command.
If `ecr.role-arn` differs, it is assumed with a fresh OIDC token in an isolated
child process. Both roles must independently trust the job; this is not role
chaining. Only the Docker login persists, not the ECR role's AWS credentials.

## Configuration

| Option | Default | Meaning |
| --- | --- | --- |
| `assume-role` | `true` | Enable all IAM assumptions; disable to use existing credentials for ECR, SSM and the command. |
| `role-arn` | Conventional ARN | `pipeline-<organization-slug>-<pipeline-slug>` in the resolved account. |
| `account-id` | `AWS_ACCOUNT_ID`, then ambient account | Target account for the conventional role; ignored with explicit `role-arn`. Quote the 12 digits. |
| `ecr.enabled` | `true` | Log into ECR. |
| `ecr.role-arn` | Workload role | Optional ECR-only identity. Ignored with `assume-role: false`. No top-level alias. |
| `ecr.accounts` | `[]` → authenticated caller's account | Quoted registry IDs or `public.ecr.aws`; override for cross-account or multiple registries. |
| `ecr.region` | Inherited AWS region | Override only ECR calls. Public ECR always uses `us-east-1`, as required by AWS. |
| `session-tags` | None | OIDC claims to send as session tags to both roles. Match your trust policies. |
| `ssm.enabled` | `true` | Load parameters before the command. |
| `ssm.prefix` | `/pipelines/<org>/<pipeline>/` | Nonrecursive parameter discovery. |
| `ssm.include-default-prefix` | `true` | Include prefix discovery alongside explicit mappings; `false` loads only explicit parameters. Also controls an overridden `ssm.prefix`. |
| `ssm.region` | Inherited AWS region | Override only SSM calls. |
| `ssm.parameters` | None | Additional required mappings from uppercase environment names to exact SSM names; override discovered destinations. |
| `github.changes-enabled` | `false` | Obtain an Exchange GitHub App token after SSM loading. |
| `github.organization` | `BUILDKITE_ORGANIZATION_SLUG` | GitHub organization authorized by the central Exchange policy. Override when the GitHub and Buildkite organizations differ. |

Inherited region means `AWS_REGION`, then `AWS_DEFAULT_REGION`, then the AWS
profile configuration. Component overrides do not alter the command's region.
Without any ECR region, fail clearly instead of choosing a legacy default.
For an explicit account, ARN partition follows the inherited region (`aws`,
`aws-cn`, or `aws-us-gov`); supply a full ARN for other partitions or nonstandard
partition/profile combinations. Ambient discovery uses the caller ARN partition.

The conceptual ECR default is `{enabled: true, role-arn: null, accounts: [],
region: null}`. **Omit unset fields rather than writing YAML `null`**: the agent's
plugin environment flattener does not accept null values. `{}` uses every default.

For role/ECR setup only, use `ssm: {enabled: false}`. To use existing credentials
for SSM only, set `assume-role: false` and `ecr: {enabled: false}`. Disabling all
three components, with GitHub authentication left disabled, performs no AWS/Docker
calls and requires no AWS tooling.

SSM value loading uses the unmodified upstream hook: duplicate mappings and batches
of up to ten are supported. Its text parser does not preserve multiline values or
all whitespace; use exact parameter names, not ARNs. We do not add a replacement
parser, malformed/NUL-value validation, ARN matching, or deferred batch exports.
An SSM mapping that changes AWS credentials or region can affect later batches,
just as it does upstream.

The wrapper discovers names and checks `InvalidParameters` before invoking
upstream. This adds one non-decrypting `GetParameters` call per ten mappings.
The check and subsequent load are separate requests, not an atomic snapshot;
parameters can change between them. Upstream failures stop the command and retain
the AWS error text, but upstream reports exit status 1 rather than the AWS status.
Shell-control variables (`PATH`, `BASH*`, `ENV`, `IFS`, `SHELLOPTS`, `LD_*`) and
plugin configuration variables cannot be SSM destinations. Prefix normalization
collisions fail rather than arbitrarily choosing a value. Loading a whole prefix
grants the command access to every immediate child; use a narrow prefix and IAM
policy, or explicit mappings with `include-default-prefix: false`, if the command
should receive fewer secrets.

## Opt-in GitHub authentication through Exchange

```yaml
steps:
  - command: ./comment-on-pr
    plugins:
      - buildkite/just-works#<release-commit>:
          session-tags: [organization_slug, organization_id, pipeline_slug, build_branch]
          github:
            changes-enabled: true
```

This invokes `arn:aws:lambda:us-east-1:032379705303:function:exchange` using the
workload AWS credentials and a fresh Buildkite OIDC token (audience `exchange`,
signed `organization_id` and `pipeline_id` claims). The Lambda invocation is
explicitly in `us-east-1`, independent of ECR/SSM region overrides; the command's
AWS region is unchanged. No Exchange request is made when disabled.

On success, `GH_TOKEN` and `GITHUB_TOKEN` both receive the returned token,
replacing any inherited or SSM-loaded values. Authentication happens after SSM
and before the command, not during checkout. If you need no SSM values, set
`ssm: {enabled: false}` separately. Tokens are short-lived and are not refreshed
during the command. This config obtains credentials; it does not itself modify
GitHub or guarantee write permissions. Repository and permission scope come
exclusively from Exchange's server-owned policy, including branch-specific rules.

**Onboarding is separate from enabling the plugin.** The workload role needs
`lambda:InvokeFunction` on that exact ARN (the proposed module option is
`enable_exchange = true`). The pipeline also needs a reviewed central policy
entry with immutable Buildkite IDs and approved GitHub repository/permissions.
Follow the [Exchange onboarding guide](https://github.com/buildkite/exchange#deployment-model).
Roles made by `pipelines_iam_role` also require the OIDC session tags shown above.

Both the consumer IAM grant and central policy changes should receive human
review. This plugin does not enroll pipelines or bypass that review. Existing
`ops` IAM-plan detection and manual apply steps still see the module's generated
IAM policy; consumers with other apply workflows must preserve equivalent review.

Errors preserve the original AWS/agent exit status and stderr, or the Exchange
error code and verbatim message. Service-level failures stop the step with status
1 even when Lambda invocation returned HTTP 200. Diagnostics distinguish:

- **Invocation denied/missing function:** exact ARN, workload credentials,
  `enable_exchange`/`lambda:InvokeFunction`, cross-account Lambda policy, deployment.
- **Pipeline not enrolled:** central policy path and immutable ID/slug checks.
- **Invalid OIDC:** audience, claims, clock/lifetime and Lambda validation logs.
- **GitHub failure:** App key, installation, approved permissions, GitHub health.
- **Lambda execution/malformed response:** `/aws/lambda/exchange` logs in
  `us-east-1`, with the pipeline and job ID printed for correlation.

Tokens are not logged; the owner-only Lambda response file is removed on success
or failure. No command runs on failed authentication, even if an old token exists.

## Failure examples

These stderr excerpts were produced by the real hooks with mocked AWS tools;
they are not claims about real AWS resources. `verbatim upstream detail` and
exit 42 are deliberately distinctive test fixtures. In a real pipeline, the
actual upstream stderr and exit status remain unchanged. Buildkite expands the
log group at `^^^ +++`.

### IAM role missing or assumption denied

AWS can return an access-denied response for either a nonexistent role or an
untrusted identity; the plugin does not pretend to distinguish them.

```text
An error occurred (AccessDenied): verbatim upstream detail

^^^ +++
just-works: Could not assume the workload IAM role. Check that the role exists and its OIDC trust policy permits this organization, pipeline and branch. The original tool output is above (exit status 42).
Role name: "pipeline-buildkite-example"
AWS account ID: "123456789012"
Role ARN: "arn:aws:iam::123456789012:role/pipeline-buildkite-example"
```

An ECR role assumption failure instead says `Could not assume the ECR IAM role`
and quotes that role's name, account and ARN. ECR login and the command do not run.
If account discovery fails before an ARN can be built, the plugin preserves that
error and asks for `role-arn` or `account-id` / `AWS_ACCOUNT_ID` and Buildkite slugs.

### SSM prefix empty or required parameter missing

An empty prefix without explicit parameters gives this diagnostic (followed by the SSM guidance below, with
exit status 1):

```text
No SSM parameters found under prefix "/pipelines/buildkite/example/". Create the parameters, override ssm.prefix, or set ssm.enabled: false.
```

For an explicitly mapped missing parameter, AWS returns `InvalidParameters`
rather than a failing CLI exit. The plugin reports that list, fails with status 1,
and exports nothing:

```text
SSM could not find the requested parameters. Check these names and the SSM region. AWS InvalidParameters:
["/pipelines/buildkite/example/github_token"]
```

### SSM access denied

For a discovery or missing-name preflight failure:

```text
An error occurred (AccessDenied): verbatim upstream detail

^^^ +++
just-works: SSM parameter loading failed. Check the prefix or parameter names and region, and grant the workload role ssm:GetParametersByPath (prefix discovery), ssm:GetParameters (all parameter loading), and kms:Decrypt for encrypted parameters. To opt out, set ssm.enabled: false. The original tool output is above (exit status 42).
```

For a failure during upstream value loading, upstream prefixes the original
message with `AWS command failed:`, and the same guidance reports exit status 1.

No command runs after these failures. Parameter values are not included in the
plugin's diagnostics.

## Requirements and security

- Linux with Bash 4.1+, AWS CLI v2, and jq. ECR also needs Docker; IAM assumption
  needs a Buildkite agent with OIDC support. Tools must already be installed.
- IAM OIDC trust for enabled roles; ECR authorization permission; SSM
  `ssm:GetParametersByPath` for discovery and `ssm:GetParameters` for loading
  mappings and, for customer-managed encrypted parameters,
  `kms:Decrypt`. The plugin does not create or modify IAM resources.
- GitHub authentication also requires Lambda invocation permission and Exchange
  enrollment; the job never reads Exchange's GitHub App private key itself.
- Use isolated agents/Docker configuration for mutually untrusted jobs. Docker
  credentials are managed by the ECR plugin and are not logged out afterward.
- Export transport uses an owner-only temporary file unlinked **before** secrets
  are written. Shell tracing is disabled while handling secrets. Parameter values,
  STS credentials, and OIDC tokens are not deliberately logged. Original upstream
  errors are not rewritten; normal Buildkite log redaction can still apply.
- The build command can access exported secrets. Do not enable this plugin for
  untrusted code unless the role trust and pipeline policy permit that access.

## Pinned dependencies

Bundled code and licenses live in `vendor/`. Neither hooks nor their libraries
download executable code. Versions are based on the existing Buildkite pipelines:

| Dependency | Version | Immutable upstream revision |
| --- | --- | --- |
| aws-assume-role-with-web-identity | v1.4.0 | [697551f](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin/commit/697551fae50ad4ba3179caf4348c8467b1a63cc2) |
| ecr | v2.9.0 | [73d58b9](https://github.com/buildkite-plugins/ecr-buildkite-plugin/commit/73d58b9491c439db5c5d136474ac910ea31f41d0) |
| aws-ssm | main snapshot (2026-09-16) | [dff5bd8](https://github.com/buildkite-plugins/aws-ssm-buildkite-plugin/commit/dff5bd8c716178d2aa3eb0f255011a98ce3cb9b5) |

Every vendored file is byte-identical to its pinned upstream revision. IAM, ECR
and SSM execute the pristine bundled code. `lib/ssm.bash` composes the prefix and
explicit mappings and checks for missing parameters, then sources upstream's
`hooks/pre-command` without replacing its commands, parsing, or export behavior.
The SSM pin includes upstream's AWS CLI error-propagation fix. It is an immutable
commit, not a runtime reference to the moving `main` branch.
The wrapper also rejects empty/null STS credentials and requires AWS CLI v2 for
ECR, avoiding its legacy `eval` path.

### Contributor invariant: never modify vendored plugins

**Humans and agents must never patch, reformat, generate changes to, or rewrite
vendored plugins**, including temporary/runtime copies. Keep dependencies genuine:
their pinned upstream code should execute, not serve only as provenance.

**Keep changes to upstream behavior to a minimum. Fix bugs upstream, not here.**
First-party integration should implement only the requested defaults,
configuration composition and diagnostics—not unrequested hardening or features.
Moving a patch into `lib/`, or maintaining a replacement loader there, is not a
workaround for this rule. Check current upstream, contribute the smallest needed
fix, then adopt a pinned upstream revision. Explain any remaining requirement gap
rather than silently replacing upstream behavior.

All three current vendored plugins belong to the `buildkite-plugins` GitHub
organization (see the source links above). Contributing upstream is the expected
path, subject to repository review/release rules and user authorization. These
rules are also recorded in [AGENTS.md](AGENTS.md).

Dependency upgrades must copy exact upstream files from a new immutable commit,
preserve licenses, verify each file against upstream, and update the README pins
and `vendor.sha256` together. Do not regenerate checksums to legitimize a local
vendor patch. The checksum test detects drift; upstream comparison is required
when updating pins. Release changes as a new just-works version.

Pinning guarantees the plugin's code, not the host's AWS CLI, jq, Docker, agent,
mutable SSM values, IAM policies, or the deployed Exchange service and its policy.
The Exchange client is local plugin code; no server code is downloaded at runtime.
Pin your agent image too for reproducible
tooling. No plugin can make external AWS state immutable.

### Why bundled files rather than Git submodules?

Submodule gitlinks pin exact commits and make upstream upgrades easier to review.
However, agent v4.0.3 clones plugins recursively **before** checking out the
requested plugin ref, without updating submodules afterward
([checkout implementation](https://github.com/buildkite/agent/blob/v4.0.3/internal/job/plugin.go#L438-L467)).
A local reproduction of that command sequence left dependency B from the default
branch checked out even though the selected release pinned A. A subsequent
`git submodule update --init --recursive` corrected it. Cached plugin checkouts
are reused without repair, and `BUILDKITE_GIT_SUBMODULES=false` disables recursive
plugin cloning entirely.

Using submodules safely would require explicit post-checkout synchronization and
gitlink verification before executing any dependency. That also adds network and
Git availability requirements, access to each dependency repository before our
authentication hooks run, and possible failures before our friendly diagnostics
can run. Submodules fetch code; they do not compose plugin hooks or
propagate configuration/exports for us. For this small dependency set, bundled
files currently provide the simpler runtime guarantee. No submodule conversion
has been made.

## Verification

From this directory:

```sh
python3 tests/test_plugin.py
shellcheck -x -P SCRIPTDIR hooks/* lib/*
sha256sum --check vendor.sha256
```

Tests execute the bundled IAM/ECR/SSM code and first-party Exchange client
against fake AWS, Docker and agent binaries, and verify vendor checksums;
they make no AWS calls. They cover lifecycle order, role selection, switches,
fail-fast errors, verbatim stderr/status, parameter batching and mapping, missing
values, credential export, Exchange transport/service errors and token precedence,
and secret-safe tracing. A real AWS/OIDC job smoke test
is still required before releasing. The Notion “GitHub Tokens” guide could not be
read during development because its MCP connection required authentication.

See [the configuration audit](configuration-audit.md) for the limits of automatic
configuration in Buildkite's checked-in pipelines.
