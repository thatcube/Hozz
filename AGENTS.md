# Hozz contributor notes

Hozz moves someone's health data to somewhere they own. Almost everything that
matters follows from two things: tell the truth about what happened, and do not
lose records.

Nothing below is a rule for its own sake. If something here makes the app worse,
change it and say why in the commit.

## What Hozz is

Free and open source. No subscription, account, advertising, analytics, or
server the maintainer runs. There is nothing to sign up for and nothing phoning
home, and that is the reason to choose it over the alternatives.

Nothing leaves the device until someone adds a destination and confirms it.
Hozz ships with no default destination and never picks one on a user's behalf.

## Tell the truth

Report what actually happened. If a read failed, a type is unavailable, or
permission was refused, say so plainly rather than reporting success.

Do not manufacture alarm either. A type with no records exported nothing, which
is a complete and successful export, not a warning. Save attention states for
things a person can act on.

## Do not lose records

Acquisition uses opaque, type-scoped, device-local anchors, never date windows.
Health accepts samples written retroactively, so a date cursor silently skips
them.

An anchor may only advance inside the same store transaction that seals the part
holding its bytes. An unsealed part is discarded on relaunch and its work
replays. Interruption is the normal case — phones get locked, backgrounded, and
killed constantly — so resuming correctly matters more than finishing quickly.

The phone keeps a bounded spool rather than a second copy of Health history; the
Mac receiver is where an archive accumulates. Adding a permanent phone-side
mirror is a real design change, not a tweak.

Test the paths that lose or duplicate records: transaction boundaries,
cancellation, retries, tombstones, and deterministic encoding.

## Secrets

Destination credentials live in the device Keychain, never in a file, a log, or
this repository. The Mac receiver token deliberately syncs through the user's
own iCloud Keychain so a phone and Mac on the same Apple ID pair without anyone
copying a token by hand. Both are fine: in each case the secret only ever rests
somewhere the user owns.

Logs and diagnostics carry statuses and failure states, never sample values,
credentials, or destination secrets — not even in a response body echoed back
from a server.

Never commit signing credentials, App Store Connect keys, `.env` files, or the
generated Xcode project.

## Build and test

```bash
xcodegen generate
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`tools/device-build.sh` builds and installs on a connected iPhone, and
`tools/mac-build.sh` builds the Mac app. The README covers signing, the App
Group the widget needs, and two macOS networking traps that are invisible from
the code and cost days each.

## Do not believe a red build until you have ruled these out

Both of these produce failures that look exactly like a broken `main`, and both
have already sent someone chasing a regression that was not there.

**Regenerate after changing branch.** The project file is generated and
gitignored, so a `git checkout` or `git reset --hard` brings in source files the
`.xcodeproj` has never heard of. The result is a pile of errors in a module you
did not touch. Run `xcodegen generate` first, every time.

**Use your own derived data.** Sharing DerivedData between worktrees mixes a
stale app binary with a freshly built framework, and dyld reports a missing
symbol for a function that exists and compiles:

```
dyld: Symbol not found: _$s11HozzDeliver10UnitFamilyO10settingKeySSvg
```

Pass `-derivedDataPath /tmp/something-of-your-own`. The same sharing makes the
simulator wedge with `Test crashed with signal kill before establishing
connection`.

## A green build is not a working app

Three times now something has passed every test and been broken on a device: a
framework that linked but was never embedded, a string concatenation the
compiler type-checked on the simulator and gave up on for the device, and a
HealthKit authorization request that raises rather than being refused. The
tests drive a fake data source, so they cannot see any of it.

Build for a device and run the thing before saying it works. When it dies,
`xcrun devicectl device process launch --console` names the reason in seconds —
which is worth more than an hour of reasoning about what it might be.
