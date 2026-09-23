# Usher wiki

Usher reads private files for a living. These pages describe what it will and
will not do with them, and why each rule exists.

| Page | What it covers |
| --- | --- |
| [Security model](Security-Model.md) | The layers a file passes through, what can leave the machine, what never does |
| [Secret floor](Secret-Floor.md) | How vaults, keys, recovery codes and credentials are recognised and refused |
| [Encrypted logs](Encrypted-Logs.md) | How the journal and rename log are sealed, where the key lives, what happens if it is lost |
| [When Usher asks again](When-Usher-Asks-Again.md) | The fingerprint, re-asking, and why a threshold change never costs an API call |
| [Manual checks](Manual-Checks.md) | What Usher deliberately leaves for you to verify by hand |

The [README](../../README.md) covers building, the API key, routes and rules.

## Three rules the rest follows from

1. **Nothing is sent that a local check could have stopped.** Every layer that
   can decide without the network runs before the one that cannot, and the
   request itself is screened once more right before it leaves.
2. **Nothing is written in the clear.** Logs are encrypted line by line; if the
   key cannot be read, Usher stops rather than writing plain text "for now".
3. **Nothing is destroyed.** Files are moved, never overwritten; binned files go
   to the Trash; undo reads the journal.
