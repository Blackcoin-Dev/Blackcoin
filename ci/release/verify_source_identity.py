#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Fail closed unless release history and tag metadata use the team identity."""

import argparse
import base64
import binascii
import hashlib
from pathlib import Path
import re
import subprocess
import sys


EXPECTED_REPOSITORY = "Blackcoin-Dev/Blackcoin"
EXPECTED_ACTOR = "Blackcoin-Dev"
EXPECTED_NAME = "Blackcoin-Dev"
EXPECTED_EMAIL = "298119138+Blackcoin-Dev@users.noreply.github.com"
EXPECTED_SSH_FINGERPRINT = "SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70"
PINNED_ALLOWED_SIGNERS = Path(__file__).with_name(
    "blackcoin-dev-release-signing.allowed_signers"
)
TRUSTED_V30_1_0 = "f647dc75c9479c03e81414f145a8d233b60959c7"
PINNED_IDENTITY_EXCEPTIONS = {
    # Historical main-branch commit made by the same GitHub team account before
    # its numeric noreply address was configured. Keep this exception scoped to
    # the immutable commit; do not accept the legacy address generally.
    "4f87d05a741013d1e55fd9caa1c2a1cc4a6e570d": (
        ("Blackcoin-Dev", "Blackcoin-Dev@users.noreply.github.com"),
        ("Blackcoin-Dev", "Blackcoin-Dev@users.noreply.github.com"),
    ),
    # GitHub creates verified merge commits with the initiating account as the
    # author and its own signing identity as the committer. These exact objects
    # are the reviewed release-line merges; accepting the identities generally
    # would let an unrelated GitHub merge satisfy the release-history policy.
    "957b41d22c8d96131a0ec87fff1e2f4c20a5caa2": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    "f06033966ccc1ad8ba2b3329f3af69cd9c99acb9": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    "39ac8f41b0904a6c9db37cde6a2a9670bb11f6a5": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    "ac4f2e1718023c82ea2cd087f4a355609453f09d": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    "8e0db55a05ed03fba80bbd2e7ddfebef581043ae": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    # Exact GitHub-verified merge of PR #45. This merge introduced the
    # preceding pinned identity exceptions and is itself on the production
    # release ancestry. Pin the object; do not trust GitHub merge identities
    # as a class.
    "19baffef25af36e177db2975780e0641b59753aa": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
    # Exact GitHub-verified PR #49 merge by Blackcoin-Dev. This immutable
    # object also pins the reviewed parents:
    # 19baffef25af36e177db2975780e0641b59753aa
    # 0e62ec0af3daefba30f87382d9b3cc8b00224e62
    "e85668ed26ef75d92e234488cbd85e146f6ffd5a": (
        (EXPECTED_NAME, EXPECTED_EMAIL),
        ("GitHub", "noreply@github.com"),
    ),
}
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ATTRIBUTION_TRAILER_RE = re.compile(r"^(?:co-authored-by|co-developed-by):", re.IGNORECASE)
TAG_SIGNATURE_MARKERS = (
    "-----BEGIN PGP SIGNATURE-----",
    "-----BEGIN SSH SIGNATURE-----",
    "-----BEGIN SIGNED MESSAGE-----",
)


def git(*args):
    return subprocess.run(
        ["git", *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()


def resolved_commit(value):
    commit = git("rev-parse", f"{value}^{{commit}}")
    if not FULL_SHA_RE.fullmatch(commit):
        raise RuntimeError(f"{value} did not resolve to a full commit identifier")
    return commit


def verify_commit(commit):
    fields = git("show", "-s", "--format=%an%x00%ae%x00%cn%x00%ce%x00%B", commit).split("\0", 4)
    if len(fields) != 5:
        raise RuntimeError(f"cannot parse identity metadata for {commit}")
    author_name, author_email, committer_name, committer_email, message = fields
    expected = (EXPECTED_NAME, EXPECTED_EMAIL)
    pinned_expected = PINNED_IDENTITY_EXCEPTIONS.get(commit)
    expected_author, expected_committer = pinned_expected or (expected, expected)
    author = (author_name, author_email)
    committer = (committer_name, committer_email)
    if author != expected_author:
        raise RuntimeError(
            f"{commit} author is {author_name} <{author_email}>; expected the release team identity"
        )
    if committer != expected_committer:
        raise RuntimeError(
            f"{commit} committer is {committer_name} <{committer_email}>; expected the release team identity"
        )
    for line in message.splitlines():
        if ATTRIBUTION_TRAILER_RE.match(line.strip()):
            raise RuntimeError(f"{commit} contains an additional contributor-attribution trailer")


def ssh_public_key_fingerprint(encoded_key):
    try:
        key_blob = base64.b64decode(encoded_key, validate=True)
    except (binascii.Error, ValueError) as error:
        raise RuntimeError("the pinned SSH public key is not valid base64") from error

    def read_field(offset):
        if offset + 4 > len(key_blob):
            raise RuntimeError("the pinned SSH public key is truncated")
        size = int.from_bytes(key_blob[offset:offset + 4], "big")
        start = offset + 4
        end = start + size
        if end > len(key_blob):
            raise RuntimeError("the pinned SSH public key is truncated")
        return key_blob[start:end], end

    key_type, offset = read_field(0)
    key_material, offset = read_field(offset)
    if key_type != b"ssh-ed25519" or len(key_material) != 32 or offset != len(key_blob):
        raise RuntimeError("the pinned SSH public key is not an Ed25519 key")
    digest = hashlib.sha256(key_blob).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


def validate_allowed_signers(path=None, expected_fingerprint=None):
    path = Path(path) if path is not None else PINNED_ALLOWED_SIGNERS
    if expected_fingerprint is None:
        expected_fingerprint = EXPECTED_SSH_FINGERPRINT
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("the pinned SSH allowed-signers file is missing or unsafe")
    lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(lines) != 1:
        raise RuntimeError("the SSH allowed-signers file must contain exactly one signer")
    fields = lines[0].split()
    if len(fields) != 3:
        raise RuntimeError("the SSH allowed-signers entry must be canonical")
    principal, key_type, encoded_key = fields
    if principal != EXPECTED_EMAIL:
        raise RuntimeError("the SSH allowed-signers principal is not Blackcoin-Dev")
    if key_type != "ssh-ed25519":
        raise RuntimeError("the SSH allowed-signers key is not Ed25519")
    fingerprint = ssh_public_key_fingerprint(encoded_key)
    if fingerprint != expected_fingerprint:
        raise RuntimeError("the SSH allowed-signers key fingerprint is not trusted")
    return path.resolve()


def verify_ssh_signature(
    object_name,
    object_kind,
    expected_fingerprint,
    allowed_signers_file=None,
):
    if object_kind not in ("commit", "tag"):
        raise RuntimeError(f"unsupported signed object kind: {object_kind}")
    allowed_signers = validate_allowed_signers(
        allowed_signers_file,
        expected_fingerprint,
    )
    command = [
        "git",
        "-c",
        "gpg.format=ssh",
        "-c",
        f"gpg.ssh.allowedSignersFile={allowed_signers}",
        f"verify-{object_kind}",
        "--raw",
        "--",
        object_name,
    ]
    result = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    expected_status = (
        f'Good "git" signature for {EXPECTED_EMAIL} with ED25519 key '
        f"{expected_fingerprint}"
    )
    if result.returncode != 0 or expected_status not in result.stdout.splitlines():
        raise RuntimeError(
            f"{object_name} does not have a valid signature from the pinned "
            "Blackcoin-Dev SSH release key"
        )


def verify_unsigned_object(object_name, object_kind):
    content = git("cat-file", "-p", object_name)
    if object_kind == "commit":
        headers = content.split("\n\n", 1)[0]
        if re.search(r"^gpgsig(?:-sha256)? ", headers, re.MULTILINE):
            raise RuntimeError(f"{object_name} has an embedded commit signature")
        return
    if object_kind != "tag":
        raise RuntimeError(f"unsupported object kind: {object_kind}")
    if any(marker in content for marker in TAG_SIGNATURE_MARKERS):
        raise RuntimeError(f"{object_name} has an embedded tag signature")


def verify_tag(tag, head, signing_fingerprint=None):
    ref = f"refs/tags/{tag}"
    if git("cat-file", "-t", ref) != "tag":
        raise RuntimeError(f"{tag} must be an annotated tag")
    if resolved_commit(ref) != head:
        raise RuntimeError(f"{tag} does not resolve to the gated commit {head}")
    tagger = git("for-each-ref", "--format=%(taggername)%00%(taggeremail)", ref).split("\0", 1)
    if len(tagger) != 2:
        raise RuntimeError(f"cannot parse tagger identity for {tag}")
    tagger_name, tagger_email = tagger
    tagger_email = tagger_email.removeprefix("<").removesuffix(">")
    if (tagger_name, tagger_email) != (EXPECTED_NAME, EXPECTED_EMAIL):
        raise RuntimeError(f"{tag} was not created with the release team identity")
    if signing_fingerprint:
        verify_ssh_signature(ref, "tag", signing_fingerprint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=TRUSTED_V30_1_0)
    parser.add_argument("--head", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--actor")
    parser.add_argument("--require-actor", action="store_true")
    parser.add_argument("--tag")
    parser.add_argument("--require-signatures", action="store_true")
    parser.add_argument("--require-unsigned-objects", action="store_true")
    parser.add_argument("--signing-fingerprint")
    args = parser.parse_args()

    if args.repository != EXPECTED_REPOSITORY:
        raise RuntimeError(f"release repository must be {EXPECTED_REPOSITORY}")
    if args.require_actor and args.actor != EXPECTED_ACTOR:
        raise RuntimeError("release workflow must be initiated by the release team account")

    signing_fingerprint = (args.signing_fingerprint or "").strip()
    if args.require_signatures and args.require_unsigned_objects:
        raise RuntimeError("signed and explicitly unsigned release policies are mutually exclusive")
    if args.require_signatures and signing_fingerprint != EXPECTED_SSH_FINGERPRINT:
        raise RuntimeError("the exact Blackcoin-Dev SSH release-signing fingerprint is required")

    base = resolved_commit(args.base)
    head = resolved_commit(args.head)
    subprocess.run(["git", "merge-base", "--is-ancestor", base, head], check=True)
    commits = git("rev-list", "--reverse", f"{base}..{head}").splitlines()
    if not commits:
        raise RuntimeError("release range contains no commits after v30.1.0")
    for commit in commits:
        verify_commit(commit)
    if args.require_signatures:
        verify_ssh_signature(head, "commit", signing_fingerprint)
    if args.require_unsigned_objects:
        verify_unsigned_object(head, "commit")
    if args.tag:
        verify_tag(args.tag, head, signing_fingerprint if args.require_signatures else None)
        if args.require_unsigned_objects:
            verify_unsigned_object(f"refs/tags/{args.tag}", "tag")

    print(f"Verified {len(commits)} release commit(s) through {head}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"identity verification failed: {error}", file=sys.stderr)
        sys.exit(1)
