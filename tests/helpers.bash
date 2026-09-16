ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
PREFIX=BUILDKITE_PLUGIN_JUST_WORKS_
SECRET='spaces quotes '\''" $(touch /never-execute)'
ROLE=arn:aws:iam::123456789012:role/pipeline-buildkite-example
ECR_ROLE=arn:aws:iam::210987654321:role/ci/ecr-reader

setup_plugin() {
  [[ -z ${TEST_TMP:-} ]] || rm -rf "$TEST_TMP"
  while IFS='=' read -r name _; do
    case "$name" in
      BUILDKITE_PLUGIN_JUST_WORKS_*|FAIL|MISSING|PAGES|PROFILE_REGION|EMPTY_STS|TRACE|EXPECT_GITHUB_ORG|EXCHANGE_RESPONSE|EMPTY_EXCHANGE_OIDC|LAMBDA_METADATA|AWS_ACCOUNT_ID|AWS_ACCESS_KEY_ID)
        unset "$name"
        ;;
    esac
  done < <(env)

  TEST_TMP=$(mktemp -d /tmp/just-works-tests.XXXXXX)
  export TEST_TMP CALLS=$TEST_TMP/calls VALUE=$SECRET HOME=$TEST_TMP TMPDIR=$TEST_TMP
  export BUILDKITE_JOB_ID=job-id BUILDKITE_ORGANIZATION_SLUG=buildkite BUILDKITE_PIPELINE_SLUG=example AWS_REGION=ap-southeast-2 AWS_DEFAULT_REGION=us-west-1
  for tool in aws docker buildkite-agent; do ln -s "$ROOT/tests/mock-tool" "$TEST_TMP/$tool"; done
  export PATH="$TEST_TMP:/usr/bin:/bin"
}
teardown_plugin() { rm -rf "$TEST_TMP"; }
cfg() { export "$PREFIX$1=$2"; }
run_plugin() {
  local flags=-eu; [[ ${TRACE:-} ]] && flags=-eux
  : >"$CALLS"
  run --separate-stderr env ROOT="$ROOT" bash "$flags" -c 'source "$ROOT/hooks/environment"; source "$ROOT/hooks/pre-command"; set +x; while IFS= read -r name; do printf "%s\0%s\0" "$name" "${!name}"; done < <(compgen -e) | jq -Rsc '\''split("\u0000")[:-1] as $a | reduce range(0;$a|length;2) as $i ({}; .[$a[$i]]=$a[$i+1])'\'' | sed "s/^/RESULT=/"'
  RUN_OUTPUT=$output
  [[ -z $stderr ]] || RUN_OUTPUT+=$'\n'"$stderr"
  RESULT_LINE=$(printf '%s\n' "${lines[@]}" | sed -n 's/^RESULT=//p' | tail -1)
  CALLS_JSON=$(jq -sc . "$CALLS" 2>/dev/null || echo '[]')
  [[ -z $(find "$TEST_TMP" -maxdepth 1 -name 'just-works.*' -print -quit) ]]
}
assert_success() { [[ $status -eq 0 ]] || { echo "$RUN_OUTPUT" >&2; return 1; }; }
assert_failure() { [[ $status -ne 0 && -z $RESULT_LINE ]]; }
assert_status() { [[ $status -eq $1 && ( $1 -eq 0 || -z $RESULT_LINE ) ]] || { echo "wanted $1 got $status: $RUN_OUTPUT" >&2; return 1; }; }
assert_output_has() { [[ $RUN_OUTPUT == *"$1"* ]] || { echo "missing <$1>: $RUN_OUTPUT" >&2; return 1; }; }
assert_output_lacks() { [[ $RUN_OUTPUT != *"$1"* ]] || { echo "unexpected <$1>: $RUN_OUTPUT" >&2; return 1; }; }
assert_stderr_lacks() { [[ $stderr != *"$1"* ]] || { echo "unexpected stderr <$1>: $stderr" >&2; return 1; }; }
events() { jq -r '.[].e' <<<"$CALLS_JSON"; }
exported() { jq -r --arg k "$1" '.[$k] // empty' <<<"$RESULT_LINE"; }
