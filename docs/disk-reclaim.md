# Apple build and cleanup interlock

Hozz participates in the same machine-wide Apple build/cleanup interlock as the
other Apple applications on this host. Build tooling takes a shared lease before
XcodeGen or Xcode can write developer resources. Destructive maintenance must
take the conflicting exclusive lease and remains disabled until the separate
machine-wide rollout is complete.

## Protocol provenance

The protocol clients in this repository are byte-for-byte copies of these files
from the frozen Plozz tree at commit `b1d24c0` (interlock implementation
`5407b2508`):

- `tools/lib/apple-build-lease.sh`
- `tools/lib/apple_build_lease.py`
- `tools/lib/apple_build_lease.rb`
- `tools/with-apple-build-lease.sh`

Hozz has no runtime dependency on a Plozz checkout. Keeping the clients
identical is intentional: every participating repository must use the same
descriptor inheritance, durable record, and fail-closed validation protocol.

## Current rollout status: destructive cleanup disabled

The frozen protocol's rollout schema does not yet name Hozz. This repository
does not change that schema, remove
`~/.config/smart-disk-maintenance/SUSPENDED`, create or rewrite the rollout
policy, enable a scheduler, or authorize cleanup. Hozz's writer port is one
input to that later coordinated policy update, not evidence that the global
rollout is ready.

Broad cleanup must remain disabled while any of these are true:

- Hozz is absent from the machine-wide rollout policy;
- the primary checkout or a linked Hozz worktree can still run pre-interlock
  tooling;
- direct Xcode, raw `xcodebuild`/`xcodegen`, or a third-party Apple build tool
  can write outside a lease;
- another Apple application's current or legacy writers are not covered;
- global cleanup entrypoints and policy writers have not completed their own
  fail-closed integration.

Hozz contains no build-cache deletion entrypoint. This change does not add one,
and the shared lease does not make any cache, archive, dSYM, dependency,
toolchain, simulator, worktree, or release evidence eligible for deletion.

## Hozz writer coverage

The current branch acquires a shared lease before its first relevant write and
holds it through the complete lane:

- `tools/generate-project.sh` for XcodeGen project generation;
- `tools/simulator-build.sh` for generation and simulator compilation;
- `tools/run-tests.sh` for generation and XCTest;
- `tools/device-build.sh` for signing configuration, generation, device build,
  and installation;
- `tools/mac-build.sh` for signing configuration, generation, Mac build,
  build-setting lookup, and the optional launch/relaunch step;
- `tools/generate-healthkit-catalog.py` for the complete SDK-read and generated
  source-write lane;
- `tools/with-apple-build-lease.sh` for unusual direct commands.

Nested scripts validate and reuse the inherited descriptor-backed lease instead
of publishing a second record. The device, Mac, simulator, and test lanes
therefore keep one outer lease across their project-generation child.

The HealthKit catalog generator validates inherited lease descriptors with an
explicit `pass_fds` allowlist before it reads the SDK. Its `xcrun` child does not
inherit those descriptors because the parent remains alive and retains the
lease for the blocking SDK lookup and subsequent generated-source write. No
Python build wrapper uses a blanket `close_fds=False`.

There is currently no Fastlane configuration or CI workflow in Hozz. If either
is added, its outer release/build lane must acquire the same shared protocol
before its first Apple-resource write and retain it across archive, upload,
processing, distribution, and tagging gaps.

## Protocol behavior

The same-user namespace is physically resolved from the effective UID's account
record:

```text
~/.config/smart-disk-maintenance/apple-build-interlock-v1/
```

Shared build leases may coexist. Exclusive cleanup refuses immediately while a
shared lease is active, and new cooperative builds wait while an exclusive
owner holds the lock. Shell and Ruby clients retain the kernel-flocked file
descriptor and pass authenticated descriptor identity to descendants.

Normal completion records a release request and starts a finalizer that waits
for inherited children to close the descriptor before removing durable lease
evidence. Failed commands, signals, hard crashes, malformed records, replaced
lock files, or finalizer failures retain evidence. Cleanup must fail closed; it
must not infer safety from PID age, an empty process list, or a quiet machine.
There is deliberately no automatic stale-record deletion.

Inspect production records without changing them:

```bash
/usr/bin/python3 tools/lib/apple_build_lease.py inspect
```

## Fixture tests

The interlock regression test uses only private temporary HOME and lock roots.
It does not invoke Xcode, XcodeGen, SwiftPM, a simulator, a device, a release
lane, or a real cleanup entrypoint:

```bash
tools/tests/test-apple-build-interlock.sh
```

It covers helper provenance, current entrypoint coverage, simultaneous shared
owners, nonblocking exclusive refusal, nested shell inheritance, Ruby-spawned
child inheritance, Python re-exec validation with an explicit descriptor
allowlist, closed descriptors in the `xcrun` child, and durable crash evidence.
