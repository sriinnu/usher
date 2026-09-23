# When Usher asks again

Catch-up runs at launch and every 30 minutes over watched folders. For each
file it asks: is there a reason to think Jev would answer differently now? If
not, nothing is sent.

## The fingerprint

Every journal entry is stamped with a short hash of everything that can change
Jev's **answer**:

- `routes.json` and `rules.json`
- the privacy lists and the count of personal identifiers (never their values)
- the model name
- `ConfigFingerprint.logicVersion`

**`logicVersion` is bumped by hand** whenever a change to evidence extraction,
the questions, the name candidates or the rules engine could change an answer.
It replaced the binary's modification time, which changed on every rebuild:
a README edit made every unresolved file look new, and each rebuild re-sent
them all.

## Answered or not

| Last outcome | Asked again when |
| --- | --- |
| filed, waiting on you, duplicate, already filed, binned | never |
| undone move | the fingerprint changes |
| never classified (floored) | the fingerprint changes — a free local re-check |
| unsorted / unsure / dry run, **with a probability** | the fingerprint changes |
| held **by Jev** as a personal record | the fingerprint changes — never on a timer |
| no probability (placeholder didn't download, a failure, held locally) | a second look, then once a day |

A probability means Jev answered, and the same evidence through the same logic
gives the same answer. No probability means there was no answer yet.

Two more rules sit in front of the table:

- **A different file at the same path is always new.** Entries record the
  file's creation date and size, so a new `invoice.pdf` downloaded where an old
  one was filed is decided, not skipped.
- **An outage is not an attempt.** No key, a rejected key, rate limiting, a
  server error or no network records nothing: the pass stops, the panel says
  what to do, and the next pass tries again.

## Policy is not in the fingerprint

The two thresholds and dry run change what is **done** with an answer, not the
answer. The journal already holds the answer with its probability, so when they
change `Pipeline.reapplyPolicy` re-decides from it — **no API call**:

- above the auto-move threshold: filed
- between the thresholds: waits for you
- below: left alone

Moves are not made by the toggle itself: the panel says how many previews
would now be filed and waits for **File them** or **Not now**, and a bulk move
can be undone as one. Moving the other way — back to waiting or below the line
— applies at once.

Left out: folder units and new-folder proposals (always your call), anything
you told to stay, files that moved since. Turning dry run **on** changes
nothing already decided — it only stops new moves. Settings are read again
after the model answers, so dry run switched on mid-request still holds.
