#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers
setup() { setup_plugin; }
teardown() { teardown_plugin; }

@test "vendored files match the immutable manifest" {
  run sha256sum -c vendor.sha256; assert_success
  run bash -c 'diff -u <(cut -d" " -f3 vendor.sha256|sort) <(find vendor -type f|sort)'; assert_success
}
@test "roles, ECR and SSM run in order and export asymmetric credentials" {
  cfg ROLE_ARN "$ROLE"; cfg ECR_ROLE_ARN "$ECR_ROLE"; cfg ECR_ACCOUNTS_0 999999999999; cfg SSM_ADDITIONAL_PARAMETERS_TOKEN /app/token
  run_plugin; assert_success; [[ $(events) == $'buildkite-agent\nrole:'"$ROLE"$'\nbuildkite-agent\nrole:'"$ECR_ROLE"$'\necr\ndocker\nssm-path\nssm-check\nssm' ]]
  [[ $(exported TOKEN) == "$SECRET" ]]; [[ $(exported AWS_ACCESS_KEY_ID) == "role:$ROLE" ]]; [[ $(jq -r '.[4].k'<<<"$CALLS_JSON") == "role:$ECR_ROLE" ]]; [[ $(jq -r '.[-1].k'<<<"$CALLS_JSON") == "role:$ROLE" ]]
  jq -e '.[5].args|any(contains("999999999999.dkr.ecr.ap-southeast-2.amazonaws.com"))'<<<"$CALLS_JSON"
}
@test "every component can be disabled and ambient credentials survive" {
  cfg ASSUME_ROLE false; cfg ECR_ENABLED false; cfg SSM_ENABLED false; run_plugin; assert_success; [[ $(events) == '' ]]
  unset "${PREFIX}SSM_ENABLED"; export AWS_ACCESS_KEY_ID=existing; run_plugin; assert_success; [[ $(events) == $'ssm-path\nssm-check\nssm' ]]; [[ $(exported AWS_ACCESS_KEY_ID) == existing ]]
}
@test "invalid configuration fails before network access" {
  for key in ACCOUNT_ID SSM_ADDITIONAL_PARAMETERS_PATH SSM_INCLUDE_DEFAULT_PREFIX GITHUB_CHANGES_ENABLED ECR_ENABLED; do
    teardown_plugin; setup_plugin; case $key in ACCOUNT_ID) value=123; expected='12 digits';; SSM_ADDITIONAL_PARAMETERS_PATH) value=/unsafe; expected='cannot be overwritten';; *) value=yes; expected='must be true or false';; esac
    cfg "$key" "$value"; run_plugin; assert_failure; assert_output_has "$expected"; [[ $(events) == '' ]]
  done
}
@test "upstream failures preserve status text and component hint" {
  cfg ROLE_ARN "$ROLE"; cfg ECR_ROLE_ARN "$ECR_ROLE"
  for spec in "buildkite-agent|OIDC trust" "role:$ROLE|OIDC trust" 'ecr|ECR login failed' 'docker|ECR login failed' "role:$ECR_ROLE|ECR IAM role" 'ssm-path|SSM parameter loading failed'; do
    export FAIL=${spec%%|*}; run_plugin; assert_status 42; assert_output_has 'verbatim upstream detail'; assert_output_has "${spec#*|}"; [[ $(events|tail -1) == "$FAIL" ]]; done
}
@test "role diagnostics identify only the failing role" {
  local first=arn:aws:iam::123456789012:role/ci/ecr-reader second=arn:aws-us-gov:iam::210987654321:role/deployment/app-deployer
  cfg ROLE_ARN "$first"; cfg ECR_ROLE_ARN "$second"
  for spec in "$first|ecr-reader|123456789012|$second" "$second|app-deployer|210987654321|$first"; do
    IFS='|' read -r arn name account other <<<"$spec"
    export FAIL="role:$arn"
    run_plugin
    assert_status 42
    [[ $(events | tail -1) == "role:$arn" ]]
    assert_output_has "Role name: \"$name\""
    assert_output_has "AWS account ID: \"$account\""
    assert_output_has "Role ARN: \"$arn\""
    assert_stderr_lacks "$other"
    assert_output_has 'An error occurred (AccessDenied): verbatim upstream detail'
  done
}
@test "missing SSM parameters show AWS InvalidParameters" { cfg SSM_ADDITIONAL_PARAMETERS_TOKEN /app/token; export MISSING=/app/token; run_plugin; assert_failure; assert_output_has '["/app/token"]'; assert_output_has 'SSM parameter loading failed'; }
@test "SSM fetch failure is not hidden" { export FAIL=ssm; run_plugin; assert_status 1; assert_output_has 'AWS command failed: An error occurred (AccessDenied): verbatim upstream detail'; assert_output_has 'SSM parameter loading failed'; }
@test "upstream text parsing keeps only the first value line" { cfg SSM_ADDITIONAL_PARAMETERS_TOKEN /app/token; export VALUE=$'first line\nsecond line\n'; run_plugin; assert_success; [[ $(exported TOKEN) == 'first line' ]]; assert_output_has 'Exported TOKEN as value of parameter /app/token'; }
@test "SSM batches ten names and exposes first-batch credential changes" {
  for i in {0..10}; do cfg "SSM_ADDITIONAL_PARAMETERS_KEY_$i" "/app/$i"; done; cfg SSM_ADDITIONAL_PARAMETERS_TOKEN /app/token; cfg SSM_ADDITIONAL_PARAMETERS_DUPLICATE /app/token; cfg SSM_ADDITIONAL_PARAMETERS_AWS_ACCESS_KEY_ID /app/next-credentials
  run_plugin; assert_success; [[ $(events|grep -c '^ssm$') == 2 ]]; mapfile -t keys < <(jq -r '.[]|select(.e=="ssm")|.k'<<<"$CALLS_JSON"); [[ ${keys[0]} == "role:$ROLE" && ${keys[1]} == "$SECRET/app/next-credentials" ]]; [[ $(exported KEY_10) == "$SECRET/app/10" && $(exported DUPLICATE) == "$SECRET" ]]
}
@test "a missing parameter in a later batch prevents all fetches" {
  for i in {00..10}; do cfg "SSM_ADDITIONAL_PARAMETERS_KEY_$i" "/app/${i#0}"; done
  export MISSING=/app/10
  run_plugin; assert_failure; [[ $(events|grep -c ssm-check) == 2 ]]; [[ $(events|grep -c '^ssm$'||:) == 0 ]]
}
@test "ECR account discovery failure is preserved" { cfg ROLE_ARN "$ROLE"; export FAIL=identity; run_plugin; assert_status 42; assert_output_has 'verbatim upstream detail'; assert_output_has 'ECR login failed'; }
@test "null STS credentials are rejected" { export EMPTY_STS=1; run_plugin; assert_failure; assert_output_has 'no usable credentials'; [[ $(events|tail -1) == "role:$ROLE" ]]; }
@test "xtrace does not expose credentials or values" { export TRACE=1; run_plugin; assert_success; [[ $(exported GITHUB_TOKEN) == prefix-secret ]]; trace_output=$(printf '%s\n' "$RUN_OUTPUT" | grep -v '^RESULT='); for secret in oidc-token ecr-password spaces AWS_SECRET_ACCESS_KEY=secret; do [[ $trace_output != *"$secret"* ]]; done; }
@test "configuration belonging to other plugin instances cannot leak in" { export BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX=OTHER_ BUILDKITE_PLUGIN_ECR_ASSUME_ROLE_ROLE_ARN=wrong BUILDKITE_PLUGIN_AWS_SSM_PARAMETERS_UNEXPECTED=/unexpected; run_plugin; assert_success; [[ -z $(exported UNEXPECTED) ]]; [[ $(exported AWS_ACCESS_KEY_ID) == "role:$ROLE" ]]; [[ $CALLS_JSON != *wrong* ]]; }
@test "defaults discover role, inherit regions and remove internal exports" {
  run_plugin
  assert_success
  [[ $(events) == $'identity\nbuildkite-agent\nrole:'"$ROLE"$'\nidentity\necr\ndocker\nssm-path\nssm-check\nssm' ]]
  jq -e '.[-3].args | index("/pipelines/buildkite/example/") and index("--no-recursive")' <<<"$CALLS_JSON"
  jq -e '.[-1] | .r == "ap-southeast-2" and .d == "ap-southeast-2"' <<<"$CALLS_JSON"
  [[ $(exported GITHUB_TOKEN) == prefix-secret ]]
  [[ $(exported AWS_REGION) == ap-southeast-2 ]]
  [[ $(exported AWS_DEFAULT_REGION) == us-west-1 ]]
  [[ -z $(exported JW_ROLE_ARN) ]]
}
@test "ECR, SSM region and prefix overrides stay local" {
  cfg ECR_REGION eu-west-1
  cfg SSM_REGION us-east-2
  cfg SSM_PREFIX /shared/project
  run_plugin
  assert_success
  jq -e '.[] | select(.e=="ecr") | .r=="eu-west-1" and .d=="eu-west-1"' <<<"$CALLS_JSON"
  jq -e '.[-3].args | index("/shared/project/")' <<<"$CALLS_JSON"
  jq -e '.[-1] | .r=="us-east-2" and .d=="us-east-2"' <<<"$CALLS_JSON"
  [[ $(exported AWS_REGION) == ap-southeast-2 ]]
  [[ $(exported AWS_DEFAULT_REGION) == us-west-1 ]]
}
@test "account override precedence and identical ECR role reuse" {
  cfg ECR_ENABLED false
  cfg SSM_ENABLED false
  export AWS_ACCOUNT_ID=111111111111
  run_plugin
  assert_success
  [[ $(events) == $'buildkite-agent\nrole:arn:aws:iam::111111111111:role/pipeline-buildkite-example' ]]

  cfg ACCOUNT_ID 222222222222
  run_plugin
  assert_success
  [[ $(events) == $'buildkite-agent\nrole:arn:aws:iam::222222222222:role/pipeline-buildkite-example' ]]

  teardown_plugin
  setup_plugin
  cfg ROLE_ARN "$ROLE"
  cfg ECR_ROLE_ARN "$ROLE"
  run_plugin
  assert_success
  [[ $(events | grep -c '^role:') == 1 ]]
}
@test "missing account identity and pipeline slug give diagnostics" { export FAIL=identity; run_plugin; assert_status 42; assert_output_has 'Could not determine the conventional IAM role'; unset FAIL BUILDKITE_PIPELINE_SLUG; run_plugin; assert_failure; assert_output_has 'pipeline slug is missing'; [[ $(events) == '' ]]; }
@test "prefix pagination tolerates empty pages and preserves values" { export PAGES='[[["api-key","spaces quotes '\''\" $(touch /never-execute)"]],[],[["another_value","different"]]]'; run_plugin; assert_success; [[ $(events|grep -c ssm-path) == 3 ]]; [[ $(exported API_KEY) == "$SECRET" && $(exported ANOTHER_VALUE) == different ]]; }
@test "explicit SSM mappings union with prefix and win collisions" {
  cfg SSM_ADDITIONAL_PARAMETERS_GITHUB_TOKEN /app/token
  cfg SSM_ADDITIONAL_PARAMETERS_EXTRA /app/extra
  export PAGES='[[["github_token","discovered-token"]],[["keep-me","kept-value"]]]'
  run_plugin
  assert_success
  [[ $(events | grep '^ssm') == $'ssm-path\nssm-path\nssm-check\nssm' ]]
  [[ $(exported GITHUB_TOKEN) == "$SECRET" && $(exported KEEP_ME) == kept-value && $(exported EXTRA) == "$SECRET/app/extra" ]]

  export PAGES='[[]]'
  run_plugin
  assert_success
  [[ $(exported GITHUB_TOKEN) == "$SECRET" ]]

  unset PAGES
  export MISSING=/app/token
  run_plugin
  assert_failure
  assert_output_has InvalidParameters

  unset MISSING
  export FAIL=ssm-path
  run_plugin
  assert_status 42
  assert_output_has 'verbatim upstream detail'
}
@test "explicit-only SSM skips prefix and does not require slugs" {
  cfg ASSUME_ROLE false
  cfg ECR_ENABLED false
  cfg SSM_INCLUDE_DEFAULT_PREFIX false
  cfg SSM_PREFIX /ignored/
  cfg SSM_ADDITIONAL_PARAMETERS_TOKEN /app/token
  unset BUILDKITE_PIPELINE_SLUG
  export FAIL=ssm-path
  run_plugin
  assert_success
  [[ $(events) == $'ssm-check\nssm' ]]
  [[ $(exported TOKEN) == "$SECRET" ]]
  [[ -z $(exported GITHUB_TOKEN) ]]

  unset FAIL "${PREFIX}SSM_PREFIX" "${PREFIX}SSM_ADDITIONAL_PARAMETERS_TOKEN"
  run_plugin
  assert_failure
  assert_output_has 'no parameters were specified'
  [[ $(events) == '' ]]
}
@test "unsafe, duplicate, nested and empty prefix discovery fails closed" { for spec in '[[ ]]|No SSM parameters found' '[[["api-key","one"]],[["API_KEY","two"]]]|Multiple SSM parameters' '[[["path","unsafe"]]]|cannot be overwritten' '[[["nested/key","value"]]]|explicit mapping'; do export PAGES=${spec%%|*}; run_plugin; assert_failure; assert_output_has "${spec#*|}"; done; }
@test "ECR region falls back through default and profile" { unset AWS_REGION; run_plugin; assert_success; [[ $CALLS_JSON == *123456789012.dkr.ecr.us-west-1.amazonaws.com* ]]; unset AWS_DEFAULT_REGION; export PROFILE_REGION=eu-central-1; run_plugin; assert_success; [[ $CALLS_JSON == *123456789012.dkr.ecr.eu-central-1.amazonaws.com* ]]; }
@test "Exchange is opt-in, uses workload role, overrides SSM tokens and hides secrets" {
  cfg GITHUB_CHANGES_ENABLED true
  cfg ECR_ROLE_ARN "$ECR_ROLE"
  cfg GITHUB_ORGANIZATION buildkite-plugins
  export EXPECT_GITHUB_ORG=buildkite-plugins TRACE=1
  run_plugin
  assert_success
  [[ $(events | tail -3) == $'ssm\nexchange-oidc\nexchange' ]]
  [[ $(exported GH_TOKEN) == ghs_exchange_secret ]]
  [[ $(exported GITHUB_TOKEN) == ghs_exchange_secret ]]
  [[ $(exported AWS_REGION) == ap-southeast-2 ]]
  [[ $(exported AWS_DEFAULT_REGION) == us-west-1 ]]
  [[ $(jq -r '.[-1].k' <<<"$CALLS_JSON") == "role:$ROLE" ]]
  [[ $CALLS_JSON != *exchange-oidc-secret* ]]
  trace_output=$(printf '%s\n' "$RUN_OUTPUT" | grep -v '^RESULT=')
  [[ $trace_output != *ghs_exchange_secret* ]]
  [[ $trace_output != *exchange-oidc-secret* ]]

  teardown_plugin
  setup_plugin
  cfg GITHUB_CHANGES_ENABLED false
  run_plugin
  assert_success
  [[ $(events | grep -c '^exchange' || :) == 0 ]]
  [[ -z $(exported GH_TOKEN) ]]
}
@test "Exchange transport errors preserve original status and text" { cfg GITHUB_CHANGES_ENABLED true; for spec in 'exchange-oidc|Could not request a Buildkite OIDC token' 'exchange|enable_exchange = true'; do export FAIL=${spec%%|*}; run_plugin; assert_status 42; assert_output_has 'verbatim upstream detail'; assert_output_has "${spec#*|}"; done; }
@test "Exchange service errors preserve exact messages and actionable hints" { cfg GITHUB_CHANGES_ENABLED true; for spec in 'constraint_mismatch|immutable Buildkite organization/pipeline IDs' 'token_validation_failed|agent clock' 'bad_request|github.organization' 'upstream_failure|App private key in SSM'; do code=${spec%%|*}; export EXCHANGE_RESPONSE="{\"error\":{\"code\":\"$code\",\"message\":\"Original Exchange error: exact detail\"}}"; run_plugin; assert_status 1; assert_output_has 'Original Exchange error: exact detail'; assert_output_has "${spec#*|}"; done; }
@test "Exchange rejects malformed responses, empty tokens and Lambda errors" {
  cfg GITHUB_CHANGES_ENABLED true
  for spec in 'not-json-with-secret|invalid JSON' '{}|no usable GitHub token' \
    '{"token":null}|no usable GitHub token' \
    '{"token":"before\u0000after"}|no usable GitHub token'; do
    export EXCHANGE_RESPONSE=${spec%%|*}
    run_plugin
    assert_status 1
    assert_output_has "${spec#*|}"
    assert_output_lacks not-json-with-secret
  done
  unset EXCHANGE_RESPONSE
  export EMPTY_EXCHANGE_OIDC=1
  run_plugin
  assert_status 1
  assert_output_has 'empty OIDC token'
  unset EMPTY_EXCHANGE_OIDC
  export LAMBDA_METADATA='{"StatusCode":202}'
  run_plugin
  assert_status 1
  assert_output_has 'synchronous invocation'
  export LAMBDA_METADATA='{"StatusCode":200,"FunctionError":"Unhandled"}'
  export EXCHANGE_RESPONSE='{"errorMessage":"Original Lambda execution error"}'
  run_plugin
  assert_status 1
  assert_output_has 'Original Lambda execution error'
}
@test "Exchange can use ambient credentials without AWS setup components" { cfg ASSUME_ROLE false; cfg ECR_ENABLED false; cfg SSM_ENABLED false; cfg GITHUB_CHANGES_ENABLED true; export AWS_ACCESS_KEY_ID=ambient; run_plugin; assert_success; [[ $(events) == $'exchange-oidc\nexchange' ]]; [[ $(jq -r '.[-1].k'<<<"$CALLS_JSON") == ambient && $(exported GH_TOKEN) == ghs_exchange_secret ]]; }
