#!/usr/bin/env bash
# Compose upstream configuration; upstream owns value parsing and exports.

if [[ "${BUILDKITE_PLUGIN_AWS_SSM_INCLUDE_DEFAULT_PREFIX:-true}" == true ]]; then
  prefix="${BUILDKITE_PLUGIN_AWS_SSM_PATH%/}/"
  if [[ "$prefix" != /* || "$prefix" == / ]]; then
    echo 'SSM prefix must be a non-root absolute path.' >&2
    exit 1
  fi
  echo "Loading SSM parameters from $prefix"
  next_token=""
  discovered_keys=()
  while true; do
    aws_command=(aws ssm get-parameters-by-path --path "$prefix" --no-recursive --no-paginate --query '{Names: Parameters[].Name, NextToken: NextToken}' --output json)
    [[ -z "$next_token" ]] || aws_command+=(--next-token "$next_token")
    response=$("${aws_command[@]}")
    while IFS= read -r name; do
      leaf="${name#"$prefix"}"
      if [[ "$name" != "$prefix"* || ! "$leaf" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
        echo "SSM parameter $name cannot be mapped to an environment variable. Disable ssm.include-default-prefix and use ssm.parameters for an explicit mapping." >&2
        exit 1
      fi
      key="${leaf^^}"
      key="${key//-/_}"
      case "$key" in
        PATH|BASH*|SHELLOPTS|ENV|IFS|LD_*|BUILDKITE_PLUGIN_*|JW_*)
          echo "SSM destination $key controls plugin execution and cannot be overwritten. Choose an application environment variable name." >&2
          exit 1 ;;
      esac
      for existing in "${discovered_keys[@]}"; do
        if [[ "$existing" == "$key" ]]; then
          echo "Multiple SSM parameters map to $key under $prefix. Disable ssm.include-default-prefix and use ssm.parameters to choose distinct names." >&2
          exit 1
        fi
      done
      discovered_keys+=("$key")
      config_key="BUILDKITE_PLUGIN_AWS_SSM_PARAMETERS_$key"
      # Explicit destinations take precedence over discovered defaults.
      if [[ ! -v "$config_key" ]]; then
        export "$config_key=$name"
      fi
    done < <(jq -r '.Names[]' <<< "$response")
    next_token=$(jq -r '.NextToken // empty' <<< "$response")
    [[ -n "$next_token" ]] || break
  done
fi

configured=("${!BUILDKITE_PLUGIN_AWS_SSM_PARAMETERS_@}")
if [[ ${#configured[@]} == 0 ]]; then
  if [[ "${BUILDKITE_PLUGIN_AWS_SSM_INCLUDE_DEFAULT_PREFIX:-true}" == true ]]; then
    echo "No SSM parameters found under prefix \"$prefix\". Create the parameters, override ssm.prefix, or set ssm.enabled: false." >&2
  else
    echo 'SSM prefix loading is disabled and no parameters were specified. Set ssm.parameters, enable ssm.include-default-prefix, or set ssm.enabled: false.' >&2
  fi
  exit 1
fi

# Upstream filters InvalidParameters out of its response. Preflight names only;
# leave all value fetching, parsing, batching and exports to the upstream hook.
required_names=()
for config_key in "${configured[@]}"; do
  required_names+=("${!config_key}")
done
for ((offset = 0; offset < ${#required_names[@]}; offset += 10)); do
  invalid=$(aws ssm get-parameters --query InvalidParameters --output json --names "${required_names[@]:offset:10}")
  if [[ "$(jq 'length' <<< "$invalid")" != 0 ]]; then
    echo 'SSM could not find the requested parameters. Check these names and the SSM region. AWS InvalidParameters:' >&2
    printf '%s\n' "$invalid" >&2
    exit 1
  fi
done

# shellcheck source=../vendor/aws-ssm/hooks/pre-command
source "$(dirname "${BASH_SOURCE[0]}")/../vendor/aws-ssm/hooks/pre-command"
