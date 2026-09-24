# Policy Nudger

Gets users to run one or more Jamf Pro policies **at a time that suits them**,
before a deadline. A [swiftDialog](https://github.com/swiftDialog/swiftDialog)
prompt lets the user install now or defer by hours or days. When a policy's
deadline is reached it is installed regardless. Nudges never appear while the
user is in a call or presenting.

Each policy has its own Configuration Profile, deadline, deferral count and
state, so several policies can be nudged at once and each is tracked separately.

Structure and security hardening follow the sibling **DDM Update Notifier**
project.

## How it works

```
Jamf policy (once)            LaunchDaemon (every 15 min)        Jamf policies (Ongoing, custom triggers)
launchDaemonManagement.zsh ─► /Library/Management/com.lbg/ ────► jamf policy -event <PolicyTrigger>
 • installs/verifies swiftDialog   policynudger.zsh                  (one per due nudge)
 • writes nudge script             • finds every com.lbg.policynudger.<name> profile
 • writes/loads LaunchDaemon       • per nudge, decides: wait / nudge / enforce
 • fails the policy if any         • state per nudge in /Library/Management/com.lbg/policynudger/<NudgeID>.plist
   component is missing
```

### Configuration profiles

| Profile | Preference domain | Scope | Holds |
|---|---|---|---|
| **Base** (one) | `com.lbg.policynudger` | All Macs running the nudger | Shared settings: branding, text, support details, default timings and deferral options |
| **Nudge** (one per policy) | `com.lbg.policynudger.<name>`, e.g. `com.lbg.policynudger.zoom` | The same scope as the policy it nudges | That policy's trigger, name, deadline and completion check, plus any overrides |

- For each nudge, a setting comes from its own profile first, then the base
  profile, then the built-in default. For example, give one policy different
  `DeferralOptions` or `Message` by adding the key to its nudge profile only.
- These keys are **nudge profile only** and are never inherited from the base:
  `NudgeID`, `PolicyTrigger`, `PolicyID`, `PolicyName`, `CompletionCheckPath`,
  `CompletionCheckVersion`, `HardDeadline`.
- Each nudge needs a unique `NudgeID`, which defaults to its `PolicyTrigger`.
  If two profiles resolve to the same ID, the second is skipped and a warning
  is logged.
- A profile with a missing or invalid trigger is skipped with a warning. The
  other nudges keep working.
- **Single-policy setup:** a base profile that sets `PolicyTrigger` or
  `PolicyID` itself is also treated as a nudge, so a single profile still works.

### Each run

Each time the LaunchDaemon runs the nudge script, it checks every nudge as
follows:

1. **Already done?** The script exits if this nudge has completed, or if
   `CompletionCheckPath` / `CompletionCheckVersion` shows the payload is already
   installed.
2. **Deadline.** The deadline is the **earlier** of *first seen on this Mac +
   `EnforcementDays` + `EnforcementHours`* and `HardDeadline`.
3. **Before the deadline**, the script stays quiet in any of these cases:
   - a deferral is still running
   - a failed install is waiting to retry
   - nobody is logged in, or the screen is locked
   - the user is in a call or presenting

   Otherwise the nudge is eligible. **At most one nudge dialog is shown per
   run**: the eligible nudge with the earliest deadline. The others get their
   turn on later runs, so users never see a stack of windows. The user picks a deferral from
   `DeferralOptions` (choices that would pass the deadline are hidden) or clicks
   **Install Now**. An ignored prompt closes after `PromptTimeoutMinutes` and
   counts as the shortest deferral, but not against `MaxDeferrals`.
4. **At the deadline, or once `MaxDeferrals` are used up**, the script enforces.
   Enforcement takes priority over nudging: no nudge dialog appears in the same
   run.
   - All nudges that are due are handled together. They share one meeting wait
     and **one countdown**, e.g. "Microsoft Office and Zoom will now be
     installed".
   - The timing and dialog text come from the nudge with the earliest deadline.
   - It waits up to `MeetingGraceMinutes` for a call or presentation to end.
   - It then shows the countdown and installs the policies one at a time,
     earliest deadline first. If one fails, the others still install.
   - It installs **silently, with no dialog**, if the user is still in a call
     when the grace period runs out, if nobody is logged in, if the screen is
     locked, or if swiftDialog is missing.
5. **Result.** Success is recorded when `jamf policy` exits 0, Jamf Pro found a
   policy for the trigger, and the completion check (if set) passes. A failure
   is retried after `FailureRetryMinutes`, both before and after the deadline.

### Why a LaunchDaemon rather than a LaunchAgent

`jamf policy` must run as root, and a LaunchAgent runs as the user. A
LaunchAgent would therefore need a second privileged component to trigger the
install. Running as root, the daemon can show swiftDialog in the console user's
session (the same approach as DDM Update Notifier) and call `jamf` directly. It
can also enforce when nobody is logged in.

### Call / presentation detection

- **Display-sleep assertions** (`pmset -g assertions`): Teams, Zoom, Webex,
  Meet in a browser, FaceTime, Keynote and PowerPoint slideshows all hold
  `PreventUserIdleDisplaySleep` or `NoDisplaySleepAssertion` while a call or
  slideshow is running. Owners listed in `AssertionIgnoreList` are ignored.
  Browser video playback also holds this assertion, so a user watching a video
  is treated as busy. That errs on the side of not interrupting.
- **Meeting processes** (`MeetingProcesses`): Zoom runs `CptHost` only while in
  a meeting. Add other process names as needed.

## Files

| File | Purpose |
|---|---|
| `policyNudger.zsh` | The nudge script run by the LaunchDaemon |
| `launchDaemonManagement.zsh` | Installer: swiftDialog, nudge script, LaunchDaemon, final verification |
| `assemble.zsh` | **Build-time only.** Embeds `policyNudger.zsh` into the installer |
| `com.lbg.policynudger.plist` | Sample **base** profile (shared settings) |
| `com.lbg.policynudger.zoom.plist` | Sample **nudge** profile (one policy) |
| `Resources/com.lbg.policynudger.json` | Jamf Pro custom schema, used for both profile types |
| `Resources/JamfEA-Policy-Nudger-Status.zsh` | Extension Attribute: one line per nudge |

## Deploying via Jamf Pro

1. **The policy to be nudged.** Set its frequency to **Ongoing**, add a
   **Custom** trigger (e.g. `install-zoom`), and scope it to the same Macs.
   Keep it out of the recurring check-in trigger, or it will install without
   the nudge.
2. **Build.** Run `zsh assemble.zsh` and keep the SHA-256 it prints.
3. **Script.** In **Settings → Computer Management → Scripts → New**, paste in
   `Resources/policy-nudger-assembled-<timestamp>.zsh` and set these labels:
   - Parameter 4: `Action (blank | ResetState | Uninstall)`
   - Parameter 5: `Check interval minutes (default 15)`
4. **Installer policy.** Run the script **once per computer** (or at
   enrolment). Re-running it is safe: it repairs missing parts and updates the
   script or LaunchDaemon only when they have changed. It exits non-zero if
   swiftDialog, the script or the LaunchDaemon cannot be verified.
5. **Base profile.** Add **Application & Custom Settings → Jamf Applications →
   Add → Custom Schema** with preference domain `com.lbg.policynudger`, and
   paste in `Resources/com.lbg.policynudger.json`. Alternatively, upload
   `com.lbg.policynudger.plist` under **External Applications**. Fill in the
   shared settings and scope it to every Mac that runs the nudger.
6. **One nudge profile per policy.** Create the profile the same way, with
   domain `com.lbg.policynudger.<name>` (e.g. `com.lbg.policynudger.zoom`) and
   the same schema, or upload `com.lbg.policynudger.zoom.plist`. Set at least
   `PolicyTrigger`, `PolicyName` and a deadline (`EnforcementDays`/`Hours`
   and/or `HardDeadline`). **Scope it exactly like the policy it nudges.**
7. **(Optional)** Add the Extension Attribute (Data Type: String) and build
   Smart Groups such as *Status like "zoom-6.2: Pending"*.

**Adding or retiring a policy:** add or remove its nudge profile. The other
nudges are unaffected, and nothing needs to be re-run on the Macs.

**Re-nudging the same policy:** change `NudgeID` in its profile, e.g. from
`zoom-6.1` to `zoom-6.2`. State is kept per NudgeID, so the new nudge starts
fresh (first-seen date and deferral count reset) and the old state is left
alone.

**Uninstall:** re-run the installer with Parameter 4 = `Uninstall`.

## Preference keys

"Nudge only" keys are read only from the policy's own
`com.lbg.policynudger.<name>` profile. All other keys can be set in the base
profile and overridden per nudge.

| Key | Default | Notes |
|---|---|---|
| `NudgeID` | trigger name | **Nudge only.** Unique per nudge; change it to start a new nudge |
| `PolicyTrigger` / `PolicyID` | — | **Nudge only.** One of these is required; the trigger wins if both are set |
| `PolicyName` | `a required update` | **Nudge only.** Shown to the user as `{policyName}` |
| `CompletionCheckPath` / `CompletionCheckVersion` | — | **Nudge only.** e.g. `/Applications/zoom.us.app` / `6.2.0` |
| `EnforcementDays` / `EnforcementHours` | `7` / `0` | Relative deadline from first seen |
| `HardDeadline` | — | **Nudge only.** `YYYY-MM-DD HH:MM`, local time; the earliest deadline wins |
| `DeferralOptions` | `1h,4h,1d` | `h` = hours, `d` = days |
| `MaxDeferrals` | `0` (unlimited) | Once used up, the next reminder enforces |
| `PromptTimeoutMinutes` | `15` | |
| `EnforcementCountdownMinutes` | `5` | |
| `MeetingGraceMinutes` | `60` | Wait at the deadline before installing silently |
| `FailureRetryMinutes` | `60` | |
| `MeetingProcesses` | `CptHost` | |
| `AssertionIgnoreList` | `coreaudiod,powerd,caffeinate,WindowServer` | |
| `Icon`, `DateFormat`, `Title`, `Message`, `InfoBox`, `Button1Text`, `Button2Text`, `DeferralLabel`, `EnforcementTitle`, `EnforcementMessage`, `InstallingMessage`, `SuccessMessage`, `FailureMessage`, `HelpMessage`, `SupportTeam*` | see script | Text and branding |

The text keys support these placeholders: `{policyName}` `{deadline}`
`{timeRemaining}` `{deferralsRemaining}` `{deferralsUsed}` `{maxDeferrals}`
`{countdown}` `{userFirstName}` `{userName}` `{button1Text}` `{button2Text}`
`{supportTeamName}` `{supportTeamPhone}` `{supportTeamEmail}`
`{supportTeamWebsite}` `{computerName}` `{serialNumber}` `{nudgeID}`.

## Local testing

```zsh
sudo zsh policyNudger.zsh demo           # nudge dialog for the first nudge; prints exit code + selection; no state change, no install
sudo zsh policyNudger.zsh demo enforce   # 1-minute deadline countdown; no install
sudo zsh policyNudger.zsh status         # every configured nudge and its state
tail -f /var/log/com.lbg.policynudger.log

# Test a nudge without MDM: local plists are discovered too (managed profiles win)
sudo defaults write /Library/Preferences/com.lbg.policynudger.test PolicyTrigger my-test-trigger
```

## Security design

- No preference value is ever put into a shell command string. `jamf` and
  `dialog` receive every value as its own argv element.
- `PolicyTrigger`, `NudgeID` and the `<name>` in nudge profile domains are
  restricted to `A-Z a-z 0-9 . _ -`. Because NudgeID becomes a file name, this
  also blocks path traversal.
- swiftDialog's Team ID (`PWA5E9TQ59`) is checked before every launch, and the
  package is checked before install. If the check fails, no dialog is shown,
  but enforcement still happens.
- The script, log, state directory and state files must be root-owned, not
  symlinks, and not group- or other-writable. State files are mode 600 in a
  700 directory.
- Numeric preferences are clamped to sane ranges, so a bad value can't cause,
  for example, a zero-minute retry loop.
- No network access at runtime. Icons are local paths or SF Symbols only.
- The LaunchDaemon sets `AbandonProcessGroup`. Without it, launchd kills the
  post-install result dialog as soon as the script exits.
