import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFIX = "BUILDKITE_PLUGIN_JUST_WORKS_"
SECRET = "spaces quotes '\" $(touch /never-execute)"
ROLE = "arn:aws:iam::123456789012:role/pipeline-buildkite-example"
ECR_ROLE = "arn:aws:iam::210987654321:role/ci/ecr-reader"

MOCK = '''#!/usr/bin/env python3
import json, os, sys
tool = os.path.basename(sys.argv[0])
args = sys.argv[1:]
event = tool
if tool == "aws":
    if args == ["--version"]:
        print("aws-cli/2.15.0 Python/3.11 Linux/6")
        sys.exit(0)
    if "assume-role-with-web-identity" in args:
        event = "role:" + args[args.index("--role-arn") + 1]
    elif "get-caller-identity" in args:
        event = "identity"
    elif "get-login-password" in args:
        event = "ecr"
    elif "get-parameters" in args:
        event = "ssm-check" if "InvalidParameters" in args else "ssm"
    elif "get-parameters-by-path" in args:
        event = "ssm-path"
    elif args[:2] == ["lambda", "invoke"]:
        event = "exchange"
    elif args == ["configure", "get", "region"]:
        print(os.environ.get("PROFILE_REGION", ""))
        sys.exit(0)
if tool == "buildkite-agent" and "exchange" in args:
    event = "exchange-oidc"
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([event, os.environ.get("AWS_ACCESS_KEY_ID"), args, os.environ.get("AWS_REGION"), os.environ.get("AWS_DEFAULT_REGION")]) + "\\n")
if event == os.environ.get("FAIL"):
    print("An error occurred (AccessDenied): verbatim upstream detail", file=sys.stderr)
    sys.exit(42)
if event.startswith("role:"):
    if os.environ.get("EMPTY_STS"):
        print('{}')
    else:
        print(json.dumps({"Credentials": {"AccessKeyId": event, "SecretAccessKey": "secret", "SessionToken": "token"}, "AssumedRoleUser": {"AssumedRoleId": "example"}}))
elif event == "identity":
    if "--query" in args:
        print("123456789012")
    else:
        print(json.dumps({"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:role/agent"}))
elif event == "ecr":
    print("ecr-password")
elif event == "buildkite-agent":
    print("oidc-token")
elif event == "exchange-oidc":
    assert args == ["oidc", "request-token", "--audience", "exchange", "--claim", "organization_id", "--claim", "pipeline_id"]
    print("" if os.environ.get("EMPTY_EXCHANGE_OIDC") else "exchange-oidc-secret")
elif event == "exchange":
    payload_path = args[args.index("--payload") + 1]
    assert payload_path == "fileb:///dev/stdin"
    with open(payload_path[len("fileb://"):]) as request_file:
        request = json.load(request_file)
    assert request == {"token": "exchange-oidc-secret", "github_organization": os.environ.get("EXPECT_GITHUB_ORG", "buildkite")}
    assert args[args.index("--function-name") + 1] == "arn:aws:lambda:us-east-1:032379705303:function:exchange"
    assert args[args.index("--region") + 1] == "us-east-1"
    assert os.stat(args[-1]).st_mode & 0o777 == 0o600
    response = os.environ.get("EXCHANGE_RESPONSE", '{"token":"ghs_exchange_secret","expires_at":"2026-09-16T23:00:00Z"}')
    with open(args[-1], "w") as response_file:
        response_file.write(response)
    print(os.environ.get("LAMBDA_METADATA", '{"StatusCode":200}'))
elif event == "docker":
    assert sys.stdin.read().strip() == "ecr-password"
elif event == "ssm-path":
    prefix = args[args.index("--path") + 1]
    pages = json.loads(os.environ.get("PAGES", '[[["github_token", "prefix-secret"]]]'))
    index = int(args[args.index("--next-token") + 1]) if "--next-token" in args else 0
    result = {"Names": [prefix + name for name, value in pages[index]]}
    if index + 1 < len(pages):
        result["NextToken"] = str(index + 1)
    print(json.dumps(result))
elif event in ("ssm", "ssm-check"):
    names = args[args.index("--names") + 1:]
    assert len(names) <= 10
    invalid = [n for n in names if n == os.environ.get("MISSING")]
    if event == "ssm-check":
        assert "--with-decryption" not in args
        print(json.dumps(invalid))
    else:
        assert args[args.index("--query") + 1] == "Parameters[].[Name,Value]"
        assert args[args.index("--output") + 1] == "text"
        assert "--with-decryption" in args
        prefix = os.environ.get("BUILDKITE_PLUGIN_JUST_WORKS_SSM_PREFIX", "/pipelines/buildkite/example/").rstrip("/") + "/"
        pages = json.loads(os.environ.get("PAGES", '[[["github_token", "prefix-secret"]]]'))
        stored = {prefix + name: value for page in pages for name, value in page}
        for name in reversed(names):
            if name not in invalid:
                value = stored.get(name, os.environ["VALUE"] + ("" if name == "/app/token" else name))
                print(name + "\\t" + value)
else:
    raise RuntimeError([tool, args])
'''


class PluginTest(unittest.TestCase):
    def test_vendored_files_match_manifest(self):
        listed = set()
        for line in (ROOT / "vendor.sha256").read_text().splitlines():
            digest, path = line.split(maxsplit=1)
            listed.add(path)
            self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), digest,
                             f"{path} drifted: restore upstream bytes, do not bless a local patch")
        self.assertEqual(listed, {p.relative_to(ROOT).as_posix() for p in (ROOT / "vendor").rglob("*") if p.is_file()})

    def run_plugin(self, config=None, extra=None, trace=False):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for tool in ("aws", "docker", "buildkite-agent"):
                path = directory / tool
                path.write_text(MOCK)
                path.chmod(0o755)
            env = {"PATH": f"{directory}:/usr/bin:/bin", "HOME": str(directory),
                   "TMPDIR": str(directory), "CALLS": str(directory / "calls"),
                   "VALUE": SECRET, "BUILDKITE_JOB_ID": "job-id",
                   "BUILDKITE_ORGANIZATION_SLUG": "buildkite", "BUILDKITE_PIPELINE_SLUG": "example",
                   "AWS_REGION": "ap-southeast-2", "AWS_DEFAULT_REGION": "us-west-1"}
            settings = {}
            settings.update(config or {})
            env.update({PREFIX + k: v for k, v in settings.items() if v is not None})
            env.update(extra or {})
            env = {k: v for k, v in env.items() if v is not None}
            # Source hooks just as the agent does; assert the command sees exports.
            script = f'source "{ROOT}/hooks/environment"; source "{ROOT}/hooks/pre-command"; set +x; /usr/bin/python3 -c \'import os,json; print("RESULT=" + json.dumps(dict(os.environ)))\''
            result = subprocess.run(["bash", "-eux" if trace else "-eu", "-c", script],
                                    env=env, text=True, capture_output=True)
            calls = [json.loads(line) for line in (directory / "calls").read_text().splitlines()] if (directory / "calls").exists() else []
            exports = next((json.loads(line[7:]) for line in result.stdout.splitlines() if line.startswith("RESULT=")), {})
            self.assertFalse(list(directory.glob("just-works.*")))
            return result, calls, exports

    def test_order_roles_and_exports(self):
        result, calls, exports = self.run_plugin({"ROLE_ARN": ROLE, "ECR_ROLE_ARN": ECR_ROLE, "ECR_ACCOUNTS_0": "999999999999", "SSM_PARAMETERS_TOKEN": "/app/token"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["buildkite-agent", "role:" + ROLE, "buildkite-agent", "role:" + ECR_ROLE, "ecr", "docker", "ssm-path", "ssm-check", "ssm"])
        self.assertEqual(calls[4][1], "role:" + ECR_ROLE)
        self.assertEqual(calls[-1][1], "role:" + ROLE)
        self.assertIn("999999999999.dkr.ecr.ap-southeast-2.amazonaws.com", calls[5][2])
        self.assertEqual(exports["TOKEN"], SECRET)
        self.assertEqual(exports["AWS_ACCESS_KEY_ID"], "role:" + ROLE)

    def test_every_component_can_be_disabled(self):
        result, calls, _ = self.run_plugin({"ASSUME_ROLE": "false", "ECR_ENABLED": "false", "SSM_ENABLED": "false"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        result, calls, exports = self.run_plugin({"ASSUME_ROLE": "false", "ECR_ENABLED": "false"}, {"AWS_ACCESS_KEY_ID": "existing"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["ssm-path", "ssm-check", "ssm"])
        self.assertEqual(exports["AWS_ACCESS_KEY_ID"], "existing")

    def test_missing_configuration_fails_before_network(self):
        for config, expected in [({"ACCOUNT_ID": "123"}, "12 digits"),
                                 ({"SSM_PARAMETERS_PATH": "/unsafe"}, "cannot be overwritten"),
                                 ({"SSM_INCLUDE_DEFAULT_PREFIX": "yes"}, "must be true or false"),
                                 ({"GITHUB_CHANGES_ENABLED": "yes"}, "must be true or false"),
                                 ({"ECR_ENABLED": "yes"}, "must be true or false")]:
            with self.subTest(config=config):
                result, calls, _ = self.run_plugin(config)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertEqual(calls, [])

    def test_upstream_failures_keep_error_and_stop(self):
        for event, hint in [("buildkite-agent", "OIDC trust"), ("role:" + ROLE, "OIDC trust"), ("ecr", "ECR login failed"), ("docker", "ECR login failed"), ("role:" + ECR_ROLE, "ECR IAM role"), ("ssm-path", "SSM parameter loading failed")]:
            with self.subTest(event=event):
                result, calls, exports = self.run_plugin({"ROLE_ARN": ROLE, "ECR_ROLE_ARN": ECR_ROLE}, {"FAIL": event})
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(calls[-1][0], event)
                self.assertIn("An error occurred (AccessDenied): verbatim upstream detail", result.stderr)
                self.assertIn(hint, result.stderr)
                self.assertEqual(exports, {})

    def test_role_errors_quote_the_failing_role_identity(self):
        first = "arn:aws:iam::123456789012:role/ci/ecr-reader"
        second = "arn:aws-us-gov:iam::210987654321:role/deployment/app-deployer"
        config = {"ROLE_ARN": first, "ECR_ROLE_ARN": second}
        for arn, role_name, account_id, other in [
            (first, "ecr-reader", "123456789012", second),
            (second, "app-deployer", "210987654321", first),
        ]:
            with self.subTest(arn=arn):
                result, calls, _ = self.run_plugin(config, {"FAIL": "role:" + arn})
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(calls[-1][0], "role:" + arn)
                self.assertIn(f'Role name: "{role_name}"', result.stderr)
                self.assertIn(f'AWS account ID: "{account_id}"', result.stderr)
                self.assertIn(f'Role ARN: "{arn}"', result.stderr)
                self.assertNotIn(other, result.stderr)
                self.assertIn("An error occurred (AccessDenied): verbatim upstream detail", result.stderr)

    def test_ssm_missing_parameters_fail_with_original_response(self):
        for extra in [{"MISSING": "/app/token"}]:
            result, _, exports = self.run_plugin({"SSM_PARAMETERS_TOKEN": "/app/token"}, extra=extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('["/app/token"]', result.stderr)
            self.assertIn("SSM parameter loading failed", result.stderr)
            self.assertEqual(exports, {})

    def test_upstream_ssm_failure_is_not_hidden(self):
        result, calls, exports = self.run_plugin(extra={"FAIL": "ssm"})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(calls[-1][0], "ssm")
        self.assertIn("AWS command failed: An error occurred (AccessDenied): verbatim upstream detail", result.stderr)
        self.assertIn("SSM parameter loading failed", result.stderr)
        self.assertEqual(exports, {})

    def test_ssm_uses_upstream_text_parsing_without_local_corrections(self):
        result, _, exports = self.run_plugin({"SSM_PARAMETERS_TOKEN": "/app/token"}, {"VALUE": "first line\nsecond line\n"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(exports["TOKEN"], "first line")
        self.assertIn("Exported TOKEN as value of parameter /app/token", result.stdout)

    def test_batching_and_duplicate_mappings(self):
        config = {f"SSM_PARAMETERS_KEY_{i}": f"/app/{i}" for i in range(11)}
        config["SSM_PARAMETERS_TOKEN"] = "/app/token"
        config["SSM_PARAMETERS_DUPLICATE"] = "/app/token"
        config["SSM_PARAMETERS_AWS_ACCESS_KEY_ID"] = "/app/next-credentials"
        result, calls, exports = self.run_plugin(config)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(c[0] == "ssm" for c in calls), 2)
        # Upstream exports each batch immediately: credentials from the first
        # batch are visible to the next, rather than locally deferred.
        self.assertEqual([c[1] for c in calls if c[0] == "ssm"], ["role:" + ROLE, SECRET + "/app/next-credentials"])
        self.assertEqual(exports["KEY_10"], SECRET + "/app/10")
        self.assertEqual(exports["KEY_2"], SECRET + "/app/2")
        self.assertEqual(exports["DUPLICATE"], SECRET)

    def test_later_ssm_batch_failure_stops_command(self):
        config = {f"SSM_PARAMETERS_KEY_{i:02}": f"/app/{i}" for i in range(11)}
        result, calls, exports = self.run_plugin(config, {"MISSING": "/app/10"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum(c[0] == "ssm-check" for c in calls), 2)
        self.assertFalse(any(c[0] == "ssm" for c in calls))
        self.assertEqual(exports, {})

    def test_ecr_account_discovery_error_is_not_hidden(self):
        result, calls, _ = self.run_plugin({"ROLE_ARN": ROLE}, extra={"FAIL": "identity"})
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(calls[-1][0], "identity")
        self.assertIn("verbatim upstream detail", result.stderr)
        self.assertIn("ECR login failed", result.stderr)

    def test_null_credentials_are_not_exported(self):
        result, calls, _ = self.run_plugin(extra={"EMPTY_STS": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no usable credentials", result.stderr)
        self.assertEqual(calls[-1][0], "role:" + ROLE)

    def test_trace_does_not_expose_credentials_or_values(self):
        result, _, exports = self.run_plugin(trace=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(exports["GITHUB_TOKEN"], "prefix-secret")
        for secret in ["oidc-token", "ecr-password", "spaces", "AWS_SECRET_ACCESS_KEY=secret"]:
            self.assertNotIn(secret, result.stderr)

    def test_other_plugin_configuration_cannot_leak_in(self):
        result, calls, exports = self.run_plugin(extra={
            "BUILDKITE_PLUGIN_AWS_ASSUME_ROLE_WITH_WEB_IDENTITY_CREDENTIAL_NAME_PREFIX": "OTHER_",
            "BUILDKITE_PLUGIN_ECR_ASSUME_ROLE_ROLE_ARN": "wrong",
            "BUILDKITE_PLUGIN_AWS_SSM_PARAMETERS_UNEXPECTED": "/unexpected",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED", exports)
        self.assertEqual(exports["AWS_ACCESS_KEY_ID"], "role:" + ROLE)
        self.assertNotIn("wrong", str(calls))

    def test_defaults_and_inherited_regions(self):
        result, calls, exports = self.run_plugin()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["identity", "buildkite-agent", "role:" + ROLE, "identity", "ecr", "docker", "ssm-path", "ssm-check", "ssm"])
        self.assertIn("/pipelines/buildkite/example/", calls[-3][2])
        self.assertIn("--no-recursive", calls[-3][2])
        self.assertEqual(calls[-1][3:], ["ap-southeast-2", "ap-southeast-2"])
        self.assertEqual(exports["GITHUB_TOKEN"], "prefix-secret")
        self.assertEqual(exports["AWS_REGION"], "ap-southeast-2")
        self.assertEqual(exports["AWS_DEFAULT_REGION"], "us-west-1")
        self.assertNotIn("JW_ROLE_ARN", exports)

    def test_region_and_prefix_overrides_are_local(self):
        result, calls, exports = self.run_plugin({"ECR_REGION": "eu-west-1", "SSM_REGION": "us-east-2", "SSM_PREFIX": "/shared/project"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(next(c[3:] for c in calls if c[0] == "ecr"), ["eu-west-1", "eu-west-1"])
        self.assertEqual(calls[-1][3:], ["us-east-2", "us-east-2"])
        self.assertIn("/shared/project/", calls[-3][2])
        self.assertEqual(exports["AWS_REGION"], "ap-southeast-2")
        self.assertEqual(exports["AWS_DEFAULT_REGION"], "us-west-1")

    def test_account_override_precedence_and_same_ecr_role(self):
        for config, extra, account in [({}, {"AWS_ACCOUNT_ID": "111111111111"}, "111111111111"),
                                        ({"ACCOUNT_ID": "222222222222"}, {"AWS_ACCOUNT_ID": "111111111111"}, "222222222222")]:
            config.update({"ECR_ENABLED": "false", "SSM_ENABLED": "false"})
            result, calls, _ = self.run_plugin(config, extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([c[0] for c in calls], ["buildkite-agent", f"role:arn:aws:iam::{account}:role/pipeline-buildkite-example"])
        result, calls, _ = self.run_plugin({"ROLE_ARN": ROLE, "ECR_ROLE_ARN": ROLE})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(c[0].startswith("role:") for c in calls), 1)

    def test_missing_account_identity_and_missing_slugs(self):
        result, _, _ = self.run_plugin(extra={"FAIL": "identity"})
        self.assertEqual(result.returncode, 42)
        self.assertIn("Could not determine the conventional IAM role", result.stderr)
        self.assertIn("verbatim upstream detail", result.stderr)
        result, calls, _ = self.run_plugin(extra={"BUILDKITE_PIPELINE_SLUG": None})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pipeline slug is missing", result.stderr)
        self.assertEqual(calls, [])

    def test_prefix_pagination_empty_pages_and_value_preservation(self):
        pages = [[['api-key', SECRET]], [], [['another_value', 'different']]]
        result, calls, exports = self.run_plugin(extra={"PAGES": json.dumps(pages)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(c[0] == "ssm-path" for c in calls), 3)
        self.assertEqual(exports["API_KEY"], SECRET)
        self.assertEqual(exports["ANOTHER_VALUE"], "different")

    def test_explicit_parameters_union_with_prefix_and_win_collisions(self):
        config = {"SSM_PARAMETERS_GITHUB_TOKEN": "/app/token", "SSM_PARAMETERS_EXTRA": "/app/extra"}
        pages = [[['github_token', 'discovered-token']], [['keep-me', 'kept-value']]]
        result, calls, exports = self.run_plugin(config, {"PAGES": json.dumps(pages)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(exports["GITHUB_TOKEN"], SECRET)
        self.assertEqual(exports["KEEP_ME"], "kept-value")
        self.assertEqual(exports["EXTRA"], SECRET + "/app/extra")
        self.assertEqual([c[0] for c in calls if c[0].startswith('ssm')], ["ssm-path", "ssm-path", "ssm-check", "ssm"])
        result, _, exports = self.run_plugin(config, {"PAGES": '[[]]'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(exports["GITHUB_TOKEN"], SECRET)
        # A discovered value must never hide a missing required explicit value.
        result, _, exports = self.run_plugin(config, {"MISSING": "/app/token"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InvalidParameters", result.stderr)
        self.assertEqual(exports, {})
        result, _, exports = self.run_plugin(config, {"FAIL": "ssm-path"})
        self.assertEqual(result.returncode, 42)
        self.assertIn("verbatim upstream detail", result.stderr)
        self.assertEqual(exports, {})

    def test_explicit_only_never_reads_prefix_or_requires_pipeline_slugs(self):
        config = {"ASSUME_ROLE": "false", "ECR_ENABLED": "false",
                  "SSM_INCLUDE_DEFAULT_PREFIX": "false", "SSM_PREFIX": "/ignored/",
                  "SSM_PARAMETERS_TOKEN": "/app/token"}
        result, calls, exports = self.run_plugin(config, {"BUILDKITE_PIPELINE_SLUG": None, "FAIL": "ssm-path"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["ssm-check", "ssm"])
        self.assertEqual(exports["TOKEN"], SECRET)
        self.assertNotIn("GITHUB_TOKEN", exports)
        del config["SSM_PREFIX"]
        del config["SSM_PARAMETERS_TOKEN"]
        result, calls, _ = self.run_plugin(config, {"BUILDKITE_PIPELINE_SLUG": None})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no parameters were specified", result.stderr)
        self.assertEqual(calls, [])

    def test_prefix_errors_fail_closed(self):
        for pages, message in [([[]], "No SSM parameters found"),
                               ([[['api-key', 'one']], [['API_KEY', 'two']]], "Multiple SSM parameters"),
                               ([[['path', 'unsafe']]], "cannot be overwritten"),
                               ([[['nested/key', 'value']]], "explicit mapping")]:
            with self.subTest(message=message):
                result, _, exports = self.run_plugin(extra={"PAGES": json.dumps(pages)})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(exports, {})

    def test_default_region_and_profile_region_fallback(self):
        for extra, region in [({"AWS_REGION": None}, "us-west-1"),
                              ({"AWS_REGION": None, "AWS_DEFAULT_REGION": None, "PROFILE_REGION": "eu-central-1"}, "eu-central-1")]:
            result, calls, _ = self.run_plugin(extra=extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"123456789012.dkr.ecr.{region}.amazonaws.com", next(c[2] for c in calls if c[0] == "docker"))

    def test_exchange_is_opt_in_uses_workload_role_and_overrides_ssm_tokens(self):
        config = {"GITHUB_CHANGES_ENABLED": "true", "ECR_ROLE_ARN": ECR_ROLE,
                  "GITHUB_ORGANIZATION": "buildkite-plugins"}
        result, calls, exports = self.run_plugin(config, {"EXPECT_GITHUB_ORG": "buildkite-plugins"}, trace=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls[-3:]], ["ssm", "exchange-oidc", "exchange"])
        self.assertEqual(calls[-1][1], "role:" + ROLE)
        self.assertEqual(exports["GH_TOKEN"], "ghs_exchange_secret")
        self.assertEqual(exports["GITHUB_TOKEN"], "ghs_exchange_secret")
        self.assertEqual(exports["AWS_REGION"], "ap-southeast-2")
        self.assertEqual(exports["AWS_DEFAULT_REGION"], "us-west-1")
        self.assertNotIn("exchange-oidc-secret", str(calls))
        for secret in ["ghs_exchange_secret", "exchange-oidc-secret"]:
            self.assertNotIn(secret, result.stderr)
            self.assertNotIn(secret, '\n'.join(line for line in result.stdout.splitlines() if not line.startswith('RESULT=')))
        result, calls, exports = self.run_plugin({"GITHUB_CHANGES_ENABLED": "false"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0].startswith("exchange") for c in calls))
        self.assertNotIn("GH_TOKEN", exports)

    def test_exchange_transport_failures_keep_original_error_and_status(self):
        for event, hint in [("exchange-oidc", "Could not request a Buildkite OIDC token"),
                            ("exchange", "enable_exchange = true")]:
            with self.subTest(event=event):
                result, calls, exports = self.run_plugin({"GITHUB_CHANGES_ENABLED": "true"}, {"FAIL": event})
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(calls[-1][0], event)
                self.assertIn("An error occurred (AccessDenied): verbatim upstream detail", result.stderr)
                self.assertIn(hint, result.stderr)
                self.assertEqual(exports, {})

    def test_exchange_service_errors_are_actionable_and_preserve_message(self):
        for code, hint in [("constraint_mismatch", "immutable Buildkite organization/pipeline IDs"),
                           ("token_validation_failed", "agent clock"),
                           ("bad_request", "github.organization"),
                           ("upstream_failure", "App private key in SSM")]:
            with self.subTest(code=code):
                response = {"error": {"code": code, "message": "Original Exchange error: exact detail"}}
                result, _, exports = self.run_plugin({"GITHUB_CHANGES_ENABLED": "true"}, {"EXCHANGE_RESPONSE": json.dumps(response)})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Original Exchange error: exact detail", result.stderr)
                self.assertIn(hint, result.stderr)
                self.assertEqual(exports, {})

    def test_exchange_rejects_bad_responses_and_lambda_execution_errors(self):
        cases = [({"EXCHANGE_RESPONSE": 'not-json-with-secret'}, "invalid JSON"),
                 ({"EXCHANGE_RESPONSE": '{}'}, "no usable GitHub token"),
                 ({"EXCHANGE_RESPONSE": '{"token":null}'}, "no usable GitHub token"),
                 ({"EXCHANGE_RESPONSE": '{"token":"before\\u0000after"}'}, "no usable GitHub token"),
                 ({"EMPTY_EXCHANGE_OIDC": "1"}, "empty OIDC token"),
                 ({"LAMBDA_METADATA": '{"StatusCode":202}'}, "synchronous invocation"),
                 ({"LAMBDA_METADATA": '{"StatusCode":200,"FunctionError":"Unhandled"}',
                   "EXCHANGE_RESPONSE": '{"errorMessage":"Original Lambda execution error"}'}, "Original Lambda execution error")]
        for extra, hint in cases:
            with self.subTest(hint=hint):
                result, _, exports = self.run_plugin({"GITHUB_CHANGES_ENABLED": "true"}, extra)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(hint, result.stderr)
                self.assertNotIn("not-json-with-secret", result.stderr)
                self.assertEqual(exports, {})

    def test_exchange_can_use_existing_credentials_without_ecr_or_ssm(self):
        config = {"ASSUME_ROLE": "false", "ECR_ENABLED": "false", "SSM_ENABLED": "false", "GITHUB_CHANGES_ENABLED": "true"}
        result, calls, exports = self.run_plugin(config, {"AWS_ACCESS_KEY_ID": "ambient"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c[0] for c in calls], ["exchange-oidc", "exchange"])
        self.assertEqual(calls[-1][1], "ambient")
        self.assertEqual(exports["GH_TOKEN"], "ghs_exchange_secret")


if __name__ == "__main__":
    unittest.main()
