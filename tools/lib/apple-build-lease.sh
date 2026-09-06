#!/usr/bin/env bash
#
# Shared shell client for the host-wide Apple build/cleanup interlock.
#
# FDs 8 and 9 are inherited capabilities:
#   8 = unlinked per-lease proof file
#   9 = the kernel-flocked coordination file
# Exclusive maintenance also inherits:
#   6 = policy-update lock (shared for the full cleanup lane)
#   7 = verified rollout policy file
#
# Invalid inherited metadata is a hard failure. It never falls back to a fresh
# lease, because that would let a stale or forged environment skip ownership.

APPLE_BUILD_LEASE_SOURCE="${BASH_SOURCE[0]:-$0}"
APPLE_BUILD_LEASE_HELPER_DIR="$(
  cd "${APPLE_BUILD_LEASE_SOURCE%/*}" >/dev/null 2>&1 && pwd -P
)"
APPLE_BUILD_LEASE_PY="$APPLE_BUILD_LEASE_HELPER_DIR/apple_build_lease.py"
APPLE_BUILD_LEASE_ROOT=""
APPLE_BUILD_LEASE_ROLLOUT=""

if ! command -v apple_build_lease_log >/dev/null 2>&1; then
  apple_build_lease_log() {
    printf '%s\n' "$*" >&2
  }
fi

_apple_build_lease_valid_fd() {
  case "${1:-}" in
    [3-9]|[1-9][0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

_apple_build_lease_close_fd() {
  local fd="${1:-}"
  _apple_build_lease_valid_fd "$fd" || return 0
  eval "exec ${fd}>&-" 2>/dev/null || true
}

_apple_build_lease_close_fds() {
  _apple_build_lease_close_fd "${APPLE_BUILD_LEASE_POLICY_LOCK_FD:-}"
  _apple_build_lease_close_fd "${APPLE_BUILD_LEASE_ROLLOUT_FD:-}"
  _apple_build_lease_close_fd "${APPLE_BUILD_LEASE_PROOF_FD:-}"
  _apple_build_lease_close_fd "${APPLE_BUILD_LEASE_LOCK_FD:-}"
}

_apple_build_lease_clear_environment() {
  unset APPLE_BUILD_LEASE_PROTOCOL
  unset APPLE_BUILD_LEASE_MODE
  unset APPLE_BUILD_LEASE_OWNER
  unset APPLE_BUILD_LEASE_ID
  unset APPLE_BUILD_LEASE_TOKEN
  unset APPLE_BUILD_LEASE_PROOF_FD
  unset APPLE_BUILD_LEASE_LOCK_FD
  unset APPLE_BUILD_LEASE_POLICY_LOCK_FD
  unset APPLE_BUILD_LEASE_ROLLOUT_FD
  APPLE_BUILD_LEASE_LOCAL_DEPTH=0
  APPLE_BUILD_LEASE_LOCAL_ROLE=""
  APPLE_BUILD_LEASE_LOCAL_MODE=""
  APPLE_BUILD_LEASE_VALIDATED_ROLE=""
}

_apple_build_lease_has_environment() {
  [ -n "${APPLE_BUILD_LEASE_PROTOCOL:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_MODE:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_OWNER:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_ID:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_TOKEN:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_PROOF_FD:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_LOCK_FD:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_POLICY_LOCK_FD:-}" ] ||
    [ -n "${APPLE_BUILD_LEASE_ROLLOUT_FD:-}" ]
}

_apple_build_lease_resolve_paths() {
  APPLE_BUILD_LEASE_ROOT="$(
    /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" path root
  )" || return $?
  APPLE_BUILD_LEASE_ROLLOUT="$(
    /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" path rollout
  )" || return $?
}

_apple_build_lease_validate() {
  local requested_mode="$1" status role
  if [ "${APPLE_BUILD_LEASE_PROTOCOL:-}" != "1" ] ||
     [ -z "${APPLE_BUILD_LEASE_MODE:-}" ] ||
     [ -z "${APPLE_BUILD_LEASE_OWNER:-}" ] ||
     [ -z "${APPLE_BUILD_LEASE_ID:-}" ] ||
     [ -z "${APPLE_BUILD_LEASE_TOKEN:-}" ] ||
     [ -z "${APPLE_BUILD_LEASE_PROOF_FD:-}" ] ||
     [ -z "${APPLE_BUILD_LEASE_LOCK_FD:-}" ]; then
    apple_build_lease_log "apple-build-interlock: incomplete inherited lease environment"
    return 75
  fi
  if ! _apple_build_lease_valid_fd "$APPLE_BUILD_LEASE_PROOF_FD" ||
     ! _apple_build_lease_valid_fd "$APPLE_BUILD_LEASE_LOCK_FD" ||
     [ "$APPLE_BUILD_LEASE_PROOF_FD" = "$APPLE_BUILD_LEASE_LOCK_FD" ]; then
    apple_build_lease_log "apple-build-interlock: invalid inherited lease descriptors"
    return 75
  fi
  if [ "$APPLE_BUILD_LEASE_MODE" != "$requested_mode" ]; then
    apple_build_lease_log \
      "apple-build-interlock: inherited $APPLE_BUILD_LEASE_MODE lease cannot satisfy requested $requested_mode lease"
    return 75
  fi

  if [ "$requested_mode" = "exclusive" ]; then
    if ! _apple_build_lease_valid_fd "${APPLE_BUILD_LEASE_POLICY_LOCK_FD:-}" ||
       ! _apple_build_lease_valid_fd "${APPLE_BUILD_LEASE_ROLLOUT_FD:-}"; then
      apple_build_lease_log "apple-build-interlock: invalid inherited policy descriptors"
      return 75
    fi
    if /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" validate \
        --mode "$APPLE_BUILD_LEASE_MODE" \
        --owner "$APPLE_BUILD_LEASE_OWNER" \
        --lease-id "$APPLE_BUILD_LEASE_ID" \
        --token "$APPLE_BUILD_LEASE_TOKEN" \
        --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
        --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" \
        --policy-lock-fd "$APPLE_BUILD_LEASE_POLICY_LOCK_FD" \
        --rollout-fd "$APPLE_BUILD_LEASE_ROLLOUT_FD" \
        --role-exit-code; then
      role="owner"
    else
      status=$?
      [ "$status" -eq 10 ] || return "$status"
      role="inherited"
    fi
  else
    if [ -n "${APPLE_BUILD_LEASE_POLICY_LOCK_FD:-}" ] ||
       [ -n "${APPLE_BUILD_LEASE_ROLLOUT_FD:-}" ]; then
      apple_build_lease_log "apple-build-interlock: shared lease carries policy descriptors"
      return 75
    fi
    if /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" validate \
        --mode "$APPLE_BUILD_LEASE_MODE" \
        --owner "$APPLE_BUILD_LEASE_OWNER" \
        --lease-id "$APPLE_BUILD_LEASE_ID" \
        --token "$APPLE_BUILD_LEASE_TOKEN" \
        --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
        --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" \
        --role-exit-code; then
      role="owner"
    else
      status=$?
      [ "$status" -eq 10 ] || return "$status"
      role="inherited"
    fi
  fi
  case "$role" in
    owner|inherited) APPLE_BUILD_LEASE_VALIDATED_ROLE="$role" ;;
    *)
      apple_build_lease_log "apple-build-interlock: invalid lease validation response"
      return 75
      ;;
  esac
}

acquire_apple_build_lease() {
  local mode="$1" owner="$2" role proof

  if _apple_build_lease_has_environment; then
    _apple_build_lease_validate "$mode" || return $?
    role="$APPLE_BUILD_LEASE_VALIDATED_ROLE"
    if [ "${APPLE_BUILD_LEASE_LOCAL_ROLE:-}" = "$role" ] &&
       [ "${APPLE_BUILD_LEASE_LOCAL_MODE:-}" = "$mode" ] &&
       [ "${APPLE_BUILD_LEASE_LOCAL_DEPTH:-0}" -gt 0 ] 2>/dev/null; then
      APPLE_BUILD_LEASE_LOCAL_DEPTH=$((APPLE_BUILD_LEASE_LOCAL_DEPTH + 1))
    else
      APPLE_BUILD_LEASE_LOCAL_DEPTH=1
      APPLE_BUILD_LEASE_LOCAL_ROLE="$role"
      APPLE_BUILD_LEASE_LOCAL_MODE="$mode"
    fi
    return 0
  fi

  case "$mode" in
    shared|exclusive) ;;
    *) apple_build_lease_log "apple-build-interlock: invalid lease mode: $mode"; return 75 ;;
  esac

  _apple_build_lease_resolve_paths || return $?
  /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" prepare || return $?
  APPLE_BUILD_LEASE_PROOF_FD=8
  APPLE_BUILD_LEASE_LOCK_FD=9
  if [ "$mode" = "exclusive" ]; then
    APPLE_BUILD_LEASE_POLICY_LOCK_FD=6
    APPLE_BUILD_LEASE_ROLLOUT_FD=7
  else
    unset APPLE_BUILD_LEASE_POLICY_LOCK_FD APPLE_BUILD_LEASE_ROLLOUT_FD
  fi
  proof="$(/usr/bin/mktemp "$APPLE_BUILD_LEASE_ROOT/proof.XXXXXX")" || {
    apple_build_lease_log "apple-build-interlock: cannot create lease proof"
    return 75
  }
  chmod 600 "$proof" || {
    rm -f "$proof"
    apple_build_lease_log "apple-build-interlock: cannot secure lease proof"
    return 75
  }
  if ! exec 8<>"$proof"; then
    rm -f "$proof"
    apple_build_lease_log "apple-build-interlock: cannot open lease proof"
    return 75
  fi
  rm -f "$proof"
  if ! exec 9>>"$APPLE_BUILD_LEASE_ROOT/coordination.lock"; then
    _apple_build_lease_close_fds
    apple_build_lease_log "apple-build-interlock: cannot open coordination lock"
    return 75
  fi

  if [ "$mode" = "exclusive" ]; then
    if ! /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" suspension-check; then
      _apple_build_lease_close_fds
      return 75
    fi
    if ! exec 6>>"$APPLE_BUILD_LEASE_ROOT/policy.lock"; then
      _apple_build_lease_close_fds
      apple_build_lease_log "apple-build-interlock: cannot open maintenance policy lock"
      return 75
    fi
    if ! exec 7<"$APPLE_BUILD_LEASE_ROLLOUT"; then
      _apple_build_lease_close_fds
      apple_build_lease_log \
        "apple-build-interlock: rollout policy missing; destructive maintenance remains disabled"
      return 75
    fi
  fi

  APPLE_BUILD_LEASE_PROTOCOL=1
  APPLE_BUILD_LEASE_MODE="$mode"
  APPLE_BUILD_LEASE_OWNER="$owner"
  APPLE_BUILD_LEASE_ID="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
  APPLE_BUILD_LEASE_TOKEN="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
  export APPLE_BUILD_LEASE_PROTOCOL APPLE_BUILD_LEASE_MODE
  export APPLE_BUILD_LEASE_OWNER APPLE_BUILD_LEASE_ID APPLE_BUILD_LEASE_TOKEN
  export APPLE_BUILD_LEASE_PROOF_FD APPLE_BUILD_LEASE_LOCK_FD
  if [ "$mode" = "exclusive" ]; then
    export APPLE_BUILD_LEASE_POLICY_LOCK_FD APPLE_BUILD_LEASE_ROLLOUT_FD
  fi

  if [ "$mode" = "exclusive" ]; then
    /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" acquire \
      --mode "$mode" --owner "$owner" \
      --lease-id "$APPLE_BUILD_LEASE_ID" --token "$APPLE_BUILD_LEASE_TOKEN" \
      --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
      --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" \
      --policy-lock-fd "$APPLE_BUILD_LEASE_POLICY_LOCK_FD" \
      --rollout-fd "$APPLE_BUILD_LEASE_ROLLOUT_FD" || {
        _apple_build_lease_close_fds
        _apple_build_lease_clear_environment
        return 75
      }
  else
    /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" acquire \
      --mode "$mode" --owner "$owner" \
      --lease-id "$APPLE_BUILD_LEASE_ID" --token "$APPLE_BUILD_LEASE_TOKEN" \
      --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
      --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" || {
        _apple_build_lease_close_fds
        _apple_build_lease_clear_environment
        return 75
      }
  fi

  APPLE_BUILD_LEASE_LOCAL_DEPTH=1
  APPLE_BUILD_LEASE_LOCAL_ROLE="owner"
  APPLE_BUILD_LEASE_LOCAL_MODE="$mode"
}

acquire_apple_build_shared_lease() {
  acquire_apple_build_lease shared "$1"
}

acquire_apple_build_exclusive_lease() {
  acquire_apple_build_lease exclusive "$1"
}

verify_apple_build_lease() {
  local requested_mode="${1:-${APPLE_BUILD_LEASE_MODE:-}}"
  _apple_build_lease_validate "$requested_mode"
}

release_apple_build_lease() {
  local status=0
  [ "${APPLE_BUILD_LEASE_LOCAL_DEPTH:-0}" -gt 0 ] 2>/dev/null || return 0
  if [ "$APPLE_BUILD_LEASE_LOCAL_DEPTH" -gt 1 ]; then
    APPLE_BUILD_LEASE_LOCAL_DEPTH=$((APPLE_BUILD_LEASE_LOCAL_DEPTH - 1))
    return 0
  fi

  if [ "${APPLE_BUILD_LEASE_LOCAL_ROLE:-}" = "owner" ]; then
    if [ "$APPLE_BUILD_LEASE_MODE" = "exclusive" ]; then
      /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" request-release \
        --mode "$APPLE_BUILD_LEASE_MODE" \
        --owner "$APPLE_BUILD_LEASE_OWNER" \
        --lease-id "$APPLE_BUILD_LEASE_ID" \
        --token "$APPLE_BUILD_LEASE_TOKEN" \
        --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
        --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" \
        --policy-lock-fd "$APPLE_BUILD_LEASE_POLICY_LOCK_FD" \
        --rollout-fd "$APPLE_BUILD_LEASE_ROLLOUT_FD" || status=$?
    else
      /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" request-release \
        --mode "$APPLE_BUILD_LEASE_MODE" \
        --owner "$APPLE_BUILD_LEASE_OWNER" \
        --lease-id "$APPLE_BUILD_LEASE_ID" \
        --token "$APPLE_BUILD_LEASE_TOKEN" \
        --lock-fd "$APPLE_BUILD_LEASE_LOCK_FD" \
        --proof-fd "$APPLE_BUILD_LEASE_PROOF_FD" || status=$?
    fi

    if [ "$status" -eq 0 ]; then
      /usr/bin/python3 "$APPLE_BUILD_LEASE_PY" finalize-release \
        --mode "$APPLE_BUILD_LEASE_MODE" \
        --lease-id "$APPLE_BUILD_LEASE_ID" \
        --token "$APPLE_BUILD_LEASE_TOKEN" \
        </dev/null >/dev/null 2>&1 6>&- 7>&- 8>&- 9>&- &
    else
      apple_build_lease_log \
        "apple-build-interlock: could not record clean release; durable lease evidence retained"
    fi
  fi

  _apple_build_lease_close_fds
  _apple_build_lease_clear_environment
  return "$status"
}

abandon_apple_build_lease() {
  [ "${APPLE_BUILD_LEASE_LOCAL_DEPTH:-0}" -gt 0 ] 2>/dev/null || return 0
  _apple_build_lease_close_fds
  _apple_build_lease_clear_environment
}

apple_build_lease_signal_exit() {
  APPLE_BUILD_LEASE_SIGNALLED=1
  exit "$1"
}

apple_build_lease_default_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "${APPLE_BUILD_LEASE_SIGNALLED:-0}" -eq 1 ] || [ "$status" -ne 0 ]; then
    abandon_apple_build_lease
  elif ! release_apple_build_lease; then
    status=75
  fi
  exit "$status"
}

install_apple_build_lease_traps() {
  APPLE_BUILD_LEASE_SIGNALLED=0
  trap 'apple_build_lease_signal_exit 129' HUP
  trap 'apple_build_lease_signal_exit 130' INT
  trap 'apple_build_lease_signal_exit 143' TERM
  trap apple_build_lease_default_exit EXIT
}
