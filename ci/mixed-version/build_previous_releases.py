#!/usr/bin/env python3
# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
"""Build exact, provenance-checked binaries for mixed-version tests."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import urllib.request


BINARIES = ("blackcoind", "blackcoin-cli")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMANTIC_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*$")
CHECKPOINT_NAME = ".mixed-version-build-checkpoint.json"
BUILD_LOCK_NAME = ".mixed-version-build.lock"
BUILD_PHASES = ("clone", "identity", "depends", "autogen", "configure", "compile", "install")
SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+\-]*$")
PROVENANCE_CONTRACT = "blackcoin-mixed-version-binaries-v2"
COMPLETE_SELECTION_CONTRACT = "complete-manifest-v1"
SUBSET_SELECTION_CONTRACT = "explicit-version-subset-v1"
SELECTION_CONTRACTS = {
    COMPLETE_SELECTION_CONTRACT,
    SUBSET_SELECTION_CONTRACT,
}
VERSION_BANNER_CONTRACT = "version-banner-v1"
CLEAN_SOURCE_COMMIT_CONTRACT = "version-banner-clean-source-commit-v1"
IDENTITY_CONTRACTS = {
    VERSION_BANNER_CONTRACT,
    CLEAN_SOURCE_COMMIT_CONTRACT,
}
VERSION_BANNER_RE = re.compile(
    r"^(?P<product>Blackcoin(?: More)?) "
    r"(?P<rpc_client>RPC client )?version "
    r"v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)$"
)


def run(command, *, cwd=None, capture=False, env=None, timeout=None):
    print("+", " ".join(str(part) for part in command), flush=True)
    completed = subprocess.run(
        [str(part) for part in command],
        cwd=cwd,
        check=True,
        env=env,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        timeout=timeout,
    )
    return completed.stdout if capture else None


def verified_reported_version(
    binary,
    expected_version,
    *,
    expected_product,
    scratch_root,
    identity_contract=VERSION_BANNER_CONTRACT,
    expected_source_commit=None,
):
    """Read --version without exposing a historical client to user state.

    Some released daemons perform legacy-datadir migration before handling
    --version unless an explicit datadir is supplied. A clean HOME and an
    existing isolated datadir keep provenance checks read-only and prevent
    migration progress from being mistaken for version output.
    """
    with tempfile.TemporaryDirectory(
        prefix="version-check-", dir=scratch_root
    ) as temporary:
        root = Path(temporary)
        home = root / "home"
        datadir = root / "datadir"
        home.mkdir()
        datadir.mkdir()
        isolated_env = os.environ.copy()
        isolated_env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
        })
        output = run(
            [binary, f"-datadir={datadir}", "--version"],
            capture=True,
            env=isolated_env,
            timeout=30,
        )
    lines = output.splitlines()
    if not lines:
        raise RuntimeError(f"{binary} returned empty version output")
    reported = lines[0].strip()
    normalized_expected = expected_version.removeprefix("v")
    binary_role = Path(binary).name
    match = VERSION_BANNER_RE.fullmatch(reported)
    expected_rpc_client = binary_role == "blackcoin-cli"
    if (
        binary_role not in BINARIES
        or not SEMANTIC_VERSION_RE.fullmatch(normalized_expected)
        or match is None
        or match.group("product") != expected_product
        or bool(match.group("rpc_client")) != expected_rpc_client
        or match.group("version") != normalized_expected
    ):
        raise RuntimeError(f"{binary} reports unexpected version: {reported}")
    if identity_contract not in IDENTITY_CONTRACTS:
        raise RuntimeError(f"unsupported binary identity contract: {identity_contract}")
    if identity_contract == CLEAN_SOURCE_COMMIT_CONTRACT:
        if expected_source_commit is None or not SHA1_RE.fullmatch(expected_source_commit):
            raise RuntimeError("clean-source identity requires an exact source commit")
        expected_source_line = f"Source commit: {expected_source_commit}"
        source_lines = [line.strip() for line in lines if line.strip().startswith("Source commit:")]
        if len(lines) < 2 or lines[1].strip() != expected_source_line or source_lines != [expected_source_line]:
            observed = source_lines or ["<missing>"]
            raise RuntimeError(
                f"{binary} reports unexpected source identity: {observed}"
            )
    return reported


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path):
    data = json.loads(path.read_text(encoding="utf8"))
    if (
        not isinstance(data, dict)
        or data.get("schema") != 1
        or not isinstance(data.get("sources"), list)
        or not data["sources"]
    ):
        raise ValueError("unsupported or empty mixed-version source manifest")
    required = {
        "version", "product", "install_dir", "repository", "source_ref",
        "ref_object", "commit", "tag_kind", "source_daemon", "source_cli",
        "identity_contract",
    }
    versions = set()
    install_dirs = set()
    for source in data["sources"]:
        if not isinstance(source, dict):
            raise ValueError("mixed-version source entries must be objects")
        missing = required.difference(source)
        if missing:
            raise ValueError(f"{source.get('version', '<unknown>')} missing {sorted(missing)}")
        if any(not isinstance(source[field], str) for field in required):
            raise ValueError(f"{source.get('version', '<unknown>')} contains a non-string field")
        if source["product"] not in ("Blackcoin", "Blackcoin More"):
            raise ValueError(f"{source['version']} contains an unsupported product name")
        if not source["repository"].startswith("https://"):
            raise ValueError(f"{source['version']} contains an unsafe repository URL")
        if not source["source_ref"].startswith(("refs/heads/", "refs/tags/")):
            raise ValueError(f"{source['version']} contains an unsafe source ref")
        if (
            not source["version"].startswith("v")
            or not SEMANTIC_VERSION_RE.fullmatch(source["version"][1:])
        ):
            raise ValueError(f"{source['version']} contains an invalid semantic version")
        if source["tag_kind"] not in (
            "annotated", "lightweight", "untagged-release-branch"
        ):
            raise ValueError(f"{source['version']} contains an unsupported tag kind")
        if source["identity_contract"] not in IDENTITY_CONTRACTS:
            raise ValueError(f"{source['version']} contains an unsupported identity contract")
        if source["version"] in versions:
            raise ValueError(f"duplicate mixed-version source: {source['version']}")
        versions.add(source["version"])
        if not SHA1_RE.fullmatch(source["ref_object"]) or not SHA1_RE.fullmatch(source["commit"]):
            raise ValueError(f"{source['version']} contains a non-commit object identifier")
        install_dir = Path(source["install_dir"])
        if (
            install_dir.is_absolute()
            or not install_dir.parts
            or len(install_dir.parts) != 1
            or any(
                part in ("", ".", "..") or SAFE_COMPONENT_RE.fullmatch(part) is None
                for part in install_dir.parts
            )
        ):
            raise ValueError(f"unsafe install directory for {source['version']}")
        normalized_install_dir = install_dir.as_posix()
        if normalized_install_dir in install_dirs:
            raise ValueError(f"duplicate install directory: {normalized_install_dir}")
        install_dirs.add(normalized_install_dir)
        for binary_key in ("source_daemon", "source_cli"):
            binary_name = Path(source[binary_key])
            if (
                binary_name.is_absolute()
                or len(binary_name.parts) != 1
                or binary_name.name in ("", ".", "..")
                or SAFE_COMPONENT_RE.fullmatch(binary_name.name) is None
            ):
                raise ValueError(f"unsafe {binary_key} for {source['version']}")
        asset = source.get("release_asset")
        if asset is not None:
            if not isinstance(asset, dict):
                raise ValueError(f"{source['version']} release asset must be an object")
            asset_required = {
                "host", "url", "sha256", "daemon_member", "daemon_sha256",
                "cli_member", "cli_sha256",
            }
            missing_asset = asset_required.difference(asset)
            if missing_asset:
                raise ValueError(
                    f"{source['version']} release asset missing {sorted(missing_asset)}"
                )
            if any(not isinstance(asset[field], str) for field in asset_required):
                raise ValueError(f"{source['version']} release asset contains a non-string field")
            if not HOST_RE.fullmatch(asset["host"]) or not asset["url"].startswith("https://"):
                raise ValueError(f"{source['version']} release asset has unsafe origin metadata")
            for digest_key in ("sha256", "daemon_sha256", "cli_sha256"):
                if not SHA256_RE.fullmatch(asset[digest_key]):
                    raise ValueError(
                        f"{source['version']} release asset has invalid {digest_key}"
                    )
            for member_key in ("daemon_member", "cli_member"):
                member = Path(asset[member_key])
                if member.is_absolute() or ".." in member.parts:
                    raise ValueError(
                        f"{source['version']} release asset has unsafe {member_key}"
                    )
    return data


def select_manifest_sources(sources, requested_versions=None):
    """Return one canonical, manifest-ordered source selection.

    ``None`` selects the complete manifest.  An explicit selection is strict:
    every requested version must be named exactly once and must exist in the
    checked-in manifest.  Canonical ordering makes the provenance independent
    of command-line argument order and gives consumers one exact list to
    compare rather than set-like data with duplicate ambiguity.
    """
    if not isinstance(sources, list) or not sources:
        raise ValueError("mixed-version source selection requires a non-empty manifest")
    versions = []
    source_by_version = {}
    for source in sources:
        if not isinstance(source, dict) or not isinstance(source.get("version"), str):
            raise ValueError("mixed-version source selection contains invalid metadata")
        version = source["version"]
        if version in source_by_version:
            raise ValueError(f"duplicate mixed-version source: {version}")
        versions.append(version)
        source_by_version[version] = source

    if requested_versions is None:
        requested = list(versions)
    else:
        if (
            isinstance(requested_versions, (str, bytes))
            or not isinstance(requested_versions, (list, tuple))
            or not requested_versions
            or any(not isinstance(version, str) for version in requested_versions)
        ):
            raise ValueError("explicit mixed-version selection must be a non-empty version list")
        requested = list(requested_versions)
        if len(set(requested)) != len(requested):
            raise ValueError("explicit mixed-version selection contains duplicate versions")
        unknown = sorted(set(requested).difference(source_by_version))
        if unknown:
            raise ValueError(f"unknown mixed-version source selection: {unknown}")
        requested_set = set(requested)
        requested = [version for version in versions if version in requested_set]

    selected = [source_by_version[version] for version in requested]
    contract = (
        COMPLETE_SELECTION_CONTRACT
        if requested == versions
        else SUBSET_SELECTION_CONTRACT
    )
    return contract, requested, selected


def provenance_source_metadata(source):
    """Copy all manifest identity metadata declared by each provenance item."""
    return {
        field: source[field]
        for field in (
            "version", "product", "install_dir", "repository", "source_ref",
            "ref_object", "commit", "tag_kind", "source_daemon", "source_cli",
            "identity_contract",
        )
    }


def remote_objects(source):
    ref = source["source_ref"]
    output = run(
        ["git", "ls-remote", source["repository"], ref, f"{ref}^{{}}"],
        capture=True,
    )
    objects = {}
    for line in output.splitlines():
        object_id, object_ref = line.split(maxsplit=1)
        objects[object_ref] = object_id
    observed = objects.get(ref)
    if source["tag_kind"] == "untagged-release-branch":
        if not ref.startswith("refs/heads/"):
            raise RuntimeError(
                f"{source['version']} untagged release source is not a branch: {ref}"
            )
        if source["ref_object"] != source["commit"]:
            raise RuntimeError(
                f"{source['version']} untagged release branch pin must be an exact commit"
            )
        if observed is None:
            raise RuntimeError(f"{source['version']} provenance changed: {ref} is missing")
        with tempfile.TemporaryDirectory(prefix="mixed-version-ref-") as temporary:
            repository = Path(temporary) / "repository.git"
            run(["git", "init", "--bare", "--quiet", repository])
            run([
                "git", "remote", "add", "origin", source["repository"],
            ], cwd=repository)
            run([
                "git", "fetch", "--quiet", "--no-tags", "--filter=blob:none",
                "origin",
                f"{ref}:refs/remotes/provenance/observed",
            ], cwd=repository)
            fetched = run(
                ["git", "rev-parse", "refs/remotes/provenance/observed"],
                cwd=repository,
                capture=True,
            ).strip()
            if fetched != observed:
                raise RuntimeError(
                    f"{source['version']} {ref} moved during provenance verification: "
                    f"observed {observed}, fetched {fetched}"
                )
            reachable = subprocess.run(
                [
                    "git", "merge-base", "--is-ancestor",
                    source["commit"], observed,
                ],
                cwd=repository,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if reachable.returncode != 0:
                raise RuntimeError(
                    f"{source['version']} provenance changed: pinned commit "
                    f"{source['commit']} is not an ancestor of observed {ref} head {observed}"
                )
        print(
            f"{source['version']} observed untagged release branch {ref} at {observed}; "
            f"pinned build commit remains {source['commit']}",
            flush=True,
        )
        return observed

    if observed != source["ref_object"]:
        raise RuntimeError(
            f"{source['version']} provenance changed: {ref} is "
            f"{observed or '<missing>'}, expected {source['ref_object']}"
        )
    peeled = objects.get(f"{ref}^{{}}", objects[ref])
    if peeled != source["commit"]:
        raise RuntimeError(
            f"{source['version']} resolves to {peeled}, expected {source['commit']}"
        )
    if source["tag_kind"] == "annotated" and f"{ref}^{{}}" not in objects:
        raise RuntimeError(f"{source['version']} is no longer an annotated tag")
    if source["tag_kind"] == "lightweight" and source["ref_object"] != source["commit"]:
        raise RuntimeError(f"{source['version']} lightweight tag does not point to its pinned commit")
    return observed


def source_version(source_dir):
    configure = (source_dir / "configure.ac").read_text(encoding="utf8")
    values = {}
    for component in ("MAJOR", "MINOR", "BUILD"):
        match = re.search(rf"^define\(_CLIENT_VERSION_{component}, ([0-9]+)\)$", configure, re.MULTILINE)
        if match is None:
            raise RuntimeError(f"cannot read {component.lower()} version from {source_dir / 'configure.ac'}")
        values[component] = match.group(1)
    return f"v{values['MAJOR']}.{values['MINOR']}.{values['BUILD']}"


def expected_source_commit(source):
    if source["identity_contract"] == CLEAN_SOURCE_COMMIT_CONTRACT:
        return source["commit"]
    return None


def verified_binary_version(binary, source, *, scratch_root):
    return verified_reported_version(
        binary,
        source["version"],
        expected_product=source["product"],
        scratch_root=scratch_root,
        identity_contract=source["identity_contract"],
        expected_source_commit=expected_source_commit(source),
    )


def cached_provenance_is_valid(
    output_dir,
    manifest_digest,
    sources,
    *,
    required_versions=None,
    host,
    scratch_root,
):
    provenance_path = output_dir / "provenance.json"
    if not provenance_path.is_file():
        return False
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf8"))
    except (OSError, ValueError):
        return False
    if not isinstance(provenance, dict) or provenance_path.is_symlink():
        return False
    if (
        provenance.get("schema") != 1
        or provenance.get("contract") != PROVENANCE_CONTRACT
        or provenance.get("manifest_sha256") != manifest_digest
        or provenance.get("host") != host
    ):
        return False
    try:
        _required_contract, required, _required_sources = select_manifest_sources(
            sources, required_versions
        )
        declared_contract, declared, selected_sources = select_manifest_sources(
            sources, provenance.get("requested_versions")
        )
    except ValueError:
        return False
    if (
        provenance.get("selection_contract") not in SELECTION_CONTRACTS
        or provenance.get("selection_contract") != declared_contract
        or provenance.get("requested_versions") != declared
        or provenance.get("built_versions") != declared
    ):
        return False
    if declared_contract == COMPLETE_SELECTION_CONTRACT:
        if not set(required).issubset(declared):
            return False
    elif declared != required:
        # A subset is an exact-purpose artifact.  Do not silently accept extra
        # historical executables under a looser consumer requirement.
        return False
    provenance_sources = provenance.get("sources")
    if (
        not isinstance(provenance_sources, list)
        or len(provenance_sources) != len(selected_sources)
    ):
        return False
    built = {}
    for expected_version, item in zip(declared, provenance_sources):
        if not isinstance(item, dict) or not isinstance(item.get("version"), str):
            return False
        if item["version"] != expected_version:
            return False
        if item["version"] in built:
            return False
        built[item["version"]] = item
    if len(built) != len(selected_sources):
        return False
    for source in selected_sources:
        item = built.get(source["version"])
        if item is None:
            return False
        for field in (
            "product", "install_dir", "repository", "source_ref", "ref_object",
            "commit", "tag_kind", "source_daemon", "source_cli",
            "identity_contract",
        ):
            if item.get(field) != source[field]:
                return False
        if item.get("host") != host or item.get("identity_verified") is not True:
            return False
        asset = source.get("release_asset")
        expected_origin = (
            "digest-pinned-release-asset"
            if asset is not None and asset.get("host") == host
            else "source-build"
        )
        origin = item.get("origin")
        if origin != expected_origin:
            return False
        if origin == "source-build":
            if item.get("source_checkout_clean") is not True:
                return False
        elif origin == "digest-pinned-release-asset":
            if (
                asset is None
                or asset.get("host") != host
                or item.get("release_asset_url") != asset.get("url")
                or item.get("release_asset_sha256") != asset.get("sha256")
            ):
                return False
        binary_hashes = item.get("binaries")
        reported_versions = item.get("reported_versions")
        if not isinstance(binary_hashes, dict) or not isinstance(reported_versions, dict):
            return False
        if origin == "digest-pinned-release-asset":
            expected_asset_hashes = {
                "blackcoind": asset["daemon_sha256"],
                "blackcoin-cli": asset["cli_sha256"],
            }
            if any(
                binary_hashes.get(binary) != expected_asset_hashes[binary]
                for binary in BINARIES
            ):
                return False
        for binary in BINARIES:
            path = output_dir / source["install_dir"] / "bin" / binary
            try:
                path_is_safe = path.resolve().is_relative_to(output_dir.resolve())
            except OSError:
                return False
            if (
                not path_is_safe
                or path.is_symlink()
                or not path.is_file()
                or not os.access(path, os.X_OK)
            ):
                return False
            try:
                binary_digest = file_sha256(path)
            except OSError:
                return False
            if binary_digest != binary_hashes.get(binary):
                return False
            try:
                reported = verified_binary_version(path, source, scratch_root=scratch_root)
            except (OSError, RuntimeError, subprocess.SubprocessError):
                return False
            if reported != reported_versions.get(binary):
                return False
    return True


def cached_provenance_is_reusable(
    output_dir,
    manifest_digest,
    sources,
    *,
    required_versions=None,
    host,
    scratch_root,
):
    """Validate only cache entries with an independent binary digest root.

    A source-built executable plus adjacent JSON cannot authenticate itself:
    both the reported source line and the self-declared digest are controlled
    by the cached bytes.  Refuse the selected cache before reading or
    executing any cached binary whenever even one manifest entry would have
    to be built from source on this host.  Same-run functional consumers may
    use ``cached_provenance_is_valid`` after this builder has recreated the
    output from the pinned sources.
    """
    try:
        _contract, _requested, selected_sources = select_manifest_sources(
            sources, required_versions
        )
    except ValueError:
        return False
    if any(
        source.get("release_asset") is None
        or source["release_asset"].get("host") != host
        for source in selected_sources
    ):
        return False
    return cached_provenance_is_valid(
        output_dir,
        manifest_digest,
        sources,
        required_versions=required_versions,
        host=host,
        scratch_root=scratch_root,
    )


def clone_exact_source(source, destination):
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f"refusing to clone into existing path: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{destination.name}.clone-", dir=destination.parent
    ) as temporary:
        checkout = Path(temporary) / "checkout"
        run(["git", "init", "--quiet", checkout])
        run(["git", "remote", "add", "origin", source["repository"]], cwd=checkout)
        run(["git", "fetch", "--quiet", "--depth=1", "origin", source["commit"]], cwd=checkout)
        run(["git", "checkout", "--quiet", "--detach", "FETCH_HEAD"], cwd=checkout)
        verify_source_checkout(checkout, source["commit"], require_untracked_clean=True)
        checkout.replace(destination)


def verify_source_checkout(source_dir, expected_commit, *, require_untracked_clean):
    checked_out = run(["git", "rev-parse", "HEAD"], cwd=source_dir, capture=True).strip()
    if checked_out != expected_commit:
        raise RuntimeError(f"checked out {checked_out}, expected {expected_commit}")
    status = run(
        [
            "git", "status", "--porcelain=v1",
            "--untracked-files=all" if require_untracked_clean else "--untracked-files=no",
        ],
        cwd=source_dir,
        capture=True,
    )
    if status:
        raise RuntimeError(f"source checkout is not clean: {status.splitlines()[0]}")


def frozen_build_environment(source, source_dir):
    environment = os.environ.copy()
    if source["identity_contract"] != CLEAN_SOURCE_COMMIT_CONTRACT:
        return environment
    verify_source_checkout(
        source_dir, source["commit"], require_untracked_clean=True
    )
    environment.pop("BITCOIN_GENBUILD_FROZEN_SOURCE_COMMIT", None)
    environment.pop("BITCOIN_GENBUILD_NO_GIT", None)
    header = source_dir / "src" / "obj" / "build.h"
    header.parent.mkdir(parents=True, exist_ok=True)
    run(
        [source_dir / "share" / "genbuild.sh", header, source_dir],
        env=environment,
    )
    expected_prefix = (
        f'#define BUILD_SOURCE_COMMIT "{source["commit"]}"\n'
        "#define BUILD_SOURCE_DIRTY 0\n"
    )
    try:
        header_text = header.read_text(encoding="utf8")
    except OSError as error:
        raise RuntimeError("clean source identity header was not generated") from error
    if not header_text.startswith(expected_prefix):
        raise RuntimeError("generated build header does not bind the exact clean source")
    environment["BITCOIN_GENBUILD_FROZEN_SOURCE_COMMIT"] = source["commit"]
    return environment


def safe_child(root, relative, *suffix):
    root = Path(root).resolve()
    candidate = root.joinpath(relative, *suffix).resolve()
    if candidate == root or not candidate.is_relative_to(root):
        raise RuntimeError(f"unsafe path outside workspace root: {candidate}")
    return candidate


def normalized_path_parts(path):
    """Return a conservative, filesystem-independent path identity key.

    ``Path.resolve`` does not canonicalize component case on case-insensitive
    filesystems.  Treat case and Unicode-normalization variants as aliases on
    every host.  This can reject two distinct paths on a case-sensitive host,
    which is the safe result for roots that will later be removed recursively.
    """
    return tuple(
        unicodedata.normalize("NFC", part).casefold()
        for part in Path(path).parts
    )


def filesystem_relative_path(path, root):
    """Return ``path`` relative to ``root`` across safe filesystem aliases.

    Lexical containment handles the ordinary path.  Normalized components
    close case/Unicode aliases, and ``samefile`` closes existing symlink, mount,
    and other device/inode aliases without relying on their spelling.
    """
    path = Path(path).resolve()
    root = Path(root).resolve()
    try:
        return path.relative_to(root)
    except ValueError:
        pass

    path_parts = normalized_path_parts(path)
    root_parts = normalized_path_parts(root)
    if (
        len(path_parts) >= len(root_parts)
        and path_parts[:len(root_parts)] == root_parts
    ):
        return Path(*path.parts[len(root.parts):])

    for depth, ancestor in enumerate((path, *path.parents)):
        try:
            if ancestor.samefile(root):
                return Path(*path.parts[len(path.parts) - depth:])
        except OSError:
            continue
    return None


def reject_tracked_destructive_root(path, repository_root):
    """Do not let a cleanup target overlap tracked repository content."""
    path = Path(path).resolve()
    repository_root = Path(repository_root).resolve()
    relative = filesystem_relative_path(path, repository_root)
    if relative is None:
        return
    if (
        not relative.parts
        or unicodedata.normalize("NFC", relative.parts[0]).casefold() == ".git"
    ):
        raise RuntimeError(f"unsafe cleanup target inside repository metadata: {path}")
    tracked = run(
        ["git", "ls-files", "-z"],
        cwd=repository_root,
        capture=True,
    )
    relative_parts = normalized_path_parts(relative)
    for tracked_path in tracked.rstrip("\0").split("\0"):
        if not tracked_path:
            continue
        tracked_parts = normalized_path_parts(Path(tracked_path))
        if (
            len(tracked_parts) >= len(relative_parts)
            and tracked_parts[:len(relative_parts)] == relative_parts
        ):
            raise RuntimeError(
                f"cleanup target contains tracked repository files: {path}"
            )


def download_exact_release(source, *, output_dir, build_root, host):
    """Install an immutable, digest-pinned upstream release asset.

    The functional framework expects Blackcoin's current executable names, so
    legacy `blackmored`/`blackmore-cli` members are deliberately normalized at
    install time. The archive and each extracted executable are independently
    pinned. No archive path is extracted to disk.
    """
    asset = source.get("release_asset")
    if asset is None or asset["host"] != host:
        return None

    archive = safe_child(build_root, f"{source['install_dir']}-release.tar.gz")
    request = urllib.request.Request(
        asset["url"],
        headers={"User-Agent": "Blackcoin-v30.1.1-mixed-version-gate"},
    )
    with urllib.request.urlopen(request) as response, archive.open("wb") as destination:
        shutil.copyfileobj(response, destination)
    if file_sha256(archive) != asset["sha256"]:
        raise RuntimeError(f"{source['version']} release archive digest mismatch")

    destination = safe_child(output_dir, source["install_dir"], "bin")
    destination.mkdir(parents=True, exist_ok=True)
    installed = {}
    hashes = {}
    with tarfile.open(archive, mode="r:gz") as bundle:
        for installed_name, member_key, digest_key in (
            ("blackcoind", "daemon_member", "daemon_sha256"),
            ("blackcoin-cli", "cli_member", "cli_sha256"),
        ):
            member_name = asset[member_key]
            try:
                member = bundle.getmember(member_name)
            except KeyError as error:
                raise RuntimeError(
                    f"{source['version']} release archive is missing {member_name}"
                ) from error
            if not member.isfile():
                raise RuntimeError(
                    f"{source['version']} release member is not a regular file: {member_name}"
                )
            source_file = bundle.extractfile(member)
            if source_file is None:
                raise RuntimeError(f"cannot read {member_name}")
            installed_path = destination / installed_name
            with installed_path.open("wb") as output:
                shutil.copyfileobj(source_file, output)
            installed_path.chmod(0o755)
            digest = file_sha256(installed_path)
            if digest != asset[digest_key]:
                raise RuntimeError(
                    f"{source['version']} release member digest mismatch: {member_name}"
                )
            installed[installed_name] = installed_path
            hashes[installed_name] = digest

    reported_versions = {}
    for installed_name, installed_path in installed.items():
        reported_versions[installed_name] = verified_binary_version(
            installed_path, source, scratch_root=build_root
        )
    return {
        **provenance_source_metadata(source),
        "host": host,
        "origin": "digest-pinned-release-asset",
        "identity_verified": True,
        "release_asset_url": asset["url"],
        "release_asset_sha256": asset["sha256"],
        "binaries": hashes,
        "reported_versions": reported_versions,
    }


def tree_sha256(root, *, exclude=()):
    """Seal file contents, modes, names and internal links, never following links."""
    root = root.resolve()
    digest = hashlib.sha256()

    def inaccessible(error):
        raise error

    for directory, directories, files in os.walk(root, followlinks=False, onerror=inaccessible):
        directories.sort()
        files.sort()
        for name in sorted(directories + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if relative in exclude:
                continue
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                if not path.resolve().is_relative_to(root):
                    raise RuntimeError(f"retained tree has escaping symlink: {relative}")
                value = [relative, "link", os.readlink(path)]
            elif stat.S_ISREG(info.st_mode):
                value = [relative, "file", stat.S_IMODE(info.st_mode), file_sha256(path)]
            elif stat.S_ISDIR(info.st_mode):
                value = [relative, "directory", stat.S_IMODE(info.st_mode)]
            else:
                raise RuntimeError(f"retained tree has unsupported file: {relative}")
            digest.update(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    return digest.hexdigest()


def retained_build_environment():
    # Do not let undeclared shell variables alter a resumed build. Values are
    # hashed in the checkpoint, not written there (proxies may contain secrets).
    allowed = {
        "PATH", "HOME", "TMPDIR", "SYSTEMROOT", "DEVELOPER_DIR", "SDKROOT",
        "MACOSX_DEPLOYMENT_TARGET", "CC", "CXX", "AR", "RANLIB", "NM", "LD",
        "STRIP", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS",
        "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH",
        "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SOURCE_DATE_EPOCH", "AUTOCONF", "AUTOMAKE", "ACLOCAL", "LIBTOOLIZE",
    }
    environment = {key: value for key, value in os.environ.items() if key in allowed}
    environment.update({"LC_ALL": "C", "LANG": "C", "TZ": "UTC"})
    return environment


def retained_build_inputs(source, *, manifest_digest, build_root, output_dir,
                          host, environment):
    tools = {}
    fingerprints = {}

    def fingerprint(executable):
        path = Path(executable).resolve()
        if path.is_relative_to(build_root) or path.is_relative_to(output_dir):
            raise RuntimeError("build tools must not come from the retained workspace/output")
        if path not in fingerprints:
            version = subprocess.run([str(path), "--version"], env=environment,
                                     text=True, capture_output=True, timeout=30, check=False)
            fingerprints[path] = [str(path), file_sha256(path), version.returncode,
                                  (version.stdout + version.stderr)[:8192]]
        return fingerprints[path]

    commands = {name: name for name in ("sh", "make", "git", "cc", "c++", "clang", "clang++", "ar",
                 "ranlib", "ld", "nm", "strip", "autoconf", "automake", "autoreconf",
                 "aclocal", "glibtoolize", "libtoolize", "cmake", "pkg-config",
                 "python3", "perl", "m4", "bison", "patch", "tar", "xcrun")}
    for name in ("CC", "CXX", "AR", "RANLIB", "NM", "LD", "STRIP", "AUTOCONF",
                 "AUTOMAKE", "ACLOCAL", "LIBTOOLIZE"):
        if environment.get(name):
            commands[name] = shlex.split(environment[name])[0]
    for name, command in commands.items():
        found = shutil.which(command, path=environment.get("PATH"))
        if found:
            tools[name] = fingerprint(found)
    sdk = None
    if "xcrun" in tools:
        xcrun = tools["xcrun"][0]
        sdk_path = Path(run([xcrun, "--show-sdk-path"], capture=True, env=environment).strip()).resolve()
        sdk = {"path": str(sdk_path)}
        for name in ("SDKSettings.json", "SDKSettings.plist"):
            if (sdk_path / name).is_file():
                sdk[name] = file_sha256(sdk_path / name)
        for name in ("clang", "clang++", "ld", "ar", "ranlib"):
            path = Path(run([xcrun, "--find", name], capture=True, env=environment).strip()).resolve()
            tools["xcrun:" + name] = fingerprint(path)
    return {
        "source": source, "manifest_sha256": manifest_digest,
        "builder_sha256": file_sha256(Path(__file__)), "host": host,
        "build_root": str(build_root), "output_dir": str(output_dir),
        "tools": tools, "sdk": sdk,
        "environment_sha256": hashlib.sha256(json.dumps(
            environment, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    }


@contextmanager
def retained_build_lock(build_root):
    # The checkpoint must never seal another active builder's partial writes.
    import fcntl

    build_root.mkdir(parents=True, exist_ok=True)
    path = build_root / BUILD_LOCK_NAME
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("retained build workspace is already in use") from error
        yield


def read_build_checkpoint(build_root, expected_digest):
    path = build_root / CHECKPOINT_NAME
    if not SHA256_RE.fullmatch(expected_digest) or path.is_symlink() or not path.is_file():
        raise RuntimeError("resume requires the checkpoint digest printed by the prior trusted run")
    if file_sha256(path) != expected_digest:
        raise RuntimeError("retained build checkpoint digest mismatch")
    try:
        document = json.loads(path.read_text(encoding="utf8"))
    except (ValueError, OSError) as error:
        raise RuntimeError("invalid retained build checkpoint") from error
    if (not isinstance(document, dict) or document.get("schema") != 1
            or document.get("contract") != "retained-source-build-v1"
            or type(document.get("next_phase")) is not int
            or not 0 <= document["next_phase"] <= len(BUILD_PHASES)):
        raise RuntimeError("unsupported retained build checkpoint")
    if tree_sha256(build_root, exclude=(CHECKPOINT_NAME, BUILD_LOCK_NAME)) != document.get("workspace_sha256"):
        raise RuntimeError("retained workspace contents changed since the trusted checkpoint")
    return document


def write_build_checkpoint(build_root, inputs, next_phase):
    document = {
        "schema": 1, "contract": "retained-source-build-v1", "inputs": inputs,
        "next_phase": next_phase,
        "workspace_sha256": tree_sha256(build_root, exclude=(CHECKPOINT_NAME, BUILD_LOCK_NAME)),
    }
    path = build_root / CHECKPOINT_NAME
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf8", dir=build_root,
                                     delete=False, prefix=".checkpoint-") as temporary:
        temporary_path = Path(temporary.name)
        json.dump(document, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
    temporary_path.replace(path)
    digest = file_sha256(path)
    print(f"Retained build checkpoint SHA256: {digest}", flush=True)
    print("Resume only with this digest from this trusted run; do not derive it from retained files.", flush=True)
    return digest


def build_source_retained(source, *, build_root, output_dir, host, jobs,
                          inputs, environment, checkpoint=None):
    """Resume authenticated compilation state, never adjacent binary provenance."""
    next_phase = checkpoint["next_phase"] if checkpoint else 0
    source_dir = safe_child(build_root, source["install_dir"])
    staging = build_root / ".output-staging"
    if checkpoint:
        if checkpoint["inputs"] != inputs:
            raise RuntimeError("retained build inputs/toolchain changed; workspace preserved")
        if next_phase:
            verify_source_checkout(source_dir, source["commit"], require_untracked_clean=False)
    # A hard interruption cannot leave an old valid seal beside a now-active
    # partial build. Only a normally returned failed phase creates a new seal.
    (build_root / CHECKPOINT_NAME).unlink(missing_ok=True)
    build_environment = dict(environment)
    if source["identity_contract"] == CLEAN_SOURCE_COMMIT_CONTRACT:
        build_environment["BITCOIN_GENBUILD_FROZEN_SOURCE_COMMIT"] = source["commit"]

    def identity():
        verify_source_checkout(source_dir, source["commit"], require_untracked_clean=True)
        if source_version(source_dir) != source["version"]:
            raise RuntimeError("source version differs from pinned manifest")
        if source["identity_contract"] == CLEAN_SOURCE_COMMIT_CONTRACT:
            header = source_dir / "src" / "obj" / "build.h"
            header.parent.mkdir(parents=True, exist_ok=True)
            initial_environment = dict(environment)
            run([source_dir / "share" / "genbuild.sh", header, source_dir], env=initial_environment)
            expected = (f'#define BUILD_SOURCE_COMMIT "{source["commit"]}"\n'
                        '#define BUILD_SOURCE_DIRTY 0\n')
            if not header.read_text(encoding="utf8").startswith(expected):
                raise RuntimeError("generated build header does not bind the exact clean source")

    def compile_binaries():
        # Only the two copied historical executables need fresh links. Preserve
        # successful objects and libraries, including after a failed make.
        for name in (source["source_daemon"], source["source_cli"]):
            (source_dir / "src" / name).unlink(missing_ok=True)
        run(["make", f"-j{jobs}", "-C", "src", source["source_daemon"], source["source_cli"]],
            cwd=source_dir, env=build_environment)

    phases = (
        lambda: clone_exact_source(source, source_dir),
        identity,
        lambda: run(["make", f"-j{jobs}", "-C", "depends", f"HOST={host}",
                     "NO_QT=1", "NO_UPNP=1", "NO_NATPMP=1"], cwd=source_dir, env=build_environment),
        lambda: run(["./autogen.sh"], cwd=source_dir, env=build_environment),
        lambda: run(["./configure", f"--prefix={source_dir / 'depends' / host}", "--with-gui=no",
                     "--disable-tests", "--disable-bench", "--disable-zmq"], cwd=source_dir, env=build_environment),
        compile_binaries,
    )
    try:
        # Even a failure during installation/identity checking requires freshly
        # linked executables on retry, never acceptance of the staged binaries.
        next_phase = min(next_phase, BUILD_PHASES.index("compile"))
        for index, phase in enumerate(phases):
            if index >= next_phase:
                print(f"Historical source build phase: {BUILD_PHASES[index]}", flush=True)
                phase()
                next_phase = index + 1
        verify_source_checkout(source_dir, source["commit"], require_untracked_clean=False)
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir()
        item = install_built_source(source, source_dir=source_dir, build_root=build_root,
                                    output_dir=staging, host=host)
        next_phase = len(BUILD_PHASES)
        return item, staging
    except Exception:
        # No final output/provenance is published by a failed phase. All
        # successful compilation state remains authenticated by this seal.
        write_build_checkpoint(build_root, inputs, next_phase)
        raise


def install_built_source(source, *, source_dir, build_root, output_dir, host):
    destination = safe_child(output_dir, source["install_dir"], "bin")
    destination.mkdir(parents=True, exist_ok=True)
    hashes = {}
    reported_versions = {}
    source_names = {
        "blackcoind": source["source_daemon"],
        "blackcoin-cli": source["source_cli"],
    }
    for binary in BINARIES:
        built_binary = source_dir / "src" / source_names[binary]
        if built_binary.is_symlink() or not built_binary.is_file():
            raise RuntimeError(f"missing or symbolic build output {built_binary}")
        installed_binary = destination / binary
        shutil.copy2(built_binary, installed_binary)
        installed_binary.chmod(0o755)
        hashes[binary] = file_sha256(installed_binary)
        reported_versions[binary] = verified_binary_version(installed_binary, source, scratch_root=build_root)
    return {
        **provenance_source_metadata(source), "host": host, "origin": "source-build",
        "identity_verified": True, "source_checkout_clean": True,
        "binaries": hashes, "reported_versions": reported_versions,
    }


def build_source(source, *, build_root, output_dir, host, jobs):
    source_dir = safe_child(build_root, source["install_dir"])
    clone_exact_source(source, source_dir)
    verify_source_checkout(source_dir, source["commit"], require_untracked_clean=True)
    actual_version = source_version(source_dir)
    if actual_version != source["version"]:
        raise RuntimeError(
            f"{source['commit']} declares {actual_version}, expected {source['version']}"
        )

    build_environment = frozen_build_environment(source, source_dir)
    run([
        "make", f"-j{jobs}", "-C", "depends", f"HOST={host}",
        "NO_QT=1", "NO_UPNP=1", "NO_NATPMP=1",
    ], cwd=source_dir, env=build_environment)
    run(["./autogen.sh"], cwd=source_dir, env=build_environment)
    prefix = source_dir / "depends" / host
    run([
        "./configure", f"--prefix={prefix}", "--with-gui=no",
        "--disable-tests", "--disable-bench", "--disable-zmq",
    ], cwd=source_dir, env=build_environment)
    verify_source_checkout(source_dir, source["commit"], require_untracked_clean=False)
    run(["make", f"-j{jobs}"], cwd=source_dir, env=build_environment)
    verify_source_checkout(source_dir, source["commit"], require_untracked_clean=False)

    return install_built_source(source, source_dir=source_dir, build_root=build_root,
                                output_dir=output_dir, host=host)


def build_provenance(*, host, manifest_digest, selection_contract, requested_versions, built):
    return {
        "schema": 1, "contract": PROVENANCE_CONTRACT, "host": host,
        "manifest_sha256": manifest_digest, "selection_contract": selection_contract,
        "requested_versions": requested_versions,
        "built_versions": [item["version"] for item in built], "sources": built,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("sources.json"),
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--host", default="x86_64-pc-linux-gnu")
    parser.add_argument("--jobs", type=int, default=max(1, os.cpu_count() or 1))
    parser.add_argument("--preserve-build", action="store_true",
                        help="Keep one exact source build on failure; print a sealed resume digest")
    parser.add_argument("--resume-build", metavar="CHECKPOINT_SHA256",
                        help="Resume only the workspace sealed by this digest from a prior trusted run")
    parser.add_argument(
        "--version",
        dest="requested_versions",
        action="append",
        help=(
            "build one exact manifest version; repeat for a validated subset "
            "(default: build the complete manifest)"
        ),
    )
    args = parser.parse_args()

    if not HOST_RE.fullmatch(args.host):
        parser.error("unsafe host triplet")
    if args.jobs < 1:
        parser.error("jobs must be positive")
    if args.output.is_symlink() or args.build_root.is_symlink():
        parser.error("output/build-root must not be symbolic links")
    manifest_path = args.manifest.resolve()
    output_dir = args.output.resolve()
    build_root = args.build_root.resolve()
    repository_root = Path(__file__).resolve().parents[2]
    protected = {
        Path("/"), Path.home().resolve(), Path.cwd().resolve(),
        repository_root, manifest_path.parent.resolve(),
    }
    if (
        any(filesystem_relative_path(path, output_dir) is not None for path in protected)
        or any(filesystem_relative_path(path, build_root) is not None for path in protected)
        or filesystem_relative_path(output_dir, build_root) is not None
        or filesystem_relative_path(build_root, output_dir) is not None
    ):
        parser.error("unsafe or overlapping output/build-root path")
    try:
        reject_tracked_destructive_root(output_dir, repository_root)
        reject_tracked_destructive_root(build_root, repository_root)
    except RuntimeError as error:
        parser.error(str(error))
    manifest = load_manifest(manifest_path)
    manifest_digest = file_sha256(manifest_path)
    try:
        selection_contract, requested_versions, selected_sources = (
            select_manifest_sources(manifest["sources"], args.requested_versions)
        )
    except ValueError as error:
        parser.error(str(error))

    if args.preserve_build or args.resume_build:
        if len(selected_sources) != 1:
            parser.error("preserve/resume requires exactly one selected source version")
        if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
            parser.error("preserved builds require an absent or empty output directory")
        with retained_build_lock(build_root):
            if not args.resume_build and any(
                path.name != BUILD_LOCK_NAME for path in build_root.iterdir()
            ):
                parser.error("nonempty build workspace requires its prior trusted --resume-build digest")
            checkpoint = read_build_checkpoint(build_root, args.resume_build) if args.resume_build else None
            environment = retained_build_environment()
            inputs = retained_build_inputs(
                selected_sources[0], manifest_digest=manifest_digest, build_root=build_root,
                output_dir=output_dir, host=args.host, environment=environment)
            if checkpoint and checkpoint.get("inputs") != inputs:
                raise RuntimeError("retained build inputs/toolchain changed; workspace preserved")
            remote_objects(selected_sources[0])
            item, staging = build_source_retained(
                selected_sources[0], build_root=build_root, output_dir=output_dir,
                host=args.host, jobs=args.jobs, inputs=inputs, environment=environment,
                checkpoint=checkpoint)
            provenance = build_provenance(
                host=args.host, manifest_digest=manifest_digest, selection_contract=selection_contract,
                requested_versions=requested_versions, built=[item])
            try:
                (staging / "provenance.json").write_text(
                    json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf8")
                output_dir.parent.mkdir(parents=True, exist_ok=True)
                if output_dir.exists():
                    output_dir.rmdir()  # Only the explicitly checked empty destination.
                staging.replace(output_dir)
            except Exception:
                write_build_checkpoint(build_root, inputs, len(BUILD_PHASES))
                raise
            (build_root / CHECKPOINT_NAME).unlink(missing_ok=True)
        print(json.dumps(provenance, indent=2, sort_keys=True))
        print(f"Preserved source build workspace: {build_root}")
        return 0

    for source in selected_sources:
        remote_objects(source)

    build_root.mkdir(parents=True, exist_ok=True)
    if cached_provenance_is_reusable(
        output_dir,
        manifest_digest,
        manifest["sources"],
        required_versions=requested_versions,
        host=args.host,
        scratch_root=build_root,
    ):
        print(f"Reusing verified mixed-version binaries in {output_dir}")
        shutil.rmtree(build_root, ignore_errors=True)
        return 0

    shutil.rmtree(output_dir, ignore_errors=True)
    shutil.rmtree(build_root, ignore_errors=True)
    output_dir.mkdir(parents=True)
    build_root.mkdir(parents=True)
    built = []
    try:
        for source in selected_sources:
            exact_release = download_exact_release(
                source,
                output_dir=output_dir,
                build_root=build_root,
                host=args.host,
            )
            built.append(exact_release or build_source(
                source,
                build_root=build_root,
                output_dir=output_dir,
                host=args.host,
                jobs=args.jobs,
            ))
    finally:
        shutil.rmtree(build_root, ignore_errors=True)

    provenance = build_provenance(
        host=args.host, manifest_digest=manifest_digest, selection_contract=selection_contract,
        requested_versions=requested_versions, built=built)
    (output_dir / "provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf8",
    )
    print(json.dumps(provenance, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
