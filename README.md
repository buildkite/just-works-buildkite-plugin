# Just Works Buildkite Plugin

Assume AWS roles, log into ECR, load SSM parameters, and optionally obtain GitHub
credentials with one plugin and pinned upstream dependencies.

## Why this exists

## Using all defaults

Replace `<commit>` with the full commit SHA you want to run. No release is tagged yet.

```yaml
steps:
  - command: ./run-tests
    plugins:
      - buildkite/just-works#<commit>: {}
```

Assumes `pipeline-<organization>-<pipeline>` in the current AWS account, logs into
that account's ECR, and loads `/pipelines/<organization>/<pipeline>/` from SSM.
AWS region settings are inherited. Requires Bash 4.1+, AWS CLI v2, jq, Docker,
and a Buildkite agent with OIDC support, plus the corresponding IAM permissions.

## Using all overrides

```yaml
steps:
  - command: ./deploy
    plugins:
      - buildkite/just-works#<commit>:
          assume-role: true
          account-id: "123456789012"
          role-arn: arn:aws:iam::123456789012:role/app-deployer
          session-tags: [organization_slug, organization_id, pipeline_slug, build_branch]
          ecr:
            enabled: true
            role-arn: arn:aws:iam::210987654321:role/ecr-reader
            accounts: ["210987654321", "999999999999"]
            region: eu-west-1
          ssm:
            enabled: true
            prefix: /shared/example/
            include-default-prefix: true
            region: us-east-2
            additional_parameters:
              API_TOKEN: /deploy/api-token
          github:
            changes-enabled: true
            organization: buildkite-plugins
```

An explicit `role-arn` takes precedence over `account-id`. The ECR role is used
only for registry login. `additional_parameters` supplements the prefix, with
explicit destinations winning collisions. Set `include-default-prefix: false`
to load only those mappings. ECR and SSM region overrides do not change the
command's region. See [plugin.yml](plugin.yml) for the configuration schema.

## Disabling components

```yaml
steps:
  - command: ./run-tests
    plugins:
      - buildkite/just-works#<commit>:
          assume-role: false
          ecr:
            enabled: false
          ssm:
            enabled: false
          github:
            changes-enabled: false
```

Each switch is independent. Disable role assumption to use existing AWS
credentials; disabling all components performs no authentication or SSM loading.

## GitHub authentication

`github.changes-enabled: true` supplies `GH_TOKEN` and `GITHUB_TOKEN` through
Exchange, replacing inherited or SSM-loaded tokens. It is off by default.
`github.organization` selects the GitHub organization and defaults to the
Buildkite organization slug. Permissions depend on the pipeline's approved
[Exchange enrollment](https://github.com/buildkite/exchange#deployment-model).

## Vendored dependencies

These upstream files execute unchanged. Nothing is downloaded or upgraded at
runtime; each just-works commit fixes the dependency code it runs.

| Plugin | Version | Purpose | Immutable revision |
| --- | --- | --- | --- |
| aws-assume-role-with-web-identity | v1.4.0 | Obtain workload and optional ECR role credentials using OIDC. | [697551f](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin/commit/697551fae50ad4ba3179caf4348c8467b1a63cc2) |
| ecr | v2.9.0 | Authenticate Docker to ECR registries. | [73d58b9](https://github.com/buildkite-plugins/ecr-buildkite-plugin/commit/73d58b9491c439db5c5d136474ac910ea31f41d0) |
| aws-ssm | main snapshot, 2026-09-16 | Fetch, decrypt, and export parameters, including upstream's AWS error-propagation fix. | [dff5bd8](https://github.com/buildkite-plugins/aws-ssm-buildkite-plugin/commit/dff5bd8c716178d2aa3eb0f255011a98ce3cb9b5) |

The wrapper supplies defaults, composes SSM mappings, and adds failure diagnostics.
SSM retains upstream's text-parsing limitations; multiline values and ARN mappings
are not supported. Pinning code does not freeze AWS resources or agent tooling.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, tests, and contributor rules,
and [AGENTS.md](AGENTS.md) for agent guidance. [MIT license](LICENSE).
