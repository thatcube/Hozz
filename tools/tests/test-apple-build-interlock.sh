#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/lib/apple_build_lease.py"
SHELL_LIB="$ROOT/tools/lib/apple-build-lease.sh"
WRAPPER="$ROOT/tools/with-apple-build-lease.sh"
TMP="$(mktemp -d -t hozz-build-interlock-tests)"
FIXTURE_PIDS=()

cleanup() {
  local pid
  for pid in "${FIXTURE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

assert_source_contains() {
  grep -F "$2" "$ROOT/$1" >/dev/null || fail "expected writer lease '$2' in $1"
}

lease_root() {
  printf '%s/.config/smart-disk-maintenance/apple-build-interlock-v1\n' "$1"
}

new_home() {
  local name="$1" home root
  home="$TMP/$name/home"
  mkdir -p "$home"
  chmod 700 "$home"
  root="$(lease_root "$home")"
  mkdir -p "$(dirname "$root")"
  : > "$(dirname "$root")/.apple-build-interlock-test-root"
  chmod 600 "$(dirname "$root")/.apple-build-interlock-test-root"
  printf '%s\n' "$home"
}

test_env() {
  local home="$1"
  shift
  env \
    HOME="$home" \
    APPLE_BUILD_INTERLOCK_TESTING=1 \
    APPLE_BUILD_INTERLOCK_TEST_ROOT="$(lease_root "$home")" \
    "$@"
}

record_count() {
  local leases
  leases="$(lease_root "$1")/leases"
  [[ -d "$leases" ]] || { echo 0; return; }
  find "$leases" -mindepth 1 -maxdepth 1 -type f -name '*.json' |
    wc -l | tr -d ' '
}

wait_for_file() {
  local path="$1" attempts="${2:-100}" i
  for ((i = 0; i < attempts; i++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $path"
}

wait_for_no_records() {
  local home="$1" attempts="${2:-100}" i
  for ((i = 0; i < attempts; i++)); do
    [[ "$(record_count "$home")" == "0" ]] && return 0
    sleep 0.05
  done
  test_env "$home" /usr/bin/python3 "$HELPER" inspect >&2 || true
  fail "lease records did not clear under $home"
}

write_rollout() {
  local home="$1" root
  root="$(lease_root "$home")"
  test_env "$home" /usr/bin/python3 "$HELPER" prepare
  test_env "$home" /usr/bin/python3 "$HELPER" required-rollout > "$root/rollout-policy-v1"
  chmod 600 "$root/rollout-policy-v1"
}

start_shared() {
  local home="$1" owner="$2" ready="$3" release="$4"
  test_env "$home" "$WRAPPER" "$owner" -- /bin/sh -c '
    touch "$1"
    while [ ! -e "$2" ]; do sleep 0.05; done
  ' _ "$ready" "$release" >/dev/null 2>&1 &
  LAST_PID=$!
  FIXTURE_PIDS+=("$LAST_PID")
}

exclusive_probe() {
  local home="$1"
  test_env "$home" "$WRAPPER" --exclusive test/exclusive-probe -- /usr/bin/true \
    >/dev/null 2>&1
}

# The vendored protocol clients must stay byte-identical to the frozen source.
/usr/bin/python3 - "$ROOT" <<'PY'
import hashlib
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "tools/lib/apple-build-lease.sh": (
        "bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705",
        0o644,
    ),
    "tools/lib/apple_build_lease.py": (
        "56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2",
        0o755,
    ),
    "tools/lib/apple_build_lease.rb": (
        "c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372",
        0o644,
    ),
    "tools/with-apple-build-lease.sh": (
        "dc3d932b08b8056704bd37920694952effca451abb155cce1cf8e356752f1b99",
        0o755,
    ),
}
for relative, (digest, mode) in expected.items():
    path = root / relative
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"{relative} differs from frozen Plozz protocol")
    if stat.S_IMODE(path.stat().st_mode) != mode:
        raise SystemExit(f"{relative} has the wrong frozen file mode")
PY

# The current Hozz writer surfaces must acquire before invoking Apple tooling.
assert_source_contains "tools/generate-project.sh" \
  'acquire_apple_build_shared_lease "hozz/generate-project"'
assert_source_contains "tools/simulator-build.sh" \
  'acquire_apple_build_shared_lease "hozz/simulator-build"'
assert_source_contains "tools/run-tests.sh" \
  'acquire_apple_build_shared_lease "hozz/run-tests"'
assert_source_contains "tools/device-build.sh" \
  'acquire_apple_build_shared_lease "hozz/device-build"'
assert_source_contains "tools/mac-build.sh" \
  'acquire_apple_build_shared_lease "hozz/mac-build"'
assert_source_contains "tools/generate-healthkit-catalog.py" \
  '"hozz/generate-healthkit-catalog"'
assert_source_contains "tools/generate-healthkit-catalog.py" \
  'pass_fds=(proof_fd, lock_fd)'
assert_source_contains "AGENTS.md" "tools/simulator-build.sh"
assert_source_contains "CONTRIBUTING.md" "tools/with-apple-build-lease.sh hozz/manual"

# Hozz intentionally does not alter the frozen rollout schema in its writer port.
if /usr/bin/python3 "$HELPER" required-rollout | grep -F "hozz-" >/dev/null; then
  fail "Hozz writer port changed the machine-wide rollout schema"
fi

# Execute every current entrypoint against fake Apple tools. This checks the
# complete nested generate -> build/test/install/launch chains without touching
# Xcode, a simulator, a device, or production build outputs.
ENTRY_ROOT="$TMP/entrypoint-fixture"
ENTRY_BIN="$ENTRY_ROOT/fake-bin"
ENTRY_LOG="$ENTRY_ROOT/calls.log"
mkdir -p "$ENTRY_ROOT/tools/lib" "$ENTRY_BIN"
cp "$ROOT"/tools/{device-build.sh,generate-project.sh,mac-build.sh,run-tests.sh,simulator-build.sh,with-apple-build-lease.sh} \
  "$ENTRY_ROOT/tools/"
cp "$ROOT/tools/generate-healthkit-catalog.py" "$ENTRY_ROOT/tools/"
cp "$ROOT"/tools/lib/{apple-build-lease.sh,apple_build_lease.py,apple_build_lease.rb} \
  "$ENTRY_ROOT/tools/lib/"
chmod 755 "$ENTRY_ROOT"/tools/*.sh "$ENTRY_ROOT/tools/lib/apple-build-lease.sh" \
  "$ENTRY_ROOT/tools/lib/apple_build_lease.py" \
  "$ENTRY_ROOT/tools/generate-healthkit-catalog.py"

cat > "$ENTRY_BIN/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(find "$APPLE_BUILD_INTERLOCK_TEST_ROOT/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
printf 'xcodegen|%s|%s|%s\n' "$APPLE_BUILD_LEASE_OWNER" "$count" "$*" >> "$ENTRY_LOG"
SH

cat > "$ENTRY_BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(find "$APPLE_BUILD_INTERLOCK_TEST_ROOT/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
printf 'xcodebuild|%s|%s|%s\n' "$APPLE_BUILD_LEASE_OWNER" "$count" "$*" >> "$ENTRY_LOG"
mkdir -p "$ENTRY_ROOT/fake-products/Hozz.app"
if [[ -n "${HOZZ_DERIVED:-}" ]]; then
  mkdir -p "$HOZZ_DERIVED/Build/Products/Debug-iphoneos/Hozz.app"
  /usr/bin/python3 - "$HOZZ_DERIVED/Build/Products/Debug-iphoneos/Hozz.app/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump({"CFBundleIdentifier": "com.thatcube.Hozz.fixture"}, output)
PY
fi
case " $* " in
  *" -showBuildSettings "*)
    printf ' BUILT_PRODUCTS_DIR = %s\n' "$ENTRY_ROOT/fake-products"
    ;;
esac
SH

cat > "$ENTRY_BIN/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(find "$APPLE_BUILD_INTERLOCK_TEST_ROOT/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
fd_state=closed
if [[ -e "/dev/fd/$APPLE_BUILD_LEASE_PROOF_FD" ||
      -e "/dev/fd/$APPLE_BUILD_LEASE_LOCK_FD" ]]; then
  fd_state=open
fi
printf 'xcrun|%s|%s|%s|%s\n' \
  "$APPLE_BUILD_LEASE_OWNER" "$count" "$fd_state" "$*" >> "$ENTRY_LOG"
if [[ "$*" == "--sdk iphoneos --show-sdk-path" ]]; then
  printf '%s\n' "$ENTRY_ROOT/fake-sdk"
fi
SH

cat > "$ENTRY_BIN/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH

cat > "$ENTRY_BIN/open" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(find "$APPLE_BUILD_INTERLOCK_TEST_ROOT/leases" \
  -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
printf 'open|%s|%s|%s\n' "$APPLE_BUILD_LEASE_OWNER" "$count" "$*" >> "$ENTRY_LOG"
SH

chmod 755 "$ENTRY_BIN"/*
mkdir -p "$ENTRY_ROOT/fake-sdk/System/Library/Frameworks/HealthKit.framework/Headers"
: > "$ENTRY_ROOT/fake-sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h"
: > "$ENTRY_ROOT/fake-sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKClinicalType.h"
ENTRY_HOME="$(new_home entrypoints)"
ENTRY_ENV=(
  PATH="$ENTRY_BIN:/usr/bin:/bin"
  ENTRY_ROOT="$ENTRY_ROOT"
  ENTRY_LOG="$ENTRY_LOG"
  HOZZ_DERIVED="$ENTRY_ROOT/device-derived"
  HOZZ_MAC_DERIVED="$ENTRY_ROOT/mac-derived"
  HOZZ_SIM_DERIVED="$ENTRY_ROOT/simulator-derived"
  HOZZ_TEST_DERIVED="$ENTRY_ROOT/test-derived"
)

for entrypoint in generate-project.sh simulator-build.sh run-tests.sh device-build.sh mac-build.sh; do
  test_env "$ENTRY_HOME" env "${ENTRY_ENV[@]}" "$ENTRY_ROOT/tools/$entrypoint" \
    >/dev/null
  wait_for_no_records "$ENTRY_HOME"
done
test_env "$ENTRY_HOME" env "${ENTRY_ENV[@]}" \
  "$ENTRY_ROOT/tools/generate-healthkit-catalog.py" >/dev/null
wait_for_no_records "$ENTRY_HOME"
test_env "$ENTRY_HOME" env "${ENTRY_ENV[@]}" \
  "$ENTRY_ROOT/tools/with-apple-build-lease.sh" test/catalog-outer -- \
  "$ENTRY_ROOT/tools/generate-healthkit-catalog.py" >/dev/null
wait_for_no_records "$ENTRY_HOME"

assert_contains "$ENTRY_LOG" "xcodegen|hozz/generate-project|1|generate"
assert_contains "$ENTRY_LOG" "xcodegen|hozz/simulator-build|1|generate"
assert_contains "$ENTRY_LOG" "xcodebuild|hozz/simulator-build|1|"
assert_contains "$ENTRY_LOG" "xcodegen|hozz/run-tests|1|generate"
assert_contains "$ENTRY_LOG" "xcodebuild|hozz/run-tests|1|"
assert_contains "$ENTRY_LOG" "xcodegen|hozz/device-build|1|generate"
assert_contains "$ENTRY_LOG" "xcodebuild|hozz/device-build|1|"
assert_contains "$ENTRY_LOG" "xcrun|hozz/device-build|1|open|devicectl device install app"
assert_contains "$ENTRY_LOG" "xcodegen|hozz/mac-build|1|generate"
assert_contains "$ENTRY_LOG" "xcodebuild|hozz/mac-build|1|"
assert_contains "$ENTRY_LOG" "open|hozz/mac-build|1|"
assert_contains "$ENTRY_LOG" \
  "xcrun|hozz/generate-healthkit-catalog|1|closed|--sdk iphoneos --show-sdk-path"
assert_contains "$ENTRY_LOG" \
  "xcrun|test/catalog-outer|1|closed|--sdk iphoneos --show-sdk-path"

# The Python entrypoint marker cannot bypass descriptor validation.
HOME_FORGED="$(new_home forged-python-entrypoint)"
set +e
test_env "$HOME_FORGED" env HOZZ_CATALOG_BUILD_LEASE_WRAPPED=1 \
  "$ROOT/tools/generate-healthkit-catalog.py" \
  >"$TMP/forged-python.log" 2>&1
FORGED_PYTHON_STATUS=$?
set -e
[[ "$FORGED_PYTHON_STATUS" -ne 0 ]] ||
  fail "Python wrapper marker bypassed inherited lease validation"
assert_contains "$TMP/forged-python.log" \
  "Invalid inherited Apple build lease environment."

# Simultaneous shared owners coexist, while exclusive cleanup refuses.
HOME_SHARED="$(new_home simultaneous-shared)"
SHARED_ONE_READY="$TMP/shared-one.ready"
SHARED_ONE_RELEASE="$TMP/shared-one.release"
SHARED_TWO_READY="$TMP/shared-two.ready"
SHARED_TWO_RELEASE="$TMP/shared-two.release"
start_shared "$HOME_SHARED" test/shared-one "$SHARED_ONE_READY" "$SHARED_ONE_RELEASE"
SHARED_ONE_PID="$LAST_PID"
start_shared "$HOME_SHARED" test/shared-two "$SHARED_TWO_READY" "$SHARED_TWO_RELEASE"
SHARED_TWO_PID="$LAST_PID"
wait_for_file "$SHARED_ONE_READY"
wait_for_file "$SHARED_TWO_READY"
[[ "$(record_count "$HOME_SHARED")" == "2" ]] ||
  fail "concurrent shared owners did not both acquire"
write_rollout "$HOME_SHARED"
if exclusive_probe "$HOME_SHARED"; then
  fail "exclusive cleanup acquired while shared owners were active"
fi
touch "$SHARED_ONE_RELEASE" "$SHARED_TWO_RELEASE"
wait "$SHARED_ONE_PID"
wait "$SHARED_TWO_PID"
wait_for_no_records "$HOME_SHARED"

# A nested shell validates and reuses the inherited descriptor-backed record.
HOME_NESTED="$(new_home nested-shell)"
NESTED_RESULT="$TMP/nested.result"
test_env "$HOME_NESTED" "$WRAPPER" test/outer -- /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/inner
  count=$(find "$HOME/.config/smart-disk-maintenance/apple-build-interlock-v1/leases" \
    -mindepth 1 -maxdepth 1 -type f -name "*.json" | wc -l | tr -d " ")
  printf "%s %s\n" "$APPLE_BUILD_LEASE_LOCAL_ROLE" "$count" > "$2"
  release_apple_build_lease
' _ "$SHELL_LIB" "$NESTED_RESULT"
assert_contains "$NESTED_RESULT" "inherited 1"
wait_for_no_records "$HOME_NESTED"

# Ruby publishes inheritable descriptor metadata to spawned release children.
HOME_RUBY="$(new_home ruby-spawn)"
write_rollout "$HOME_RUBY"
RUBY_READY="$TMP/ruby-child.ready"
RUBY_RELEASE="$TMP/ruby-child.release"
RUBY_PID_FILE="$TMP/ruby-child.pid"
test_env "$HOME_RUBY" ruby -I"$ROOT/tools/lib" -rapple_build_lease -e '
  AppleBuildLease.with_shared("test/ruby-parent") do
    pid = Process.spawn(
      "/bin/sh",
      "-c",
      "touch \"$1\"; while [ ! -e \"$2\" ]; do sleep 0.05; done",
      "_",
      ARGV[0],
      ARGV[1]
    )
    File.write(ARGV[2], "#{pid}\n")
    Process.detach(pid)
  end
' "$RUBY_READY" "$RUBY_RELEASE" "$RUBY_PID_FILE"
wait_for_file "$RUBY_READY"
RUBY_PID="$(cat "$RUBY_PID_FILE")"
FIXTURE_PIDS+=("$RUBY_PID")
if exclusive_probe "$HOME_RUBY"; then
  fail "Ruby parent release dropped the lease while its child was active"
fi
touch "$RUBY_RELEASE"
wait_for_no_records "$HOME_RUBY"

# A hard-crashed fixture leaves durable evidence and keeps cleanup denied.
HOME_CRASH="$(new_home crash-record)"
write_rollout "$HOME_CRASH"
CRASH_READY="$TMP/crash.ready"
test_env "$HOME_CRASH" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/crashed
  touch "$2"
  while :; do sleep 0.05; done
' _ "$SHELL_LIB" "$CRASH_READY" >/dev/null 2>&1 &
CRASH_PID=$!
FIXTURE_PIDS+=("$CRASH_PID")
wait_for_file "$CRASH_READY"
kill -KILL "$CRASH_PID"
wait "$CRASH_PID" 2>/dev/null || true
sleep 0.1
[[ "$(record_count "$HOME_CRASH")" == "1" ]] ||
  fail "crashed shared owner did not retain durable evidence"
if exclusive_probe "$HOME_CRASH"; then
  fail "crash evidence was mistaken for cleanup permission"
fi

echo "Hozz Apple build interlock tests passed"
