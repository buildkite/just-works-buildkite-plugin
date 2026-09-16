#!/usr/bin/env bash
# Runs inside run-component's isolated shell, with tracing disabled.

function_arn="arn:aws:lambda:us-east-1:032379705303:function:exchange"
github_organization="${BUILDKITE_PLUGIN_JUST_WORKS_GITHUB_ORGANIZATION:-${BUILDKITE_ORGANIZATION_SLUG:-}}"
if [[ ! "$github_organization" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  echo 'The GitHub organization is missing or invalid. Set github.organization to the organization authorized in the central Exchange policy.' >&2
  exit 1
fi
echo "~~~ :github: Requesting Exchange authentication for $github_organization"
printf 'Exchange function: "%s"\nBuildkite pipeline: "%s/%s"\nJob ID: "%s"\n' "$function_arn" "${BUILDKITE_ORGANIZATION_SLUG:-unknown}" "${BUILDKITE_PIPELINE_SLUG:-unknown}" "${BUILDKITE_JOB_ID:-unknown}"

if oidc_token=$(buildkite-agent oidc request-token --audience exchange --claim organization_id --claim pipeline_id); then
  if [[ -z "$oidc_token" ]]; then
    echo 'Buildkite returned an empty OIDC token. Check agent OIDC support and job authentication; no Exchange request was sent.' >&2
    exit 1
  fi
else
  status=$?
  echo 'Could not request a Buildkite OIDC token for Exchange. Check agent OIDC support and job authentication. The required audience is exchange, with organization_id and pipeline_id claims.' >&2
  exit "$status"
fi

request=$(jq -Rcn --arg github_organization "$github_organization" '{token: input, github_organization: $github_organization}' <<< "$oidc_token")
response_file=$(mktemp "${TMPDIR:-/tmp}/just-works.exchange.XXXXXXXX")
trap 'rm -f -- "$response_file"' EXIT
# Keep the OIDC payload out of the AWS process arguments. mktemp creates an
# owner-only response file, removed on success or failure before the child exits.
if metadata=$(aws lambda invoke --region us-east-1 --function-name "$function_arn" \
  --cli-binary-format raw-in-base64-out --payload fileb:///dev/stdin \
  --log-type None --output json "$response_file" <<< "$request"); then
  :
else
  status=$?
  echo "Could not invoke Exchange at $function_arn. Check the active workload credentials and grant lambda:InvokeFunction on this exact ARN (pipelines_iam_role: enable_github_token_exchange = true). For cross-account calls, check the Lambda resource policy permits the caller's AWS Organization. If the function is missing, ask Platform to check its deployment in us-east-1. AWS CLI v2 is required." >&2
  exit "$status"
fi

if ! jq -e 'type == "object" and .StatusCode == 200' <<< "$metadata" >/dev/null; then
  echo 'Lambda did not confirm a successful synchronous invocation. Ask Platform to check the Exchange Lambda deployment and invocation metadata.' >&2
  exit 1
fi
if ! jq -e 'type == "object"' "$response_file" >/dev/null 2>&1; then
  echo 'Exchange returned an invalid JSON response. Ask Platform to inspect /aws/lambda/exchange in us-east-1 for this job. The response body is withheld because it may contain credentials.' >&2
  exit 1
fi
if jq -e '.FunctionError != null' <<< "$metadata" >/dev/null; then
  # Print the original Lambda error message, not arbitrary response fields.
  jq -r '.errorMessage // "Lambda returned FunctionError without an errorMessage"' "$response_file" >&2
  echo 'The Exchange Lambda failed while executing. Ask Platform to inspect /aws/lambda/exchange in us-east-1 for this job, including its GitHub App key, policy configuration and GitHub connectivity.' >&2
  exit 1
fi
if jq -e '.error != null' "$response_file" >/dev/null; then
  jq -r '.error | "Exchange error (\(.code)): \(.message)"' "$response_file" >&2
  code=$(jq -r '.error.code' "$response_file")
  case "$code" in
    constraint_mismatch)
      echo 'Exchange has no matching authorization for this pipeline identity. Ask Platform to review the central policy in ops/github-tf/exchange-lambda.tf: verify the immutable Buildkite organization/pipeline IDs and slugs, then apply the approved policy before retrying. IAM invocation permission alone does not enroll a pipeline.' >&2 ;;
    token_validation_failed)
      echo 'Exchange rejected the Buildkite OIDC token. Check agent clock and token lifetime, audience exchange, and organization_id/pipeline_id claims; ask Platform to inspect Lambda validation logs if it persists.' >&2 ;;
    bad_request)
      echo "Exchange rejected the request for GitHub organization $github_organization. Check github.organization and its installation entry in the pipeline's central Exchange policy; ask Platform to review any required enrollment." >&2 ;;
    upstream_failure)
      echo 'Exchange could not obtain a GitHub App token. Ask Platform to inspect Lambda logs, GitHub availability, the App private key in SSM, installation access to the repositories, and approved permissions.' >&2 ;;
    *)
      echo 'Exchange returned an unrecognized error. Ask Platform to inspect /aws/lambda/exchange in us-east-1 using the pipeline and job details above.' >&2 ;;
  esac
  exit 1
fi
if ! jq -e '.token | type == "string" and test("^[A-Za-z0-9_]+$")' "$response_file" >/dev/null; then
  echo 'Exchange returned no usable GitHub token. Ask Platform to check its response contract and GitHub App installation. No token was exported.' >&2
  exit 1
fi
token=$(jq -r '.token' "$response_file")
printf '%s\0%s\0' GH_TOKEN "$token" GITHUB_TOKEN "$token" >&3
echo 'GitHub authentication ready: GH_TOKEN and GITHUB_TOKEN will use the Exchange token. Repository and permission scope are controlled by the central Exchange policy.'
