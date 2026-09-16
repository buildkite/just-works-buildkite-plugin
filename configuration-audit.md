# Can Buildkite pipelines derive their AWS configuration?

**Conventional role names are a useful default, especially in new repositories;
accounts and purpose-specific roles still need overrides.** Pipeline and
organization slugs explain naming conventions, but not the target AWS account.

The follow-up organization audit covered all 620 accessible GitHub repositories
and 3,596 candidate files. In the 70-repository last-90-days cohort, eight had
entrypoint-checked own-CI IAM usage: seven were entirely conventional, and
`lab-ops` used a conventional plan role plus an `-apply` override. That is **10 of
11 operative declarations**, across four AWS accounts, not a success rate for
all 70 repositories. Copied and obsolete configurations were excluded.

Live visibility was limited to 13 pipelines. From 283 readable log prefixes in
11 builds, 203 resolved role observations yielded 13 distinct pipeline/ARN pairs:
10 conventional, three exceptions. `bsite-infra` used the same conventional name
in four accounts; `ops-plan` and two specialized deploy roles needed overrides.
Both `buildkite` and `agent` used conventional roles in sampled successful builds.
Logs include dynamically uploaded steps but cannot cover every dynamic branch.

No exact organization-wide count of inherently non-inferable IAM/SSM settings
can be established from these sources. SSM was not inventoried live; no secrets
were read. A conventional prefix can discover existing leaves but cannot detect
an absent required leaf unless the user names it explicitly.

## Scope

Inspected the provided checkouts of `buildkite/buildkite`, `agent`, `ops`,
`bsite-infra`, and `buildkite-gha`, including checked-in `.buildkite` definitions,
templates, and generators. The detailed examples below are this initial source
sample; the subsequent broader IAM findings are summarized above. Neither is an
organization-wide inventory of live pipeline settings. Repeated definitions are not
independent pipelines, so occurrence counts cannot establish that “most pipelines”
need a particular setting. No production secrets were retrieved.

## Findings

| Value | Derivable? | Recommendation |
| --- | --- | --- |
| Organization/pipeline identity | Yes: standard Buildkite variables. | Use for metadata and naming suggestions. |
| Role session name | Yes: job ID. | Keep upstream `buildkite-job-${BUILDKITE_JOB_ID}`. |
| Session tags | Values yes; required claim set depends on trust policy. | Explicit list; usual examples use organization slug/ID and pipeline slug, sometimes branch. |
| AWS account ID | Not from standard Buildkite identity variables. | `account-id` or `AWS_ACCOUNT_ID`, otherwise ambient identity; override when the agent account is not the target. |
| Role name | Common convention, but purpose-specific exceptions. | Default `pipeline-<org>-<pipeline>`; `role-arn` overrides it. Never retry another role on denial. |
| AWS region | Not from pipeline slug or step key. | Inherit AWS environment/profile; component-local overrides. |
| ECR account | Discoverable from authenticated caller, but may be different. | Allow STS discovery; explicit registry IDs for cross-account/multi-account access. |
| SSM namespace | Often `/pipelines/<org>/<pipeline>/`. | Default prefix; allow `ssm.prefix` override. |
| SSM leaf and destination env name | Discoverable for conventional names; aliases are not inferable. | Uppercase immediate leaf names and replace hyphens with underscores; explicit mappings for aliases or required leaves. |
| Step-specific permissions | Step keys are neither universal nor an authority. | Explicit role override; do not derive authorization from labels or keys. |

## Concrete examples and counterexamples

Paths below are relative to each named repository in the inspected checkouts.

- **Common role:** `buildkite/.buildkite/pipeline.yml:19–24` assumes
  `pipeline-buildkite-buildkite` with an `OIDC_ASSUME_ROLE_ARN` override and
  organization/pipeline tags.
- **Purpose-specific role and cross-pipeline SSM:** that same file at `29–45`
  assumes `pipeline-buildkite-buildkite-pr-comments`, includes `build_branch`, and
  maps `GITHUB_PR_COMMENT_TOKEN` to
  `/pipelines/buildkite/deploy/buildkite_github_pr_comment_token`. Neither the
  current pipeline slug nor destination environment variable gives that mapping.
- **Cross-account ECR:** `agent/.buildkite/pipeline.release-stable.yml:116–125`
  assumes a role in account `032379705303`, but logs into registry `445615400570`.
  Using the role's account automatically would authenticate the wrong registry.
- **Shared ECR followed by deployment credentials:**
  `bsite-infra/.buildkite/scripts/generate-pipeline.sh:121–137` assumes a shared
  pull role, logs into ECR `032379705303`, then assumes `plan_role` in
  `pre-command`. The earlier `27–49` logic selects roles/accounts by environment.
- **Multiple registries:** `buildkite/.buildkite/pipeline.deploy.yml:83–85`
  requests two accounts. A single inferred ID is insufficient.
- **Legacy parameter namespace:**
  `buildkite/.buildkite/pipeline.deploy.yml:427–429` uses
  `/deploy/DATADOG_API_KEY`, not the pipeline-scoped convention.

## Follow-up

To establish the claim for *most live pipelines*, inventory active pipeline
settings plus generated steps, group by distinct pipeline rather than template
occurrence, and compare each resolved value with a proposed derivation. An
organization-maintained mapping of pipeline/purpose to role ARN, registry IDs,
region and secret mappings could remove repetition without guessing privileges.
The plugin now adopts conventional role/prefix defaults with explicit overrides,
not a separately fetched policy registry. Dependency code is immutable when the
plugin is pinned, but discovered SSM names and values are mutable AWS state.

The Notion guide remains unverified pending MCP authentication. Its conventions
may refine the suggested defaults, but cannot eliminate the observed exceptions.
