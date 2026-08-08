#!/usr/bin/env bash
export LC_ALL=C

# Static and synthetic-fixture validation only. This test never invokes Docker,
# a registry, GitHub mutation, or the workflow-dispatch path.

set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

TEST_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
PACKAGE_ROOT=$(CDPATH='' cd -P -- "$TEST_ROOT/.." && pwd -P) || exit 1
REPO_ROOT=$(CDPATH='' cd -P -- "$PACKAGE_ROOT/../../.." && pwd -P) || exit 1
readonly TEST_ROOT PACKAGE_ROOT REPO_ROOT
readonly WORKFLOW="$REPO_ROOT/.github/workflows/v30.1.4-hotfix-candidate-linux.yml"
readonly METADATA="$REPO_ROOT/ci/release/generate_hotfix_candidate_metadata.py"
readonly METADATA_TEST="$REPO_ROOT/ci/release/test_hotfix_candidate_metadata.py"
readonly POLICY="$PACKAGE_ROOT/policy.json"
readonly BUILD="$PACKAGE_ROOT/build_candidate_bundle.sh"
readonly VERIFY="$PACKAGE_ROOT/verify_candidate_bundle.sh"
readonly SUMS="$PACKAGE_ROOT/SHA256SUMS"

fail()
{
    printf 'candidate package test failed: %s\n' "$*" >&2
    exit 1
}

[[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
   -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] ||
    fail 'candidate package contains a symlink or nonregular entry'
actual_directories=$(cd "$PACKAGE_ROOT" && find . -type d -print | sort)
expected_directories=$(printf '.\n./tests\n' | sort)
[[ "$actual_directories" == "$expected_directories" ]] ||
    fail 'candidate package directory inventory changed'

for path in "$WORKFLOW" "$METADATA" "$METADATA_TEST" "$POLICY" "$BUILD" "$VERIFY" "$SUMS"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "required package path is absent or unsafe: $path"
done

bash -n "$BUILD" "$VERIFY" "$TEST_ROOT/run.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$BUILD" "$VERIFY" "$TEST_ROOT/run.sh"
fi
python3 "$METADATA_TEST"

python3 - "$WORKFLOW" <<'PY'
import re
import sys

workflow = open(sys.argv[1], encoding="utf-8").read()


def job_body(text, job):
    match = re.search(
        rf"^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    assert match is not None, f"missing workflow job: {job}"
    return match.group("body")


def validate_attempt_contract(text):
    for job in ("build-linux", "assemble-candidate"):
        body = job_body(text, job)
        assert body.count('test "$GITHUB_ACTOR" = Blackcoin-Dev') == 1
        assert body.count('test "$GITHUB_TRIGGERING_ACTOR" = Blackcoin-Dev') == 1

    required_names = (
        "hotfix-candidate-authorization-${{ inputs.source_sha }}-attempt-${{ github.run_attempt }}",
        "hotfix-candidate-raw-${{ matrix.builder }}-${{ needs.authorize-source.outputs.source_sha }}-attempt-${{ github.run_attempt }}",
        "hotfix-candidate-raw-primary-${{ needs.authorize-source.outputs.source_sha }}-attempt-${{ github.run_attempt }}",
        "hotfix-candidate-raw-verifier-${{ needs.authorize-source.outputs.source_sha }}-attempt-${{ github.run_attempt }}",
        "hotfix-candidate-authorization-${{ needs.authorize-source.outputs.source_sha }}-attempt-${{ github.run_attempt }}",
        "hotfix-candidate-30.1.4-linux-x86_64-${{ needs.authorize-source.outputs.source_sha }}-attempt-${{ github.run_attempt }}",
    )
    for name in required_names:
        assert text.count(f"name: {name}") == 1, name
    assert text.count("name: hotfix-candidate-") == len(required_names)


validate_attempt_contract(workflow)
for job, actor_line in (
    ("build-linux", 'test "$GITHUB_ACTOR" = Blackcoin-Dev'),
    ("build-linux", 'test "$GITHUB_TRIGGERING_ACTOR" = Blackcoin-Dev'),
    ("assemble-candidate", 'test "$GITHUB_ACTOR" = Blackcoin-Dev'),
    ("assemble-candidate", 'test "$GITHUB_TRIGGERING_ACTOR" = Blackcoin-Dev'),
):
    body = job_body(workflow, job)
    assert actor_line in body
    mutated = workflow.replace(body, body.replace(actor_line, "true # removed actor gate", 1), 1)
    try:
        validate_attempt_contract(mutated)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"static contract accepted missing {job} actor gate")

mutated = workflow.replace("-attempt-${{ github.run_attempt }}", "", 1)
try:
    validate_attempt_contract(mutated)
except AssertionError:
    pass
else:
    raise AssertionError("static contract accepted an artifact without run-attempt scoping")
PY

python3 - <<'PY'
import hashlib
from pathlib import Path
import subprocess
import tempfile


def tracked_depends_digest(repository):
    payload = subprocess.check_output(
        ["git", "-C", str(repository), "ls-files", "-z", "--", "depends"]
    )
    paths = payload.rstrip(b"\0").split(b"\0") if payload else []
    if not paths:
        raise RuntimeError("empty tracked depends inventory")
    if paths != sorted(paths):
        raise RuntimeError("tracked depends inventory is not sorted")
    tree = hashlib.sha256()
    for encoded_path in paths:
        path = encoded_path.decode("utf-8")
        data = (repository / path).read_bytes()
        tree.update(encoded_path)
        tree.update(b"\0")
        tree.update(hashlib.sha256(data).hexdigest().encode("ascii"))
        tree.update(b"\0")
    return tree.hexdigest()


with tempfile.TemporaryDirectory() as temporary:
    repository = Path(temporary)
    subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
    (repository / "depends").mkdir()
    tracked = repository / "depends" / "input.mk"
    tracked.write_text("value=one\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repository), "add", "depends/input.mk"], check=True)
    original = tracked_depends_digest(repository)
    (repository / "depends" / "untracked-output").write_text("ignored\n", encoding="utf-8")
    assert tracked_depends_digest(repository) == original
    tracked.write_text("value=two\n", encoding="utf-8")
    assert tracked_depends_digest(repository) != original
    tracked.write_text("value=one\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(repository), "mv", "depends/input.mk", "depends/renamed.mk"],
        check=True,
    )
    assert tracked_depends_digest(repository) != original

with tempfile.TemporaryDirectory() as temporary:
    repository = Path(temporary)
    subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
    try:
        tracked_depends_digest(repository)
    except RuntimeError as error:
        assert str(error) == "empty tracked depends inventory"
    else:
        raise AssertionError("empty tracked depends inventory was accepted")
PY

python3 - "$POLICY" <<'PY'
import json
import sys

policy = json.load(open(sys.argv[1], encoding="utf-8"))
assert policy["schema"] == 1
assert policy["classification"] == "POST_RELEASE_HOTFIX_CANDIDATE_CANARY_ONLY"
assert policy["source"]["commit"] == "8a3a5aa1c01caf57acc694b836398c5acba969d0"
assert policy["source"]["immutable_release_ancestor"] == "13262151077cce3f72d07d17dc7725b2b6a8e1ab"
assert policy["source"]["signing_fingerprint"] == "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
assert policy["core_ci"] == {
    "event": "pull_request",
    "pull_request_number": 49,
    "head_sha": "8a3a5aa1c01caf57acc694b836398c5acba969d0",
    "base_sha": "19baffef25af36e177db2975780e0641b59753aa",
    "repository": "Blackcoin-Dev/Blackcoin",
    "head_repository": "Blackcoin-Dev/Blackcoin",
    "workflow_path": ".github/workflows/pr-gate.yml",
    "workflow_name": "pull-request safety gate",
    "workflow_blob_sha256": "24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869",
}
assert policy["base_image"]["manifest_digest"] == "sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2"
assert policy["base_image"]["config_digest"] == "sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909"
assert policy["artifacts"]["github_artifact_template"] == (
    "hotfix-candidate-30.1.4-linux-x86_64-{source40}-attempt-{attempt}"
)
assert policy["binaries"] == [
    "blackcoin-cli", "blackcoin-qt", "blackcoin-tx", "blackcoin-util",
    "blackcoin-wallet", "blackcoind",
]
PY

grep -Fq 'permissions:' "$WORKFLOW"
grep -Fq '  contents: read' "$WORKFLOW"
grep -Fq '  actions: read' "$WORKFLOW"
grep -Fq "if: \${{ github.event_name == 'workflow_dispatch' }}" "$WORKFLOW"
test "$(grep -Fc "test \"\$GITHUB_ACTOR\" = Blackcoin-Dev" "$WORKFLOW")" = 3
test "$(grep -Fc "test \"\$GITHUB_TRIGGERING_ACTOR\" = Blackcoin-Dev" "$WORKFLOW")" = 3
grep -Fq '.path == ".github/workflows/pr-gate.yml"' "$WORKFLOW"
grep -Fq ".event == \$event" "$WORKFLOW"
grep -Fq ".pull_requests[0].number == \$pr" "$WORKFLOW"
grep -Fq ".pull_requests[0].head.sha == \$source" "$WORKFLOW"
grep -Fq ".pull_requests[0].base.sha == \$base" "$WORKFLOW"
grep -Fq ".head_repository.full_name == \$repository" "$WORKFLOW"
grep -Fq 'EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256: 24c14f2fe4bd7b25de38e71a80bf05efcec00d2b3009c3efd4ad20b90bbda869' "$WORKFLOW"
grep -Fq '.status == "completed" and .conclusion == "success"' "$WORKFLOW"
grep -Fq ".head_sha == \$source" "$WORKFLOW"
grep -Fq -- '--require-signatures' "$WORKFLOW"
grep -Fq -- "--signing-fingerprint \"\$EXPECTED_FINGERPRINT\"" "$WORKFLOW"
test "$(grep -Fc -- "--base \"\$EXPECTED_IDENTITY_ANCESTOR\"" "$WORKFLOW")" = 2
grep -Fq "TOOLING_SHA: \${{ github.workflow_sha }}" "$WORKFLOW"
grep -Fq "test \"\$TOOLING_SHA\" = \"\$EVENT_SHA\"" "$WORKFLOW"
grep -Fq "\"\$GITHUB_WORKSPACE/\$POLICY\"" "$WORKFLOW"
grep -Fq "\"\$GITHUB_WORKSPACE/primary\" \"\$GITHUB_WORKSPACE/verifier\"" "$WORKFLOW"
grep -Fq "\"\$GITHUB_WORKSPACE/candidate-bundle\"" "$WORKFLOW"
grep -Fq "hotfix-candidate-30.1.4-linux-x86_64-\${{ needs.authorize-source.outputs.source_sha }}-attempt-\${{ github.run_attempt }}" "$WORKFLOW"
grep -Fq "hotfix-candidate-authorization-\${{ inputs.source_sha }}-attempt-\${{ github.run_attempt }}" "$WORKFLOW"
grep -Fq "hotfix-candidate-raw-\${{ matrix.builder }}-\${{ needs.authorize-source.outputs.source_sha }}-attempt-\${{ github.run_attempt }}" "$WORKFLOW"
grep -Fq 'git ls-files -z -- depends | LC_ALL=C sort -z' "$WORKFLOW"
grep -Fq 'depends_tracked_source_tree_sha256=' "$WORKFLOW"
grep -Fq "((\${#depends_tracked_files[@]} > 0))" "$WORKFLOW"
grep -Fq "printf 'workflow_run_id=%s\\n' \"\$WORKFLOW_RUN_ID\"" "$WORKFLOW"
grep -Fq "printf 'workflow_run_attempt=%s\\n' \"\$WORKFLOW_RUN_ATTEMPT\"" "$WORKFLOW"
if grep -Eq 'pull_request_target:|repository_dispatch:|packages:[[:space:]]*write|contents:[[:space:]]*write|id-token:[[:space:]]*write' "$WORKFLOW"; then
    fail 'workflow contains a forbidden event or write permission'
fi
if grep -Eq 'docker[[:space:]]+push|gh[[:space:]]+release|create-release|git[[:space:]]+tag|git[[:space:]]+push' \
    "$WORKFLOW" "$BUILD" "$VERIFY"; then
    fail 'candidate path contains a publication or tag command'
fi

grep -Fq 'docker build --pull=false --network=none --no-cache' "$BUILD"
grep -Fq "skopeo copy --format oci \"docker-daemon:\$candidate_ref\"" "$BUILD"
grep -Fq "[[ \"\$oci_config\" == \"\$candidate_config\" ]]" "$BUILD"
grep -Fq "skopeo copy \"oci-archive:\$OUTPUT/\$oci_name\" \"docker-daemon:\$roundtrip_ref\"" "$BUILD"
grep -Fq -- '--network none --read-only --user blackcoin --cap-drop ALL' "$BUILD"
grep -Fq 'POST_RELEASE_HOTFIX_CANDIDATE_CANARY_ONLY' "$METADATA"
grep -Fq '"tag": None' "$METADATA"
grep -Fq '"published": False' "$METADATA"
grep -Fq '"registry_pushed": False' "$METADATA"
grep -Fq '"tooling_commit": adapter_sha' "$METADATA"
grep -Fq '"workflow_definition_commit": adapter_sha' "$METADATA"
grep -Fq '"org.blackcoin.deployment.scope": "canary-only"' "$METADATA"
grep -Fq '"oci_roundtrip_verified"' "$METADATA"
grep -Fq 'parse_exact_key_value_evidence' "$METADATA"
grep -Fq 'object_pairs_hook=reject_duplicate_json_keys' "$METADATA"
grep -Fq 'require_canonical=True' "$METADATA"

if command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$WORKFLOW"
fi

cmp -s \
    <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); print "./" name
    }' "$SUMS" | sort) || fail 'package checksum manifest does not cover the exact package file set'
if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$PACKAGE_ROOT"
        sha256sum --strict --check SHA256SUMS >/dev/null
    ) || fail 'package checksum verification failed'
elif [[ -x /usr/bin/shasum ]]; then
    (
        cd "$PACKAGE_ROOT"
        /usr/bin/shasum -a 256 --check SHA256SUMS >/dev/null
    ) || fail 'package checksum verification failed'
else
    fail 'no SHA256 verifier is available'
fi

printf 'PASS hotfix-candidate-metadata-fixtures\n'
printf 'PASS hotfix-candidate-workflow-static-contract\n'
printf 'PASS hotfix-candidate-package-seal\n'
