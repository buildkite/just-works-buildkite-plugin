#!/usr/bin/env bash

jw_error() {
  printf '\n^^^ +++\njust-works: %s\n' "$*" >&2
  return 1
}

jw_enabled() {
  local name="BUILDKITE_PLUGIN_JUST_WORKS_$1"
  [[ "${!name:-$2}" == true ]]
}

jw_validate() {
  local name value
  for name in ASSUME_ROLE ECR_ENABLED SSM_ENABLED SSM_INCLUDE_DEFAULT_PREFIX GITHUB_CHANGES_ENABLED; do
    name="BUILDKITE_PLUGIN_JUST_WORKS_$name"
    value="${!name:-}"
    if [[ -n "$value" && "$value" != true && "$value" != false ]]; then
      jw_error "$name must be true or false."; return 1
    fi
  done
  if jw_enabled SSM_ENABLED true; then
    for name in ${!BUILDKITE_PLUGIN_JUST_WORKS_SSM_ADDITIONAL_PARAMETERS_@}; do
      value="${name#BUILDKITE_PLUGIN_JUST_WORKS_SSM_ADDITIONAL_PARAMETERS_}"
      if [[ ! "$value" =~ ^[A-Z_][A-Z0-9_]*$ || -z "${!name}" ]]; then
        jw_error "Each ssm.additional_parameters entry needs an uppercase environment variable name and a non-empty SSM parameter name."; return 1
      fi
      case "$value" in
        PATH|BASH*|SHELLOPTS|ENV|IFS|LD_*|BUILDKITE_PLUGIN_*|JW_*)
          jw_error "SSM destination $value controls plugin execution and cannot be overwritten. Choose an application environment variable name."; return 1 ;;
      esac
    done
  fi
}

jw_require() {
  local program
  for program in "$@"; do
    command -v "$program" >/dev/null || { jw_error "Install $program on this agent to run the enabled component."; return 1; }
  done
}

jw_run() {
  local component="$1" hint="$2" state status=0 key value read_fd write_fd trace=false
  [[ "$-" != *x* ]] || trace=true
  set +x
  state=$(mktemp "${TMPDIR:-/tmp}/just-works.XXXXXXXX") || return 1
  # Independent offsets: the child finishes writing before the parent reads.
  # shellcheck disable=SC2094
  exec {read_fd}<"$state" {write_fd}>"$state"
  rm -f "$state"
  # Child shells isolate upstream exit, traps, options, functions and plugin config.
  # Only successful exports cross the boundary; stdout/stderr remain untouched.
  if bash "$(dirname "${BASH_SOURCE[0]}")/run-component" "$component" "${3:-}" 3>&"$write_fd"; then
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
      export "$key=$value"
    done <&"$read_fd"
  else
    status=$?
    jw_error "$hint The original tool output is above (exit status $status)." || true
    if [[ "$component" == role ]]; then
      local arn="$3" role_name="unavailable" account_id="unavailable"
      if [[ "$arn" =~ ^arn:[^:]+:iam::([0-9]{12}):role/(.+)$ ]]; then
        account_id="${BASH_REMATCH[1]}"
        role_name="${BASH_REMATCH[2]}"
        role_name="${role_name##*/}"
      fi
      printf 'Role name: "%s"\nAWS account ID: "%s"\nRole ARN: "%s"\n' "$role_name" "$account_id" "$arn" >&2
    fi
  fi
  exec {read_fd}<&- {write_fd}>&-
  [[ "$trace" == false ]] || set -x
  return "$status"
}

jw_environment() {
  jw_validate || return
  local JW_ROLE_ARN=""
  export JW_ROLE_ARN
  if jw_enabled ASSUME_ROLE true || jw_enabled ECR_ENABLED true || jw_enabled SSM_ENABLED true; then
    jw_require aws jq || return
  fi
  if jw_enabled ASSUME_ROLE true; then
    jw_require buildkite-agent || return
    jw_run resolve-role "Could not determine the conventional IAM role. Set role-arn explicitly, or supply account-id (or AWS_ACCOUNT_ID) and the Buildkite organization/pipeline slugs." || return
    jw_run role "Could not assume the workload IAM role. Check that the role exists and its OIDC trust policy permits this organization, pipeline and branch." "$JW_ROLE_ARN" || return
  fi
  if jw_enabled ECR_ENABLED true; then
    jw_require docker || return
    jw_run ecr "ECR login failed. Check the registry account IDs, region, ecr:GetAuthorizationToken permission, AWS credentials, and Docker availability." || return
  fi
  return 0
}

jw_pre_command() {
  jw_validate || return
  if jw_enabled SSM_ENABLED true; then
    jw_require aws jq || return
    jw_run ssm "SSM parameter loading failed. Check the prefix or parameter names and region, and grant the workload role ssm:GetParametersByPath (prefix discovery), ssm:GetParameters (all parameter loading), and kms:Decrypt for encrypted parameters. To opt out, set ssm.enabled: false." || return
  fi
  if jw_enabled GITHUB_CHANGES_ENABLED false; then
    jw_require aws jq buildkite-agent || return
    jw_run github "GitHub authentication through Exchange failed. Follow the diagnostic above, or set github.changes-enabled: false to opt out. The build command was not started." || return
  fi
  return 0
}
