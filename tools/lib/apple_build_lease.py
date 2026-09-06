#!/usr/bin/env python3
"""Kernel-backed shared/exclusive lease protocol for Apple build tooling.

The coordination lock lives outside every build-cache root. Shell and Ruby
callers open the lock file, pass that descriptor here, and keep the same open
file description alive for their full lane. Darwin flock ownership therefore
survives this helper process and follows inherited descriptors into descendants.

Lease records are durable evidence, not stale-PID hints. A failed, cancelled, or
crashed owner leaves its record behind. Exclusive maintenance refuses every
record and never guesses that an orphan is safe to clear.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = 1
EFFECTIVE_UID = os.geteuid()
ROOT_NAME = "apple-build-interlock-v1"
LOCK_NAME = "coordination.lock"
REGISTRY_LOCK_NAME = "registry.lock"
POLICY_LOCK_NAME = "policy.lock"
ROLLOUT_NAME = "rollout-policy-v1"
LEASES_NAME = "leases"
SUSPEND_NAME = "SUSPENDED"

REQUIRED_ROLLOUT = (
    "protocol=1",
    "global-cleanup-entrypoints",
    "manual-xcode-writers-disabled-or-wrapped",
    "mozz-current-writers",
    "mozz-legacy-writers",
    "plozz-current-writers",
    "plozz-legacy-writers",
    "twozz-current-writers",
    "twozz-legacy-writers",
)

OWNER_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)


class LeaseError(RuntimeError):
    """A safety check failed."""


def fail(message: str) -> None:
    raise LeaseError(message)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def paths() -> dict[str, Path]:
    test_root = os.environ.get("APPLE_BUILD_INTERLOCK_TEST_ROOT")
    test_mode = os.environ.get("APPLE_BUILD_INTERLOCK_TESTING")
    if test_root or test_mode:
        if test_mode != "1" or not test_root:
            fail("test interlock root requires APPLE_BUILD_INTERLOCK_TESTING=1")
        root = Path(test_root)
        if not root.is_absolute() or root.name != ROOT_NAME:
            fail("test interlock root must be an absolute apple-build-interlock-v1 path")
        try:
            resolved_parent = root.parent.resolve(strict=True)
            resolved_temp = Path(tempfile.gettempdir()).resolve(strict=True)
        except OSError as exc:
            fail(f"cannot resolve test interlock root: {exc}")
        if resolved_parent != resolved_temp and resolved_temp not in resolved_parent.parents:
            fail("test interlock root must live under the system temporary directory")
        try:
            fixture_home = Path(os.environ["HOME"]).resolve(strict=True)
            expected_policy_home = (
                fixture_home / ".config" / "smart-disk-maintenance"
            ).resolve(strict=True)
            fixture_home_st = fixture_home.stat()
        except (KeyError, OSError) as exc:
            fail(f"cannot resolve test fixture home: {exc}")
        if resolved_parent != expected_policy_home:
            fail("test interlock root must belong to the test HOME fixture")
        if fixture_home == resolved_temp or resolved_temp not in fixture_home.parents:
            fail("test HOME must be a dedicated directory under system temporary storage")
        if not stat.S_ISDIR(fixture_home_st.st_mode):
            fail("test HOME is not a directory")
        _check_owned(fixture_home_st, str(fixture_home))
        _check_private_mode(fixture_home_st, str(fixture_home))
        sentinel = resolved_parent / ".apple-build-interlock-test-root"
        try:
            sentinel_st = sentinel.lstat()
        except OSError as exc:
            fail(f"test interlock sentinel is missing: {exc}")
        if not stat.S_ISREG(sentinel_st.st_mode) or stat.S_ISLNK(sentinel_st.st_mode):
            fail("test interlock sentinel is not a regular file")
        _check_owned(sentinel_st, str(sentinel))
        _check_private_mode(sentinel_st, str(sentinel))
        policy_home = resolved_parent
        root = resolved_parent / ROOT_NAME
        home = fixture_home
    else:
        effective_uid = EFFECTIVE_UID
        try:
            canonical_home = Path(pwd.getpwuid(effective_uid).pw_dir).resolve(strict=True)
        except (KeyError, OSError) as exc:
            fail(f"cannot resolve canonical home for effective uid {effective_uid}: {exc}")
        policy_home = canonical_home / ".config" / "smart-disk-maintenance"
        root = policy_home / ROOT_NAME
        home = canonical_home
    return {
        "home": home,
        "policy_home": policy_home,
        "root": root,
        "lock": root / LOCK_NAME,
        "registry_lock": root / REGISTRY_LOCK_NAME,
        "policy_lock": root / POLICY_LOCK_NAME,
        "rollout": root / ROLLOUT_NAME,
        "leases": root / LEASES_NAME,
        "suspend": policy_home / SUSPEND_NAME,
    }


def _check_owned(st: os.stat_result, label: str) -> None:
    if st.st_uid != EFFECTIVE_UID:
        fail(f"{label} is not owned by effective uid {EFFECTIVE_UID}")


def _check_private_mode(st: os.stat_result, label: str) -> None:
    if stat.S_IMODE(st.st_mode) & 0o077:
        fail(f"{label} is group/world accessible")


def ensure_secure_directory(path: Path, *, create: bool) -> None:
    if create:
        try:
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
        except OSError as exc:
            fail(f"cannot create interlock directory {path}: {exc}")
    try:
        st = path.lstat()
    except OSError as exc:
        fail(f"cannot inspect interlock directory {path}: {exc}")
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
        fail(f"interlock path is not a real directory: {path}")
    _check_owned(st, str(path))
    _check_private_mode(st, str(path))


def _open_regular_file(path: Path, flags: int, mode: int = 0o600) -> int:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags | nofollow, mode)
    except OSError as exc:
        fail(f"cannot open interlock file {path}: {exc}")
    try:
        validate_fd_path(fd, path, private=True)
    except Exception:
        os.close(fd)
        raise
    return fd


def ensure_lock_file(path: Path) -> None:
    fd = _open_regular_file(path, os.O_CREAT | os.O_RDWR)
    os.close(fd)


def prepare_namespace() -> None:
    p = paths()
    ensure_secure_directory(p["root"], create=True)
    ensure_secure_directory(p["leases"], create=True)
    ensure_lock_file(p["lock"])
    ensure_lock_file(p["registry_lock"])
    ensure_lock_file(p["policy_lock"])


def validate_fd_path(fd: int, path: Path, *, private: bool) -> os.stat_result:
    try:
        fd_st = os.fstat(fd)
        path_st = path.lstat()
    except OSError as exc:
        fail(f"cannot verify {path}: {exc}")
    if not stat.S_ISREG(fd_st.st_mode) or not stat.S_ISREG(path_st.st_mode):
        fail(f"interlock file is not regular: {path}")
    if stat.S_ISLNK(path_st.st_mode):
        fail(f"interlock file is a symlink: {path}")
    if (fd_st.st_dev, fd_st.st_ino) != (path_st.st_dev, path_st.st_ino):
        fail(f"interlock file was replaced while open: {path}")
    _check_owned(fd_st, str(path))
    if private:
        _check_private_mode(fd_st, str(path))
    elif stat.S_IMODE(fd_st.st_mode) & 0o022:
        fail(f"policy file is group/world writable: {path}")
    return fd_st


def validate_proof_fd(fd: int) -> os.stat_result:
    try:
        st = os.fstat(fd)
    except OSError as exc:
        fail(f"cannot verify inherited lease proof fd {fd}: {exc}")
    if not stat.S_ISREG(st.st_mode):
        fail("inherited lease proof is not a regular file")
    _check_owned(st, "inherited lease proof")
    _check_private_mode(st, "inherited lease proof")
    return st


def process_start(pid: int) -> str:
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            check=False,
            text=True,
            capture_output=True,
        )
    except OSError as exc:
        fail(f"cannot inspect process {pid}: {exc}")
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        fail(f"cannot verify process identity for pid {pid}")
    return value


def fsync_directory(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        fail(f"cannot sync interlock directory {path}: {exc}")


def record_path(lease_id: str) -> Path:
    return paths()["leases"] / f"{lease_id}.json"


def validate_uuid(value: str, label: str) -> str:
    normalized = value.lower()
    if not UUID_RE.fullmatch(normalized):
        fail(f"invalid {label}")
    return normalized


def validate_owner(owner: str) -> None:
    if not OWNER_RE.fullmatch(owner):
        fail(f"invalid lease owner label: {owner!r}")


def _validate_record_shape(payload: Any, path: Path) -> dict[str, Any]:
    if not isinstance(payload, dict):
        fail(f"lease record is not an object: {path}")
    required = {
        "protocol",
        "lease_id",
        "token",
        "mode",
        "state",
        "owner",
        "request_pid",
        "request_start",
        "created_at",
        "cwd",
        "lock_dev",
        "lock_ino",
        "proof_dev",
        "proof_ino",
        "policy_lock_dev",
        "policy_lock_ino",
        "rollout_dev",
        "rollout_ino",
        "rollout_sha256",
    }
    optional = {"release_requested_at", "release_requested_by_pid", "release_requested_by_start"}
    keys = set(payload)
    if not required.issubset(keys) or not keys.issubset(required | optional):
        fail(f"lease record has an unknown or incomplete schema: {path}")
    if payload["protocol"] != PROTOCOL_VERSION:
        fail(f"lease record uses an unknown protocol: {path}")
    lease_id = validate_uuid(str(payload["lease_id"]), "lease id")
    validate_uuid(str(payload["token"]), "lease token")
    if path.name != f"{lease_id}.json":
        fail(f"lease record filename does not match its identity: {path}")
    if payload["mode"] not in {"shared", "exclusive"}:
        fail(f"lease record has an unknown mode: {path}")
    if payload["state"] not in {"active", "release_requested"}:
        fail(f"lease record has an unknown state: {path}")
    validate_owner(str(payload["owner"]))
    if not isinstance(payload["request_pid"], int) or payload["request_pid"] <= 1:
        fail(f"lease record has an invalid requester pid: {path}")
    for key in ("request_start", "created_at", "cwd"):
        if not isinstance(payload[key], str) or not payload[key]:
            fail(f"lease record has an invalid {key}: {path}")
    for key in ("lock_dev", "lock_ino", "proof_dev", "proof_ino"):
        if not isinstance(payload[key], int) or payload[key] < 0:
            fail(f"lease record has an invalid {key}: {path}")
    policy_keys = (
        "policy_lock_dev",
        "policy_lock_ino",
        "rollout_dev",
        "rollout_ino",
        "rollout_sha256",
    )
    if payload["mode"] == "shared":
        if any(payload[key] is not None for key in policy_keys):
            fail(f"shared lease unexpectedly carries maintenance policy identity: {path}")
    else:
        for key in policy_keys[:-1]:
            if not isinstance(payload[key], int) or payload[key] < 0:
                fail(f"exclusive lease has an invalid {key}: {path}")
        if not isinstance(payload["rollout_sha256"], str) or len(payload["rollout_sha256"]) != 64:
            fail(f"exclusive lease has an invalid rollout digest: {path}")
    if payload["state"] == "release_requested":
        if not optional.issubset(keys):
            fail(f"release-requested lease lacks release identity: {path}")
    elif keys & optional:
        fail(f"active lease unexpectedly carries release identity: {path}")
    return payload


def read_record(path: Path) -> dict[str, Any]:
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, os.O_RDONLY | nofollow)
    except OSError as exc:
        fail(f"cannot open lease record {path}: {exc}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            fail(f"lease record is not regular: {path}")
        _check_owned(st, str(path))
        _check_private_mode(st, str(path))
        data = os.read(fd, 65537)
        if len(data) > 65536:
            fail(f"lease record is unexpectedly large: {path}")
    finally:
        os.close(fd)
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"lease record is malformed: {path}: {exc}")
    return _validate_record_shape(payload, path)


def scan_records() -> list[dict[str, Any]]:
    leases = paths()["leases"]
    ensure_secure_directory(leases, create=False)
    try:
        entries = sorted(os.scandir(leases), key=lambda entry: entry.name)
    except OSError as exc:
        fail(f"cannot enumerate lease records: {exc}")
    records: list[dict[str, Any]] = []
    for entry in entries:
        if not entry.name.endswith(".json"):
            fail(f"unknown file in lease registry: {entry.path}")
        try:
            if not entry.is_file(follow_symlinks=False) or entry.is_symlink():
                fail(f"unexpected lease registry entry: {entry.path}")
        except OSError as exc:
            fail(f"cannot inspect lease registry entry {entry.path}: {exc}")
        records.append(read_record(Path(entry.path)))
    return records


def write_new_record(payload: dict[str, Any]) -> None:
    path = record_path(payload["lease_id"])
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        fail(f"cannot publish lease record {path}: {exc}")
    encoded = (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8")
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    fsync_directory(path.parent)


def replace_record(payload: dict[str, Any]) -> None:
    destination = record_path(payload["lease_id"])
    leases = destination.parent
    fd, temporary = tempfile.mkstemp(
        prefix=f".{payload['lease_id']}.", suffix=".tmp", dir=leases
    )
    encoded = (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8")
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, encoded)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, destination)
        fsync_directory(leases)
    except Exception:
        if fd >= 0:
            os.close(fd)
        raise


def open_registry_lock() -> int:
    p = paths()
    fd = _open_regular_file(p["registry_lock"], os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    validate_fd_path(fd, p["registry_lock"], private=True)
    return fd


def read_rollout_policy(fd: int) -> tuple[os.stat_result, str]:
    p = paths()
    st = validate_fd_path(fd, p["rollout"], private=False)
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        data = os.read(fd, 65537)
    except OSError as exc:
        fail(f"cannot read rollout policy: {exc}")
    if len(data) > 65536:
        fail("rollout policy is unexpectedly large")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"rollout policy is not UTF-8: {exc}")
    lines = tuple(line.strip() for line in text.splitlines() if line.strip())
    if lines != REQUIRED_ROLLOUT:
        missing = [line for line in REQUIRED_ROLLOUT if line not in lines]
        unexpected = [line for line in lines if line not in REQUIRED_ROLLOUT]
        detail: list[str] = []
        if missing:
            detail.append(f"missing={','.join(missing)}")
        if unexpected:
            detail.append(f"unexpected={','.join(unexpected)}")
        if not missing and not unexpected:
            detail.append("entries are not in the required order")
        fail("rollout policy is incomplete; " + "; ".join(detail))
    return st, hashlib.sha256(data).hexdigest()


def ensure_not_suspended() -> None:
    marker = paths()["suspend"]
    try:
        marker.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        fail(f"cannot verify maintenance suspension marker {marker}: {exc}")
    fail(f"destructive maintenance is suspended by {marker}")


def validate_policy_fds(policy_lock_fd: int, rollout_fd: int) -> tuple[os.stat_result, os.stat_result, str]:
    p = paths()
    policy_st = validate_fd_path(policy_lock_fd, p["policy_lock"], private=True)
    # Compliant policy writers take LOCK_EX before changing SUSPENDED or rollout.
    # This shared lock remains on the caller's inherited descriptor for the full
    # destructive lane.
    fcntl.flock(policy_lock_fd, fcntl.LOCK_SH)
    ensure_not_suspended()
    rollout_st, digest = read_rollout_policy(rollout_fd)
    ensure_not_suspended()
    return policy_st, rollout_st, digest


def expected_record(
    *,
    mode: str,
    owner: str,
    lease_id: str,
    token: str,
    lock_st: os.stat_result,
    proof_st: os.stat_result,
    policy_identity: tuple[os.stat_result, os.stat_result, str] | None,
) -> dict[str, Any]:
    request_pid = os.getppid()
    request_start = process_start(request_pid)
    policy_st: os.stat_result | None = None
    rollout_st: os.stat_result | None = None
    rollout_digest: str | None = None
    if policy_identity is not None:
        policy_st, rollout_st, rollout_digest = policy_identity
    return {
        "protocol": PROTOCOL_VERSION,
        "lease_id": lease_id,
        "token": token,
        "mode": mode,
        "state": "active",
        "owner": owner,
        "request_pid": request_pid,
        "request_start": request_start,
        "created_at": utc_now(),
        "cwd": os.getcwd(),
        "lock_dev": lock_st.st_dev,
        "lock_ino": lock_st.st_ino,
        "proof_dev": proof_st.st_dev,
        "proof_ino": proof_st.st_ino,
        "policy_lock_dev": None if policy_st is None else policy_st.st_dev,
        "policy_lock_ino": None if policy_st is None else policy_st.st_ino,
        "rollout_dev": None if rollout_st is None else rollout_st.st_dev,
        "rollout_ino": None if rollout_st is None else rollout_st.st_ino,
        "rollout_sha256": rollout_digest,
    }


def acquire(args: argparse.Namespace) -> None:
    prepare_namespace()
    mode = args.mode
    if mode not in {"shared", "exclusive"}:
        fail(f"unknown lease mode: {mode}")
    validate_owner(args.owner)
    lease_id = validate_uuid(args.lease_id, "lease id")
    token = validate_uuid(args.token, "lease token")
    p = paths()
    lock_st = validate_fd_path(args.lock_fd, p["lock"], private=True)
    proof_st = validate_proof_fd(args.proof_fd)

    policy_identity = None
    if mode == "exclusive":
        if args.policy_lock_fd is None or args.rollout_fd is None:
            fail("exclusive lease requires policy descriptors")
        policy_identity = validate_policy_fds(args.policy_lock_fd, args.rollout_fd)

    operation = fcntl.LOCK_SH if mode == "shared" else fcntl.LOCK_EX | fcntl.LOCK_NB
    release_wait_deadline = time.monotonic() + 5
    while True:
        try:
            fcntl.flock(args.lock_fd, operation)
        except BlockingIOError:
            fail("another build/release lease is active; destructive maintenance refused")
        except OSError as exc:
            fail(f"cannot acquire {mode} build lease: {exc}")

        # Detect pathname replacement after flock acquisition, not only before it.
        lock_st = validate_fd_path(args.lock_fd, p["lock"], private=True)
        registry_fd = open_registry_lock()
        wait_for_finalizer = False
        try:
            records = scan_records()
            if mode == "exclusive" and records:
                owners = ", ".join(f"{r['owner']} ({r['lease_id']})" for r in records[:8])
                fail(f"lease registry is not empty; orphan or active owner evidence: {owners}")
            if mode == "shared":
                exclusive = [record for record in records if record["mode"] == "exclusive"]
                active_exclusive = [
                    record for record in exclusive if record["state"] == "active"
                ]
                if active_exclusive:
                    record = active_exclusive[0]
                    fail(
                        "exclusive maintenance evidence remains; builds are blocked until "
                        f"owner review: {record['owner']} ({record['lease_id']})"
                    )
                wait_for_finalizer = bool(exclusive)
            if not wait_for_finalizer:
                if policy_identity is not None:
                    policy_identity = validate_policy_fds(
                        args.policy_lock_fd, args.rollout_fd
                    )
                payload = expected_record(
                    mode=mode,
                    owner=args.owner,
                    lease_id=lease_id,
                    token=token,
                    lock_st=lock_st,
                    proof_st=proof_st,
                    policy_identity=policy_identity,
                )
                write_new_record(payload)
                return
        finally:
            os.close(registry_fd)

        # A clean exclusive owner has authenticated release, but its finalizer may
        # be racing this newly unblocked reader. Briefly drop the not-yet-owned
        # shared lock so that finalizer can take EX and remove the record.
        fcntl.flock(args.lock_fd, fcntl.LOCK_UN)
        if time.monotonic() >= release_wait_deadline:
            fail("completed exclusive lease did not finalize; owner review required")
        time.sleep(0.05)


def validate_existing(
    args: argparse.Namespace, *, require_owner: bool = False
) -> tuple[dict[str, Any], str]:
    p = paths()
    ensure_secure_directory(p["root"], create=False)
    ensure_secure_directory(p["leases"], create=False)
    lease_id = validate_uuid(args.lease_id, "lease id")
    token = validate_uuid(args.token, "lease token")
    validate_owner(args.owner)
    lock_st = validate_fd_path(args.lock_fd, p["lock"], private=True)
    proof_st = validate_proof_fd(args.proof_fd)

    registry_fd = open_registry_lock()
    try:
        records = scan_records()
        matches = [record for record in records if record["lease_id"] == lease_id]
        if len(matches) != 1:
            fail(f"lease identity is missing or duplicated: {lease_id}")
        record = matches[0]
        if record["token"] != token or record["owner"] != args.owner:
            fail("inherited lease identity does not match its durable record")
        if record["mode"] != args.mode:
            fail(
                f"inherited lease mode is {record['mode']}, not requested {args.mode}"
            )
        if (record["lock_dev"], record["lock_ino"]) != (lock_st.st_dev, lock_st.st_ino):
            fail("inherited lease lock inode does not match its durable record")
        if (record["proof_dev"], record["proof_ino"]) != (
            proof_st.st_dev,
            proof_st.st_ino,
        ):
            fail("inherited lease proof does not match its durable record")

        if record["mode"] == "exclusive":
            if args.policy_lock_fd is None or args.rollout_fd is None:
                fail("exclusive inherited lease lacks policy descriptors")
            policy_st, rollout_st, digest = validate_policy_fds(
                args.policy_lock_fd, args.rollout_fd
            )
            if (record["policy_lock_dev"], record["policy_lock_ino"]) != (
                policy_st.st_dev,
                policy_st.st_ino,
            ):
                fail("maintenance policy lock was replaced")
            if (record["rollout_dev"], record["rollout_ino"]) != (
                rollout_st.st_dev,
                rollout_st.st_ino,
            ):
                fail("maintenance rollout policy was replaced")
            if record["rollout_sha256"] != digest:
                fail("maintenance rollout policy changed during the lease")

        caller_pid = os.getppid()
        caller_start = process_start(caller_pid)
        role = (
            "owner"
            if caller_pid == record["request_pid"]
            and caller_start == record["request_start"]
            else "inherited"
        )
        if require_owner and role != "owner":
            fail("only the original requester may mark a lease complete")
        return record, role
    finally:
        os.close(registry_fd)


def request_release(args: argparse.Namespace) -> None:
    record, _ = validate_existing(args, require_owner=True)
    if record["state"] != "active":
        fail("lease release was already requested")
    record = dict(record)
    record.update(
        {
            "state": "release_requested",
            "release_requested_at": utc_now(),
            "release_requested_by_pid": os.getppid(),
            "release_requested_by_start": process_start(os.getppid()),
        }
    )
    registry_fd = open_registry_lock()
    try:
        current = read_record(record_path(record["lease_id"]))
        if current["token"] != record["token"] or current["state"] != "active":
            fail("lease record changed before release could be recorded")
        replace_record(record)
    finally:
        os.close(registry_fd)


def _close_unrelated_descriptors() -> None:
    try:
        limit = os.sysconf("SC_OPEN_MAX")
    except (OSError, ValueError):
        limit = 1024
    os.closerange(3, min(int(limit), 65536))


def finalize_release(args: argparse.Namespace) -> None:
    # Finalizers may outlive their launching shell while descendants retain the
    # shared lock. They must not keep terminal/pipeline descriptors alive.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    _close_unrelated_descriptors()
    p = paths()
    ensure_secure_directory(p["root"], create=False)
    ensure_secure_directory(p["leases"], create=False)
    lease_id = validate_uuid(args.lease_id, "lease id")
    token = validate_uuid(args.token, "lease token")
    lock_fd = _open_regular_file(p["lock"], os.O_RDWR)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        lock_st = validate_fd_path(lock_fd, p["lock"], private=True)
        registry_fd = open_registry_lock()
        try:
            records = scan_records()
            matches = [record for record in records if record["lease_id"] == lease_id]
            if len(matches) != 1:
                fail(f"release finalizer cannot find lease {lease_id}")
            record = matches[0]
            if (
                record["token"] != token
                or record["mode"] != args.mode
                or record["state"] != "release_requested"
            ):
                fail("release finalizer found mismatched lease evidence")
            if (record["lock_dev"], record["lock_ino"]) != (
                lock_st.st_dev,
                lock_st.st_ino,
            ):
                fail("release finalizer opened a replacement coordination lock")
            try:
                record_path(lease_id).unlink()
            except OSError as exc:
                fail(f"cannot remove completed lease record: {exc}")
            fsync_directory(p["leases"])
        finally:
            os.close(registry_fd)
    finally:
        os.close(lock_fd)


def inspect_records() -> None:
    p = paths()
    ensure_secure_directory(p["root"], create=False)
    ensure_secure_directory(p["leases"], create=False)
    registry_fd = open_registry_lock()
    try:
        print(json.dumps(scan_records(), sort_keys=True, indent=2))
    finally:
        os.close(registry_fd)


def policy_check(args: argparse.Namespace) -> None:
    prepare_namespace()
    validate_policy_fds(args.policy_lock_fd, args.rollout_fd)


def add_identity_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--mode", required=True, choices=("shared", "exclusive"))
    parser.add_argument("--owner", required=True)
    parser.add_argument("--lease-id", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--lock-fd", type=int, required=True)
    parser.add_argument("--proof-fd", type=int, required=True)
    parser.add_argument("--policy-lock-fd", type=int)
    parser.add_argument("--rollout-fd", type=int)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("prepare")
    commands.add_parser("required-rollout")
    commands.add_parser("inspect")
    commands.add_parser("suspension-check")
    path_parser = commands.add_parser("path")
    path_parser.add_argument(
        "name",
        choices=(
            "home",
            "root",
            "lock",
            "registry_lock",
            "policy_lock",
            "rollout",
            "leases",
            "suspend",
        ),
    )

    acquire_parser = commands.add_parser("acquire")
    add_identity_arguments(acquire_parser)

    validate_parser = commands.add_parser("validate")
    add_identity_arguments(validate_parser)
    validate_parser.add_argument("--role-exit-code", action="store_true")

    release_parser = commands.add_parser("request-release")
    add_identity_arguments(release_parser)

    finalize_parser = commands.add_parser("finalize-release")
    finalize_parser.add_argument("--mode", required=True, choices=("shared", "exclusive"))
    finalize_parser.add_argument("--lease-id", required=True)
    finalize_parser.add_argument("--token", required=True)

    policy_parser = commands.add_parser("policy-check")
    policy_parser.add_argument("--policy-lock-fd", type=int, required=True)
    policy_parser.add_argument("--rollout-fd", type=int, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "prepare":
            prepare_namespace()
        elif args.command == "required-rollout":
            print("\n".join(REQUIRED_ROLLOUT))
        elif args.command == "inspect":
            inspect_records()
        elif args.command == "suspension-check":
            ensure_not_suspended()
        elif args.command == "path":
            print(paths()[args.name])
        elif args.command == "acquire":
            acquire(args)
        elif args.command == "validate":
            _, role = validate_existing(args)
            if args.role_exit_code:
                return 0 if role == "owner" else 10
            print(role)
        elif args.command == "request-release":
            request_release(args)
        elif args.command == "finalize-release":
            finalize_release(args)
        elif args.command == "policy-check":
            policy_check(args)
        else:
            fail(f"unknown command: {args.command}")
    except LeaseError as exc:
        print(f"apple-build-interlock: {exc}", file=sys.stderr)
        return 75
    except Exception as exc:
        print(f"apple-build-interlock: unexpected guard error: {exc}", file=sys.stderr)
        return 75
    return 0


if __name__ == "__main__":
    sys.exit(main())
