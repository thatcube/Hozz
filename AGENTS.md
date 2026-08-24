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

Do not believe a red build until you have regenerated the project and used a
derived data path of your own. Two of the three "broken build" scares in one
night were the tooling rather than the code, and both looked exactly like a
genuine regression:

- The `.xcodeproj` is generated and gitignored, so changing branch brings in
  source files it does not know about. That surfaces as `cannot find type in
  scope` across a module you never touched — 26 errors in `HozzDeliver` on one
  occasion — and reads as a broken `main`. Run `xcodegen generate` after any
  branch change, and after adding a file of your own.
- DerivedData shared between two checkouts of the same project mixes a stale
  app binary with a freshly built framework, which fails at launch as
  `dyld: Symbol not found` for a symbol that does exist. Pass
  `-derivedDataPath` somewhere of your own, and use a simulator nothing else
  is installing to.

A green build is not a working app, and a green test run is not even a building
one. The tests build for a simulator; a phone builds a different product, and
the compiler's patience is not the same in both. A `Text(...)` holding a ternary
inside a chain of `+` once type-checked in seconds for the simulator and timed
out compiling for a device — 1,035 tests passing while the app could not be
installed at all. No amount of running the tests could have found it. Build for
the device before handing work over; it costs ninety seconds.

Run anything that touches the clock more than once. Four separate defects in a
single day shared one shape: a plausible result, no error path, and a symptom
that appears only under a condition nobody varied — a server left running from
another checkout, an abandoned history behind a force-push, a sub-millisecond
remainder that survives formatting, and the hour of the day. `-test-iterations`
catches the repeatable ones; a suite that passes in the morning and fails at
seven in the evening will otherwise be blamed on whatever was merged last. The
rest are caught only by measuring an explanation instead of trusting it,
including your own.
