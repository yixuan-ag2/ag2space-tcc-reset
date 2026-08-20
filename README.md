# reset-ag2space-tcc.sh

Inspect and reset macOS TCC (privacy) grants for AG2 Space — for the case where a permission
looks granted in System Settings but the app still sees it as denied.

```bash
./reset-ag2space-tcc.sh            # inspect only — changes nothing
./reset-ag2space-tcc.sh --reset    # remove the rows so the app re-prompts (asks first)
```

## Run inspect first

It answers the one question that ends the guessing: **what does the app itself see?** TCC is
per-process, so checking from a Terminal reports the Terminal's grants, not AG2 Space's. The app
writes its own view to `state/permission-status.json` every few seconds, and inspect reads that,
reports how old it is, and says plainly when it could not check something.

`accessibility_granted: false` while System Settings shows the toggle **on** is the stale-row
case: the row is bound to a previous build's identity and the preflight will stay false forever.
Toggling never fixes it; removing the row does.

## What --reset does

Quits the app (a grant never reaches an already-running process), runs `tccutil reset` for
`Accessibility ScreenCapture ListenEvent PostEvent Microphone Camera`, relaunches via
LaunchServices, then tells you what to check.

Options: `--dry-run`, `--yes`, `--services "A B"`, `--bundle other.id`.

## Two things it deliberately will not do

- **It never edits `TCC.db` directly.** That needs SIP disabled, which is a far bigger
  concession than the problem warrants.
- **It never claims it removed a stale row.** `tccutil` prints *"Successfully reset"* with exit 0
  even when there was no row at all, so success here means "the call was accepted" — nothing more.
  The proof that it worked is the app's own status file flipping to `true` afterwards.

## Verified

- Service names checked against real `tccutil` behaviour: valid → `rc=0 "Successfully reset…"`,
  unknown → `rc=70 "Failed to reset…"`. The script classifies on both, and an unknown service is
  reported as a failure rather than silently counted as done.
- The `accessibility_granted: false` branch was exercised in a sandboxed `HOME` and asserted to
  have read the sandbox file, not the real one.
- The full `--reset` path was run end-to-end against an inert bundle (`com.apple.Chess`), with
  AG2 Space confirmed unaffected.

Two bugs were found by that testing and fixed: `--bundle` retargeted the reset while quit/relaunch
still acted on AG2 Space, and the quit-wait used `pgrep -x "AG2 Space"`, which can never match —
the executable is named `cinny`, so the wait would have reported "quit" while the app was running.
