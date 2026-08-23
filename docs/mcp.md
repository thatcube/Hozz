# The Hozz MCP server

A read-only MCP server over the Health data your phone has delivered to your
Mac. It speaks JSON-RPC 2.0 over stdio, advertises protocol version
`2024-11-05`, and identifies itself as `hozz` version `1.0.0`.

## Why this one is different

Most Apple Health MCP servers read the bulk XML file you get from Health's
**Export All Health Data** button. That file is a snapshot: it is correct on the
day you export it and stale from the next morning, it takes minutes to produce,
and it is often hundreds of megabytes of XML that has to be parsed in full
before any question can be answered.

Hozz queries a local SQLite database that your phone keeps current in the
background. Asking a question costs an indexed lookup rather than a re-parse,
the answer reflects what arrived this morning, and nothing had to be exported by
hand. That is an architectural difference rather than a feature, and it is the
main reason to choose this one.

It is read-only by construction. The server can select from the received
database; it has no code path that writes, changes, or deletes anything.

## Setting it up

The tool ships inside the Mac app:

```text
/Applications/Hozz.app/Contents/MacOS/hozz-mcp
```

It has to be told where the received database is. The Mac app is sandboxed while
your assistant launches `hozz-mcp` outside that sandbox, so a guessed path opens
an empty directory and every tool truthfully reports no data. **Open the Mac
app's Assistant tab and copy the configuration it generates** rather than typing
one.

### Let your assistant do it

Every client keeps its MCP configuration somewhere different and in a slightly
different shape, which is a tedious thing to document and an easy thing to get
wrong. Your assistant already knows where its own configuration lives, so paste
this to it instead:

```text
Please add a local MCP server called "hozz" to your own MCP configuration.

It runs this command:
  /Applications/Hozz.app/Contents/MacOS/hozz-mcp

with these arguments:
  --data-dir
  /Users/YOUR_USERNAME/Library/Containers/com.thatcube.Hozz.mac/Data/Library/Application Support/Hozz/Received

Replace YOUR_USERNAME with my actual username. That path is real and contains a
space in "Application Support", so keep it as one argument rather than splitting
it. It is a stdio server speaking JSON-RPC, not an HTTP one, so it needs no URL,
port, or token.

Write it into whichever configuration file you actually read, in whatever shape
that file expects, and leave any servers already in there alone. Please back the
file up first. Then tell me whether I need to restart you for it to load.

You can check it works before I restart by running the command yourself with
those arguments and sending it this on stdin:
  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
  {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
It should answer with thirteen tools. If it says there is no received data,
Hozz has not synced to this Mac yet, which is a different problem from the
configuration being wrong.
```

That works because the server needs so little: a path, an argument, and stdio.
There is no account to create, no key to paste, and nothing to reach over a
network.

### Writing it by hand

If you would rather do it yourself, the shape most clients want is:

```json
{
  "mcpServers": {
    "hozz": {
      "command": "/Applications/Hozz.app/Contents/MacOS/hozz-mcp",
      "args": [
        "--data-dir",
        "/Users/you/Library/Containers/com.thatcube.Hozz.mac/Data/Library/Application Support/Hozz/Received"
      ]
    }
  }
}
```

Some clients want extra keys alongside those — GitHub Copilot's CLI, for
instance, keeps its servers in `~/.copilot/mcp-config.json` and expects
`"type": "local"` and a `"tools"` list on each entry. Check what the other
entries in your own file look like and match them; the `command` and `args` are
the part that is always the same.

`HOZZ_DATA_DIR` works instead of `--data-dir` if your client prefers an
environment variable.

### If it reports no data

Two different problems look identical from the client:

- **The path is wrong.** A sandboxed Mac app keeps its database inside its
  container, and the path above is that container. Pointing at
  `~/Library/Application Support/Hozz` instead finds nothing, because that is
  where an unsandboxed build would have put it.
- **Nothing has arrived yet.** Open Hozz on the Mac, connect your phone, and let
  it sync at least once. The Mac's Data tab says how many types have arrived.

The tools distinguish these where they can: a type with no records in your
window says so, rather than claiming you have no such data.

One thing worth understanding before you connect it: if you point a
cloud-hosted assistant at this server, that assistant may upload whatever it
reads. That is the assistant's behaviour, not Hozz's, and no local server can
prevent it.

## The tools

### Orientation

| Tool | Answers |
| --- | --- |
| `summarise_health_data` | What is here at all: record count, types, date range, the largest types, and the person's own characteristics. |
| `list_health_types` | Which types have arrived, with counts and date ranges. |

**Call `summarise_health_data` first.** It returns age, biological sex, blood
type and the rest where they have been shared, and reference ranges depend on
them: a resting heart rate of 48 is unremarkable at 34 and worth a question at
70. Those characteristics are deliberately part of the overview rather than a
tool of their own, because an assistant that has to make a second optional call
will sometimes not make it, and answering "is this normal for me" without
knowing who *me* is the failure worth designing against.

### Retrieval

| Tool | Answers |
| --- | --- |
| `aggregate_health_data` | One type bucketed by hour, day, week or month, with sum, average, minimum, maximum and count per bucket. |
| `list_health_samples` | Individual samples, when the readings themselves matter. |
| `list_electrocardiograms` | Every ECG reading, with what the Watch classified it as, average heart rate, symptom status, and whether the full waveform has arrived. |
| `get_electrocardiogram_voltages` | One reading's waveform as time/volt pairs. |
| `list_audiograms` | Hearing tests, with the threshold at each frequency for each ear. |
| `list_mood_entries` | State of Mind entries with their classification, kind, labels and associations. |
| `summarise_medication_adherence` | Dose events per medicine, counted by status. |
| `list_workouts` | Workouts with what Health computed about each: heart rate, energy, distance, and each leg of a multi-sport workout separately. |

A workout keeps its sample row too, with its **duration** as the value, so "how
long do I work out" charts like anything else — dropping it would have hidden
workouts from the type list altogether. What Health computed about how it went
lives alongside. A figure Health did not compute is omitted rather than shown as
zero, because a zero average heart rate reads as a measurement.

Mood is also an ordinary chartable type: its valence lands in `sample` as a real
value, so `aggregate_health_data`, `analyse_health_trend` and
`compare_health_types` all work on it. "Has my mood been declining" is a trend
question, and it is answered by the trend tool with the same honesty gates as
anything else. Use `list_mood_entries` when the labels and associations matter.

Medication doses are the opposite: a dose has no number to chart, its answer is
a status, and **only `taken` means the medicine was taken**. `skipped`,
`snoozed` and `notAnswered` are three different ways of not taking it and are
always reported separately. Never collapse them into one adherence figure, and
never read a never-answered dose as evidence either way. An unrecognised status
is reported as `unrecorded` rather than guessed at, because every guess there is
a claim about whether someone took their medicine.

`aggregate_health_data` returns both sum and average rather than one "value",
because which is correct depends entirely on the type. Summing heart rates is
meaningless; averaging step counts understates a day. Hiding one of them would
invite a confidently wrong answer.

ECGs and hearing tests are **not** ordinary samples and do not appear in
`list_health_samples`. That is deliberate: an ECG has no single value, and its
voltage pages are not readings, so storing them generically made "how many ECGs
do I have" answer 2 for one reading and made the classification invisible.

### Analysis

| Tool | Answers |
| --- | --- |
| `analyse_health_trend` | Is this drifting up or down, and can that be said at all? |
| `compare_health_types` | Do these two move together day to day? |
| `find_health_anomalies` | Did anything genuinely unusual happen? |

## What the analysis tools refuse to say

This section is the point of the analysis tools, not a caveat attached to them.

Their output goes straight into a language model, which will narrate a confident
story around any number handed to it. A slope with no uncertainty becomes "your
heart rate is climbing". A correlation over three weeks of daily data becomes
"your sleep drives your step count". Neither is supportable, and a health tool
asserting them is not merely unhelpful — it is the kind of confident wrongness
someone might act on.

So each tool reports whether a claim is supportable alongside the number, and
says plainly when it is not.

**A trend needs at least 14 days.** Below that it returns nothing but the
refusal: a line fitted through nine days describes the noise.

**A trend whose confidence interval spans zero is reported as "no detectable
change"**, and the text says not to describe it as rising or falling. This
matters more than it sounds. A genuinely flat step count still fits a slope of
about −26 steps per week; handed that number bare, an assistant reports a
decline that is not there.

**A correlation needs at least 28 shared days**, and its interval is computed on
an *autocorrelation-adjusted* sample size. Consecutive days are not independent
evidence — today's step count resembles yesterday's — and treating a hundred
similar days as a hundred observations is exactly what turns three weeks of data
into false certainty.

**A correlation warns when both series are trending.** Two quantities that both
drift across a year will correlate strongly whether or not they have anything to
do with each other, and that is the single most common way this kind of number
misleads.

**No correlation is ever described as cause.** Every response says so.

**Anomalies use the median and median absolute deviation**, not the mean and
standard deviation, so a single extreme day cannot inflate the spread and hide
the ordinary-looking outliers beside it.

**A day with too few records is not judged.** It is reported separately as the
device most likely not being worn, and explicitly as *missing measurements, not
low readings*. A stray reading of 31 bpm on a day the watch was off is
indistinguishable from a collapsed heart rate to any detector that ignores how
much was recorded, and reporting it as a collapse would be alarming and wrong.

**A type that has not synced yet says so.** Your phone works through your types
a share at a time, so a type with no data is usually one the backfill has not
reached rather than one you have none of. The tools answer "this has not reached
this Mac yet — it is not evidence that you have no such data" and list what has
arrived, rather than returning zero or an error.

The analysis tools deliberately do **not** repeat the person's characteristics.
None of them uses age in its computation — a trend is a trend regardless — so
surfacing age there would imply an age-adjusted clinical judgement that is not
being made. The context belongs in the overview; the analysis stays descriptive.

## What it will not do

The server cannot write to Apple Health, and neither can the rest of Hozz. That
is a decision rather than a missing feature, and the reasoning is in the
README's **Why Hozz does not write back into Apple Health**.
