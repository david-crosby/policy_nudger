#!/bin/zsh --no-rcs
# shellcheck shell=bash

####################################################################################################
#
# Policy Nudger — End-user Nudge
#
# Nudges the logged-in user to run one or more Jamf Pro policies at a time that
# suits them, using swiftDialog. The user may defer (by hours or days) until each
# policy's enforcement deadline; once a deadline is reached that policy is
# installed regardless.
#
# Run as root by the com.lbg.policynudger LaunchDaemon every few minutes. Each run
# is cheap: it decides, per nudge, whether it is time to prompt, and exits quietly
# if not.
#
# Configuration (Configuration Profiles):
#   com.lbg.policynudger          Shared base: branding, support, default timings.
#   com.lbg.policynudger.<name>   One profile per policy (e.g. com.lbg.policynudger.zoom),
#                                 scoped like the policy it nudges. Any key here
#                                 overrides the base profile for that nudge.
#   Nudge-only keys (never inherited from the base): NudgeID, PolicyTrigger,
#   PolicyID, PolicyName, CompletionCheckPath, CompletionCheckVersion, HardDeadline.
#   A base profile that itself sets PolicyTrigger/PolicyID is also treated as a
#   nudge (single-policy set-up).
#
# Behaviour, per nudge:
#   - Deadline = the EARLIER of (first seen + EnforcementDays/EnforcementHours)
#     and HardDeadline (absolute date), whichever are configured.
#   - Before the deadline the nudge never appears while the user is in a call
#     or presenting, while the screen is locked, or while a deferral is running.
#     At most ONE nudge dialog is shown per run (earliest deadline first).
#   - At the deadline the script waits up to MeetingGraceMinutes for a call or
#     presentation to end, shows ONE countdown covering every due policy, then
#     installs them in turn. If the user is still in a call when the grace runs
#     out — or nobody is logged in, or the screen is locked — the policies are
#     installed silently with no dialog.
#
# Security notes:
#   - No preference value is ever concatenated into a shell command string;
#     every dynamic value is passed as its own argv element.
#   - PolicyTrigger / NudgeID / profile names are validated against a strict
#     character set.
#   - swiftDialog's code signature (Team ID) is verified before every launch.
#   - The script refuses to run if it, its log, or its state directory is not
#     owned by root, is a symlink, or is group/other-writable.
#
# Local testing:
#   sudo zsh policyNudger.zsh demo           # show the nudge dialog (no state change, no install)
#   sudo zsh policyNudger.zsh demo enforce   # show the deadline countdown dialog (no install)
#   sudo zsh policyNudger.zsh status         # print every configured nudge and its state
#
####################################################################################################



####################################################################################################
#
# Global Variables
#
####################################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

# Script Version
scriptVersion="1.1.0"

# Client-side Log
scriptLog="/var/log/com.lbg.policynudger.log"

# Load is-at-least for version comparison
autoload -Uz is-at-least

# Run mode (blank for normal LaunchDaemon runs)
runMode="${1:-}"
runModeOption="${2:-}"



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Organization Variables
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

humanReadableScriptName="Policy Nudger"
reverseDomainNameNotation="com.lbg"
organizationScriptName="policynudger"

# Preference domains. Paths are without .plist, as expected by `defaults`.
preferenceDomain="${reverseDomainNameNotation}.${organizationScriptName}"
managedPreferencesDirectory="/Library/Managed Preferences"
localPreferencesDirectory="/Library/Preferences"
managedPreferencesPlist="${managedPreferencesDirectory}/${preferenceDomain}"
localPreferencesPlist="${localPreferencesDirectory}/${preferenceDomain}"

# Per-nudge state (first seen, deferrals, completion), one plist per NudgeID
stateDirectory="/Library/Management/${reverseDomainNameNotation}/${organizationScriptName}"

# Prevents a manual run overlapping the LaunchDaemon
lockDirectory="/private/var/run/${preferenceDomain}.lock"

# Binaries
jamfBinary="/usr/local/bin/jamf"
dialogBinary="/usr/local/bin/dialog"
expectedDialogTeamID="PWA5E9TQ59"



####################################################################################################
#
# Functions
#
####################################################################################################

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Preference Defaults (all overridable by Configuration Profile)
#
# Reset before each nudge is loaded, so one nudge's settings never leak into the next.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function setDefaults() {

    # What to install (nudge-only keys)
    nudgeID=""                          # Change to start a new nudge (resets deferrals/first-seen)
    policyTrigger=""                    # Jamf custom event, e.g. "install-zoom"
    policyID=""                         # …or a Jamf policy ID (trigger takes precedence)
    policyName="a required update"
    completionCheckPath=""              # Optional: path that exists once installed, e.g. /Applications/zoom.us.app
    completionCheckVersion=""           # Optional: minimum CFBundleShortVersionString of CompletionCheckPath (.app)
    hardDeadline=""                     # Absolute deadline, "YYYY-MM-DD HH:MM" (local time); earliest deadline wins

    # Enforcement
    enforcementDays="7"                 # Relative deadline from first seen on this Mac…
    enforcementHours="0"                # …plus hours
    deferralOptions="1h,4h,1d"          # Choices offered to the user: <n>h (hours) or <n>d (days)
    maxDeferrals="0"                    # 0 = unlimited (until the deadline)

    # Timing
    promptTimeoutMinutes="15"           # Unanswered nudge closes itself; treated as the shortest deferral (not counted)
    enforcementCountdownMinutes="5"     # Countdown shown at the deadline before installing
    meetingGraceMinutes="60"            # At the deadline, how long to wait for a call/presentation to end
    failureRetryMinutes="60"            # After a failed install, when to try again

    # Meeting / presentation detection
    meetingProcesses="CptHost"          # Comma-separated process names that mean "in a call" (CptHost = Zoom meeting)
    assertionIgnoreList="coreaudiod,powerd,caffeinate,WindowServer"   # Display-sleep assertion owners to ignore

    # Dialog
    dialogIcon="SF=arrow.down.app.fill,colour=auto"
    dateFormat="+%a %-d %b %Y at %H:%M"
    title="{policyName} is required"
    message="**{policyName} needs to be installed on your Mac.**<br><br>Hi {userFirstName}, please install it at a time that suits you. Save your work first, as some installs close apps or need a restart.<br><br>Click **{button1Text}** to start now, or choose when to be reminded and click **{button2Text}**.<br><br>If it has not been installed by **{deadline}**, it will be installed automatically."
    infoBox="**Deadline**<br>{deadline}<br><br>**Time left**<br>{timeRemaining}<br><br>**Deferrals left**<br>{deferralsRemaining}"
    button1Text="Install Now"
    button2Text="Defer"
    deferralLabel="Remind me in"
    enforcementTitle="{policyName} will now be installed"
    enforcementMessage="**The deadline to install {policyName} has passed.**<br><br>Installation will start automatically when the timer ends. Please save your work now, or click **{button1Text}** to start straight away."
    installingMessage="Installing {policyName}. This window will close when it has finished."
    successMessage="{policyName} was installed successfully."
    failureMessage="**{policyName} could not be installed.**<br><br>We will try again later. If this keeps happening, please contact **{supportTeamName}**."

    # Support
    supportTeamName="Mac Support"
    supportTeamPhone=""
    supportTeamEmail=""
    supportTeamWebsite=""
    helpMessage="For assistance, please contact **{supportTeamName}**.<br><br>- **Telephone:** {supportTeamPhone}<br>- **Email:** {supportTeamEmail}<br>- **Website:** {supportTeamWebsite}<br><br>**Computer Name:** {computerName}<br>**Serial Number:** {serialNumber}<br>**Nudge:** {nudgeID} (script {scriptVersion})"

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Client-side Logging
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Appends to the log; echoes to the terminal only when run interactively, so the
# LaunchDaemon's StandardOutPath (same file) doesn't receive every line twice.
function updateScriptLog() {
    local line="${organizationScriptName} (${scriptVersion}): $( date +%Y-%m-%d\ %H:%M:%S ) - ${1}"
    print -r -- "${line}" >> "${scriptLog}"
    [[ -t 1 ]] && print -r -- "${line}"
}

function preFlight()    { updateScriptLog "[PRE-FLIGHT]      ${1}"; }
function logComment()   { updateScriptLog "                  ${1}"; }
# notice/info are suppressed while quietLogging is set (re-evaluating a nudge already logged this run)
function notice()       { [[ -n "${quietLogging}" ]] || updateScriptLog "[NOTICE]          ${1}"; }
function info()         { [[ -n "${quietLogging}" ]] || updateScriptLog "[INFO]            ${1}"; }
function warning()      { updateScriptLog "[WARNING]         ${1}"; }
function fatal()        { updateScriptLog "[FATAL ERROR]     ${1}"; exit 1; }
function quitOut()      { updateScriptLog "[QUIT]            ${1}"; exit 0; }



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Security Helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Refuse to operate on a path that isn't owned by root or that is a symlink.
function assertTrustedRootPath() {

    local targetPath="${1}"

    if [[ -L "${targetPath}" ]]; then
        fatal "Refusing to use '${targetPath}': path is a symlink."
    fi

    if [[ -e "${targetPath}" ]]; then
        local owner perms
        owner=$( stat -f "%Su" "${targetPath}" 2>/dev/null )
        if [[ "${owner}" != "root" ]]; then
            fatal "Refusing to use '${targetPath}': owned by '${owner}', not root (possible tampering)."
        fi
        perms=$( stat -f "%Lp" "${targetPath}" 2>/dev/null )
        if [[ -n "${perms}" ]] && (( 8#${perms} & 8#022 )); then
            fatal "Refusing to use '${targetPath}': group- or other-writable (mode ${perms})."
        fi
    fi

}

# Returns 0 only if swiftDialog is present and signed by the expected Team ID.
# Not fatal: at the deadline the policy must still install, even with no dialog.
function dialogIsTrusted() {

    [[ -x "${dialogBinary}" ]] || { warning "swiftDialog not found at '${dialogBinary}'."; return 1; }

    local teamID
    teamID=$( codesign -dv --verbose=4 "${dialogBinary}" 2>&1 | awk -F'=' '/^TeamIdentifier/ {print $2}' )

    if [[ "${teamID}" != "${expectedDialogTeamID}" ]]; then
        warning "swiftDialog failed Team ID verification (found: '${teamID:-none}', expected: '${expectedDialogTeamID}'); not launching it."
        return 1
    fi

    return 0

}

function acquireLock() {

    if mkdir "${lockDirectory}" 2>/dev/null; then
        print -r -- "$$" > "${lockDirectory}/pid"
        return 0
    fi

    local lockPID
    lockPID=$( cat "${lockDirectory}/pid" 2>/dev/null )
    if [[ "${lockPID}" == <-> ]] && kill -0 "${lockPID}" 2>/dev/null; then
        return 1
    fi

    # Stale lock left by a crashed run
    rm -rf "${lockDirectory}"
    mkdir "${lockDirectory}" 2>/dev/null || return 1
    print -r -- "$$" > "${lockDirectory}/pid"

}

function cleanup() {
    [[ -n "${progressDialogPID}" ]] && kill "${progressDialogPID}" 2>/dev/null
    [[ "$( cat "${lockDirectory}/pid" 2>/dev/null )" == "$$" ]] && rm -rf "${lockDirectory}"
}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Nudge Discovery
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Populate nudgeDomains with every com.lbg.policynudger.<name> profile present
# (managed, or local for testing), plus the base domain if it names a policy itself.
function discoverNudges() {

    setopt localoptions nullglob
    nudgeDomains=()

    local plist domain suffix
    for plist in "${managedPreferencesDirectory}/${preferenceDomain}".*.plist "${localPreferencesDirectory}/${preferenceDomain}".*.plist; do
        domain="${${plist:t}%.plist}"
        suffix="${domain#${preferenceDomain}.}"
        if [[ ! "${suffix}" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ]]; then
            warning "Ignoring preference file with an unsupported name: '${plist}'."
            continue
        fi
        (( ${nudgeDomains[(Ie)${domain}]} )) || nudgeDomains+=( "${domain}" )
    done

    local basePlist
    for basePlist in "${managedPreferencesPlist}" "${localPreferencesPlist}"; do
        [[ -f "${basePlist}.plist" ]] || continue
        if [[ -n "$( defaults read "${basePlist}" PolicyTrigger 2>/dev/null )" || -n "$( defaults read "${basePlist}" PolicyID 2>/dev/null )" ]]; then
            (( ${nudgeDomains[(Ie)${preferenceDomain}]} )) || nudgeDomains+=( "${preferenceDomain}" )
        fi
    done

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Preference Helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Lookup order: this nudge's managed profile → this nudge's local plist → (for shared
# keys only) the base managed profile → the base local plist.
function readPreference() {

    local key="${1}" scope="${2:-shared}" value="" plist
    local -a sources=( "${nudgeManagedPlist}" "${nudgeLocalPlist}" )
    [[ "${scope}" == "shared" ]] && sources+=( "${managedPreferencesPlist}" "${localPreferencesPlist}" )

    for plist in "${sources[@]}"; do
        [[ -n "${plist}" && -f "${plist}.plist" ]] || continue
        value=$( defaults read "${plist}" "${key}" 2>/dev/null )
        [[ -n "${value}" ]] && break
    done

    print -r -- "${value}"

}

# Overwrite the default in <variable> only if <key> is set.
function stringPreference() {

    local targetVariable="${1}" key="${2}" scope="${3:-shared}" value
    value=$( readPreference "${key}" "${scope}" )
    [[ -n "${value}" ]] && printf -v "${targetVariable}" '%s' "${value}"

}

# As stringPreference, but whole numbers only, clamped to [min, max] so a bad value
# can't push the script into a pathological state (e.g. a 0-minute retry loop).
function numberPreference() {

    local targetVariable="${1}" key="${2}" minValue="${3}" maxValue="${4}" value
    value=$( readPreference "${key}" )

    if [[ -n "${value}" && "${value}" != <-> ]]; then
        warning "Ignoring non-numeric ${key} '${value}'; using default ${(P)targetVariable}."
        value=""
    fi
    [[ -z "${value}" ]] && value="${(P)targetVariable}"

    (( value < minValue )) && value="${minValue}"
    (( value > maxValue )) && value="${maxValue}"

    printf -v "${targetVariable}" '%s' "${value}"

}

function loadPreferences() {

    stringPreference nudgeID                     NudgeID                nudge
    stringPreference policyTrigger               PolicyTrigger          nudge
    stringPreference policyID                    PolicyID               nudge
    stringPreference policyName                  PolicyName             nudge
    stringPreference completionCheckPath         CompletionCheckPath    nudge
    stringPreference completionCheckVersion      CompletionCheckVersion nudge
    stringPreference hardDeadline                HardDeadline           nudge

    numberPreference enforcementDays             EnforcementDays              0 365
    numberPreference enforcementHours            EnforcementHours             0 8760
    stringPreference deferralOptions             DeferralOptions
    numberPreference maxDeferrals                MaxDeferrals                 0 100

    numberPreference promptTimeoutMinutes        PromptTimeoutMinutes         1 240
    numberPreference enforcementCountdownMinutes EnforcementCountdownMinutes  1 60
    numberPreference meetingGraceMinutes         MeetingGraceMinutes          0 480
    numberPreference failureRetryMinutes         FailureRetryMinutes          15 1440

    stringPreference meetingProcesses            MeetingProcesses
    stringPreference assertionIgnoreList         AssertionIgnoreList

    stringPreference dialogIcon                  Icon
    stringPreference dateFormat                  DateFormat
    stringPreference title                       Title
    stringPreference message                     Message
    stringPreference infoBox                     InfoBox
    stringPreference button1Text                 Button1Text
    stringPreference button2Text                 Button2Text
    stringPreference deferralLabel               DeferralLabel
    stringPreference enforcementTitle            EnforcementTitle
    stringPreference enforcementMessage          EnforcementMessage
    stringPreference installingMessage           InstallingMessage
    stringPreference successMessage              SuccessMessage
    stringPreference failureMessage              FailureMessage

    stringPreference supportTeamName             SupportTeamName
    stringPreference supportTeamPhone            SupportTeamPhone
    stringPreference supportTeamEmail            SupportTeamEmail
    stringPreference supportTeamWebsite          SupportTeamWebsite
    stringPreference helpMessage                 HelpMessage

    [[ "${dateFormat}" == +* ]] || dateFormat="+${dateFormat}"

}

# Returns 1 (with a warning) if this nudge can't be used; other nudges still run.
function validatePreferences() {

    if [[ -n "${policyTrigger}" ]]; then
        if [[ ! "${policyTrigger}" =~ '^[A-Za-z0-9._-]{1,128}$' ]]; then
            warning "[${nudgeDomain}] PolicyTrigger '${policyTrigger}' contains unsupported characters (allowed: A-Z a-z 0-9 . _ -); skipping this nudge."
            return 1
        fi
        policyID=""
    elif [[ -n "${policyID}" ]]; then
        if [[ "${policyID}" != <-> ]]; then
            warning "[${nudgeDomain}] PolicyID '${policyID}' is not a number; skipping this nudge."
            return 1
        fi
    else
        warning "[${nudgeDomain}] No PolicyTrigger or PolicyID configured; skipping this nudge."
        return 1
    fi

    [[ -z "${nudgeID}" ]] && nudgeID="${policyTrigger:-policy-${policyID}}"
    if [[ ! "${nudgeID}" =~ '^[A-Za-z0-9._-]{1,64}$' ]]; then
        warning "[${nudgeDomain}] NudgeID '${nudgeID}' contains unsupported characters (allowed: A-Z a-z 0-9 . _ -, max 64); skipping this nudge."
        return 1
    fi

    stateFile="${stateDirectory}/${nudgeID}"
    assertTrustedRootPath "${stateFile}.plist"

}

# Load one nudge's settings into the working variables. Returns 1 if it is unusable.
function loadNudge() {

    nudgeDomain="${1}"
    nudgeManagedPlist="${managedPreferencesDirectory}/${nudgeDomain}"
    nudgeLocalPlist="${localPreferencesDirectory}/${nudgeDomain}"

    setDefaults
    loadPreferences
    validatePreferences

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# State Helpers (per-nudge plist: FirstSeen, DeferUntil, DeferralCount, RetryAfter, Completed)
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function initialiseStateDirectory() {

    assertTrustedRootPath "/Library/Management"
    assertTrustedRootPath "/Library/Management/${reverseDomainNameNotation}"
    mkdir -p "${stateDirectory}"
    chown root:wheel "${stateDirectory}"
    chmod 700 "${stateDirectory}"
    assertTrustedRootPath "${stateDirectory}"

}

function stateRead() {
    defaults read "${stateFile}" "${1}" 2>/dev/null
}

function stateWrite() {
    # stateWrite <key> <-int|-string|-bool> <value>
    defaults write "${stateFile}" "${1}" "${2}" "${3}"
    chmod 600 "${stateFile}.plist" 2>/dev/null
}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Time Helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Parse HardDeadline into epoch seconds. Accepts "YYYY-MM-DD HH:MM[:SS]" or
# "YYYY-MM-DDTHH:MM[:SS]" (local time), or a plist <date> as returned by
# `defaults read` ("YYYY-MM-DD HH:MM:SS +0000").
function parseHardDeadline() {

    local value="${1}" epoch=""

    if [[ "${value}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}$' ]]; then
        epoch=$( date -j -f "%Y-%m-%d %H:%M:%S %z" "${value}" "+%s" 2>/dev/null )
    else
        value="${value/T/ }"
        # BSD date fills unspecified fields from the current time, so always supply seconds.
        [[ "${value}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$' ]] && value="${value}:00"
        if [[ "${value}" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' ]]; then
            epoch=$( date -j -f "%Y-%m-%d %H:%M:%S" "${value}" "+%s" 2>/dev/null )
        fi
    fi

    print -r -- "${epoch}"

}

# "4h" → 14400, "2d" → 172800, "30m" → 1800 (minutes are handy for testing)
function durationToSeconds() {

    local value="${1// /}"
    case "${value}" in
        <->[hH]) print $(( ${value%?} * 3600 )) ;;
        <->[dD]) print $(( ${value%?} * 86400 )) ;;
        <->[mM]) print $(( ${value%?} * 60 )) ;;
        *)       print "" ;;
    esac

}

function durationLabel() {

    local seconds="${1}" n unit
    if (( seconds % 86400 == 0 )); then
        n=$(( seconds / 86400 )); unit="day"
    elif (( seconds % 3600 == 0 )); then
        n=$(( seconds / 3600 )); unit="hour"
    else
        n=$(( seconds / 60 )); unit="minute"
    fi
    (( n == 1 )) && print "${n} ${unit}" || print "${n} ${unit}s"

}

# 190000 → "2 days, 4 hours"; 5400 → "1 hour, 30 minutes"
function humanDuration() {

    local seconds="${1}" days hours minutes
    (( seconds < 60 )) && { print "less than a minute"; return; }

    days=$(( seconds / 86400 ))
    hours=$(( seconds % 86400 / 3600 ))
    minutes=$(( seconds % 3600 / 60 ))

    local -a parts
    (( days > 0 ))    && parts+=( "${days} day$( (( days == 1 )) || print s )" )
    (( hours > 0 ))   && parts+=( "${hours} hour$( (( hours == 1 )) || print s )" )
    (( days == 0 && minutes > 0 )) && parts+=( "${minutes} minute$( (( minutes == 1 )) || print s )" )

    print "${(j:, :)parts}"

}

function formatEpoch() {

    local formatted
    formatted=$( date -j -f "%s" "${1}" "${dateFormat}" 2>/dev/null )
    [[ -z "${formatted}" ]] && formatted=$( date -j -f "%s" "${1}" "+%a %-d %b %Y at %H:%M" )
    print -r -- "${formatted}"

}

# ("Zoom") → "Zoom"; ("Zoom" "Office") → "Zoom and Office"; (a b c) → "a, b and c"
function joinNames() {

    (( $# <= 1 )) && { print -r -- "${1}"; return; }
    print -r -- "${(j:, :)@[1,-2]} and ${@[-1]}"

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Deadline
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function calculateDeadline() {

    firstSeenEpoch=$( stateRead FirstSeen )
    if [[ "${firstSeenEpoch}" != <-> ]]; then
        firstSeenEpoch="${nowEpoch}"
        stateWrite FirstSeen -int "${firstSeenEpoch}"
        info "First time this nudge has been seen on this Mac; starting the clock."
    fi

    local relativeSeconds=$(( enforcementDays * 86400 + enforcementHours * 3600 ))
    local relativeDeadline="" absoluteDeadline=""

    (( relativeSeconds > 0 )) && relativeDeadline=$(( firstSeenEpoch + relativeSeconds ))

    if [[ -n "${hardDeadline}" ]]; then
        absoluteDeadline=$( parseHardDeadline "${hardDeadline}" )
        [[ -z "${absoluteDeadline}" ]] && warning "Unable to parse HardDeadline '${hardDeadline}' (expected 'YYYY-MM-DD HH:MM'); ignoring it."
    fi

    if [[ -n "${relativeDeadline}" && -n "${absoluteDeadline}" ]]; then
        deadlineEpoch=$(( relativeDeadline < absoluteDeadline ? relativeDeadline : absoluteDeadline ))
    elif [[ -n "${relativeDeadline}" || -n "${absoluteDeadline}" ]]; then
        deadlineEpoch="${relativeDeadline:-${absoluteDeadline}}"
    else
        warning "No usable deadline configured (EnforcementDays/EnforcementHours are 0 and no valid HardDeadline); defaulting to 7 days from first seen."
        deadlineEpoch=$(( firstSeenEpoch + 7 * 86400 ))
    fi

    deadlineHumanReadable=$( formatEpoch "${deadlineEpoch}" )
    secondsRemaining=$(( deadlineEpoch - nowEpoch ))
    info "Deadline: ${deadlineHumanReadable} (relative: ${relativeDeadline:-none}; hard: ${absoluteDeadline:-none})"

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Completion Check
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Returns 0 if CompletionCheckPath (and CompletionCheckVersion, if set) show the
# policy's payload is already installed. Returns 1 if not, 2 if no check is configured.
function completionCheck() {

    [[ -z "${completionCheckPath}" ]] && return 2
    [[ -e "${completionCheckPath}" ]] || return 1
    [[ -z "${completionCheckVersion}" ]] && return 0

    local installedVersion
    installedVersion=$( defaults read "${completionCheckPath}/Contents/Info" CFBundleShortVersionString 2>/dev/null )
    [[ -n "${installedVersion}" ]] && is-at-least "${completionCheckVersion}" "${installedVersion}"

}

function markComplete() {

    stateWrite Completed -bool true
    stateWrite CompletedDate -int "$( date +%s )"
    stateWrite LastAction -string "${1}"
    notice "Nudge '${nudgeID}' complete (${1})."

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Evaluate a loaded nudge
#
# Sets nudgeStatus to one of:
#   complete  – already done
#   waiting   – deferral running or failed-install retry pending
#   enforce   – deadline reached, or all deferrals used (enforceReason set)
#   nudge     – eligible to show the nudge dialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function evaluateNudge() {

    if [[ "$( stateRead Completed )" == "1" ]]; then
        nudgeStatus="complete"
        return
    fi

    notice "Checking nudge '${nudgeID}' (${policyTrigger:+event ${policyTrigger}}${policyID:+policy ID ${policyID}}) from ${nudgeDomain}"

    completionCheck
    if (( $? == 0 )); then
        markComplete "already installed (CompletionCheckPath satisfied)"
        nudgeStatus="complete"
        return
    fi

    calculateDeadline

    deferralCount=$( stateRead DeferralCount ); [[ "${deferralCount}" == <-> ]] || deferralCount=0
    deferUntilEpoch=$( stateRead DeferUntil );  [[ "${deferUntilEpoch}" == <-> ]] || deferUntilEpoch=0
    retryAfterEpoch=$( stateRead RetryAfter );  [[ "${retryAfterEpoch}" == <-> ]] || retryAfterEpoch=0

    if (( retryAfterEpoch > nowEpoch )); then
        info "Last install attempt failed; retrying after $( formatEpoch "${retryAfterEpoch}" )."
        nudgeStatus="waiting"
    elif (( nowEpoch >= deadlineEpoch )); then
        enforceReason="deadline ${deadlineHumanReadable} reached"
        nudgeStatus="enforce"
    elif (( deferUntilEpoch > nowEpoch )); then
        info "Deferred until $( formatEpoch "${deferUntilEpoch}" )."
        nudgeStatus="waiting"
    elif (( maxDeferrals > 0 && deferralCount >= maxDeferrals )); then
        enforceReason="all ${maxDeferrals} deferral(s) used"
        nudgeStatus="enforce"
    else
        nudgeStatus="nudge"
    fi

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# User Context
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function currentLoggedInUser() {

    loggedInUser=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ { print $3 }' )

    case "${loggedInUser}" in
        ""|"loginwindow"|"_mbsetupuser"|"root") loggedInUser="" ;;
    esac

    if [[ -n "${loggedInUser}" ]]; then
        loggedInUserFirstName=$( id -F "${loggedInUser}" 2>/dev/null | awk '{print $1}' )
        [[ -z "${loggedInUserFirstName}" ]] && loggedInUserFirstName="${loggedInUser}"
    fi

}

function screenIsLocked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'
}

# Returns 0 (and sets meetingReason) if the user appears to be in a call or presenting.
# Video-call and presentation apps hold a display-sleep assertion for as long as the
# call / slideshow is running; Zoom additionally runs a dedicated CptHost process.
function userIsInMeeting() {

    setopt localoptions extendedglob
    meetingReason=""

    local -a ignoreList=( "${(@s:,:)assertionIgnoreList// /}" )
    local line owner

    while IFS= read -r line; do
        owner="${line#*pid <->\(}"
        owner="${owner%%\)*}"
        [[ -z "${owner}" || "${owner}" == "${line}" ]] && continue
        (( ${ignoreList[(Ie)${owner}]} )) && continue
        meetingReason="display-sleep assertion held by '${owner}'"
        return 0
    done < <( pmset -g assertions 2>/dev/null | grep -E '^[[:space:]]+pid [0-9]+\(.*(NoDisplaySleepAssertion|PreventUserIdleDisplaySleep)' )

    local processName
    for processName in "${(@s:,:)meetingProcesses}"; do
        processName="${${processName##[[:space:]]#}%%[[:space:]]#}"
        [[ -z "${processName}" ]] && continue
        if pgrep -xq -- "${processName}"; then
            meetingReason="meeting process '${processName}' is running"
            return 0
        fi
    done

    return 1

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Dialog Text
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function buildPlaceholderValues() {

    local deferralCount="${1:-0}"

    if (( maxDeferrals == 0 )); then
        deferralsRemaining="Unlimited"
    else
        deferralsRemaining=$(( maxDeferrals - deferralCount ))
        (( deferralsRemaining < 0 )) && deferralsRemaining=0
    fi

    computerName=$( scutil --get ComputerName 2>/dev/null )
    serialNumber=$( ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformSerialNumber/ {print $4}' )

}

# Replace {placeholders} in the named variable, in place. Values are substituted as
# plain text into dialog arguments; nothing here is ever evaluated by a shell.
function replacePlaceholders() {

    local targetVariable="${1}"
    local value="${(P)targetVariable}"

    value="${value//\{policyName\}/${policyName}}"
    value="${value//\{deadline\}/${deadlineHumanReadable}}"
    value="${value//\{timeRemaining\}/$( humanDuration $(( secondsRemaining > 0 ? secondsRemaining : 0 )) )}"
    value="${value//\{deferralsRemaining\}/${deferralsRemaining}}"
    value="${value//\{deferralsUsed\}/${deferralCount:-0}}"
    value="${value//\{maxDeferrals\}/${maxDeferrals}}"
    value="${value//\{countdown\}/$( durationLabel $(( enforcementCountdownMinutes * 60 )) )}"
    value="${value//\{userFirstName\}/${loggedInUserFirstName}}"
    value="${value//\{userName\}/${loggedInUser}}"
    value="${value//\{button1Text\}/${button1Text}}"
    value="${value//\{button2Text\}/${button2Text}}"
    value="${value//\{supportTeamName\}/${supportTeamName}}"
    value="${value//\{supportTeamPhone\}/${supportTeamPhone:-—}}"
    value="${value//\{supportTeamEmail\}/${supportTeamEmail:-—}}"
    value="${value//\{supportTeamWebsite\}/${supportTeamWebsite:-—}}"
    value="${value//\{computerName\}/${computerName}}"
    value="${value//\{serialNumber\}/${serialNumber}}"
    value="${value//\{nudgeID\}/${nudgeID}}"
    value="${value//\{scriptVersion\}/${scriptVersion}}"

    printf -v "${targetVariable}" '%s' "${value}"

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Dialogs
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Build the deferral choices the user can pick from. Options that would land past
# the deadline are dropped; if none fit, offer a single "until the deadline" choice.
function buildDeferralChoices() {

    deferralChoiceLabels=()
    deferralChoiceSeconds=()

    local option seconds
    for option in "${(@s:,:)deferralOptions}"; do
        seconds=$( durationToSeconds "${option}" )
        if [[ -z "${seconds}" || "${seconds}" -le 0 ]]; then
            warning "Ignoring invalid DeferralOptions entry '${option}' (use e.g. 4h or 2d)."
            continue
        fi
        (( nowEpoch + seconds > deadlineEpoch )) && continue
        deferralChoiceLabels+=( "$( durationLabel "${seconds}" )" )
        deferralChoiceSeconds+=( "${seconds}" )
    done

    if (( ${#deferralChoiceLabels} == 0 )); then
        deferralChoiceLabels=( "Until the deadline" )
        deferralChoiceSeconds=( "${secondsRemaining}" )
    fi

}

function showNudgeDialog() {

    local dialogTitle="${title}" dialogMessage="${message}" dialogInfoBox="${infoBox}" dialogHelp="${helpMessage}"
    replacePlaceholders dialogTitle
    replacePlaceholders dialogMessage
    replacePlaceholders dialogInfoBox
    replacePlaceholders dialogHelp

    buildDeferralChoices

    local -a dialogArgs=(
        --title "${dialogTitle}"
        --message "${dialogMessage}"
        --icon "${dialogIcon}"
        --infobox "${dialogInfoBox}"
        --helpmessage "${dialogHelp}"
        --button1text "${button1Text}"
        --button2text "${button2Text}"
        --selecttitle "${deferralLabel}"
        --selectvalues "${(j:,:)deferralChoiceLabels}"
        --selectdefault "${deferralChoiceLabels[1]}"
        --timer $(( promptTimeoutMinutes * 60 ))
        --hidetimerbar
        --alwaysreturninput
        --json
        --ontop
        --moveable
        --width 760
        --height 460
        --messagefont "size=14"
        --position center
    )

    dialogOutput=$( "${dialogBinary}" "${dialogArgs[@]}" 2>/dev/null )
    dialogExitCode=$?

}

function showEnforcementDialog() {

    local dialogTitle="${enforcementTitle}" dialogMessage="${enforcementMessage}" dialogHelp="${helpMessage}"
    replacePlaceholders dialogTitle
    replacePlaceholders dialogMessage
    replacePlaceholders dialogHelp

    "${dialogBinary}" \
        --title "${dialogTitle}" \
        --message "${dialogMessage}" \
        --icon "${dialogIcon}" \
        --helpmessage "${dialogHelp}" \
        --button1text "${button1Text}" \
        --timer $(( enforcementCountdownMinutes * 60 )) \
        --ontop \
        --moveable \
        --width 700 \
        --height 360 \
        --messagefont "size=14" \
        --position center \
        >/dev/null 2>&1

}

function closeResultDialog() {
    [[ -n "${resultDialogPID}" ]] && kill "${resultDialogPID}" 2>/dev/null
    resultDialogPID=""
}

function showProgressDialog() {

    local dialogMessage="${installingMessage}"
    replacePlaceholders dialogMessage

    closeResultDialog

    "${dialogBinary}" \
        --mini \
        --title "${policyName}" \
        --message "${dialogMessage}" \
        --icon "${dialogIcon}" \
        --progress \
        --button1text none \
        --ontop \
        --moveable \
        >/dev/null 2>&1 &
    progressDialogPID=$!

}

# Left running in the background when the script exits (the LaunchDaemon sets
# AbandonProcessGroup so launchd doesn't kill it). Replaced by the next dialog
# if several policies install in one run.
function showResultDialog() {

    local dialogMessage="${1}"
    replacePlaceholders dialogMessage

    closeResultDialog

    "${dialogBinary}" \
        --mini \
        --title "${policyName}" \
        --message "${dialogMessage}" \
        --icon "${dialogIcon}" \
        --button1text "OK" \
        --timer 60 \
        --hidetimerbar \
        --ontop \
        --moveable \
        >/dev/null 2>&1 &
    resultDialogPID=$!

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Install
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# installPolicy <interactive|silent> <reason>
function installPolicy() {

    local mode="${1}" reason="${2}"
    local showUI="false"
    [[ "${mode}" == "interactive" ]] && dialogIsTrusted && showUI="true"

    notice "Installing '${nudgeID}' (${reason}; ${mode})"

    [[ -x "${jamfBinary}" ]] || fatal "Jamf binary not found at '${jamfBinary}'."

    local -a jamfArgs
    if [[ -n "${policyTrigger}" ]]; then
        jamfArgs=( policy -event "${policyTrigger}" )
    else
        jamfArgs=( policy -id "${policyID}" )
    fi

    [[ "${showUI}" == "true" ]] && showProgressDialog

    local jamfOutput jamfExitCode
    jamfOutput=$( "${jamfBinary}" "${jamfArgs[@]}" 2>&1 )
    jamfExitCode=$?

    if [[ -n "${progressDialogPID}" ]]; then
        kill "${progressDialogPID}" 2>/dev/null
        progressDialogPID=""
    fi

    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && logComment "jamf: ${line}"
    done <<< "${jamfOutput}"

    local succeeded="true"
    if (( jamfExitCode != 0 )); then
        warning "jamf exited with code ${jamfExitCode}."
        succeeded="false"
    elif [[ "${jamfOutput}" == *"No policies were found"* ]]; then
        warning "Jamf Pro returned no policy for ${jamfArgs[2]} '${jamfArgs[3]}'. Check the policy's trigger, scope and that its frequency is 'Ongoing'."
        succeeded="false"
    else
        completionCheck
        if (( $? == 1 )); then
            warning "Policy ran, but CompletionCheckPath '${completionCheckPath}'${completionCheckVersion:+ (>= ${completionCheckVersion})} is still not satisfied."
            succeeded="false"
        fi
    fi

    if [[ "${succeeded}" == "true" ]]; then
        markComplete "${reason}"
        [[ "${showUI}" == "true" ]] && showResultDialog "${successMessage}"
        return 0
    fi

    # Separate from DeferUntil so it is also honoured after the deadline — otherwise a
    # policy that keeps failing would be re-forced (with a countdown) every check interval.
    local retryEpoch=$(( $( date +%s ) + failureRetryMinutes * 60 ))
    stateWrite RetryAfter -int "${retryEpoch}"
    stateWrite LastAction -string "failed (${reason})"
    warning "Install failed; will try again after $( formatEpoch "${retryEpoch}" )."
    [[ "${showUI}" == "true" ]] && showResultDialog "${failureMessage}"
    return 1

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Nudge (before the deadline) — the currently loaded nudge
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function nudge() {

    notice "Nudging ${loggedInUser} about '${nudgeID}': $( humanDuration "${secondsRemaining}" ) until the deadline; ${deferralCount} deferral(s) used."

    buildPlaceholderValues "${deferralCount}"
    showNudgeDialog
    info "Dialog exit code: ${dialogExitCode}"

    case "${dialogExitCode}" in

        0)
            info "${loggedInUser} clicked '${button1Text}'."
            stateWrite LastAction -string "install-now"
            installPolicy interactive "user chose to install"
            ;;

        2)
            local selectedIndex selectedSeconds
            selectedIndex=$( plutil -extract SelectedIndex raw -o - - <<< "${dialogOutput}" 2>/dev/null )
            if [[ "${selectedIndex}" == <-> ]] && (( selectedIndex < ${#deferralChoiceSeconds} )); then
                selectedSeconds="${deferralChoiceSeconds[selectedIndex + 1]}"
            else
                selectedSeconds="${deferralChoiceSeconds[1]}"
                info "No deferral selection returned by swiftDialog; using the shortest option."
            fi
            deferUntilEpoch=$(( nowEpoch + selectedSeconds ))
            (( deferUntilEpoch > deadlineEpoch )) && deferUntilEpoch="${deadlineEpoch}"
            (( deferralCount++ ))
            stateWrite DeferUntil -int "${deferUntilEpoch}"
            stateWrite DeferralCount -int "${deferralCount}"
            stateWrite LastAction -string "deferred $( durationLabel "${selectedSeconds}" )"
            info "${loggedInUser} deferred for $( durationLabel "${selectedSeconds}" ) (deferral ${deferralCount}$( (( maxDeferrals > 0 )) && print " of ${maxDeferrals}" )); next reminder after $( formatEpoch "${deferUntilEpoch}" )."
            ;;

        *)
            # 4 = timed out (user away / ignored it); 10 = quit key; anything else = closed.
            # Treated as the shortest deferral, but not counted against MaxDeferrals.
            deferUntilEpoch=$(( nowEpoch + deferralChoiceSeconds[1] ))
            (( deferUntilEpoch > deadlineEpoch )) && deferUntilEpoch="${deadlineEpoch}"
            stateWrite DeferUntil -int "${deferUntilEpoch}"
            stateWrite LastAction -string "no response"
            info "No response from ${loggedInUser} (exit ${dialogExitCode}); will remind again after $( formatEpoch "${deferUntilEpoch}" )."
            ;;

    esac

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Enforce every due nudge (deadline reached, or deferrals used up)
#
# One meeting wait and one countdown cover all of them; timing and dialog text come
# from the nudge with the earliest deadline. Policies then install one at a time.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function enforceAll() {

    # enforceQueue entries are "<deadlineEpoch>:<domain>"; sort so the earliest deadline goes first.
    local -a queue=( "${(on)enforceQueue[@]}" )
    local -a domains=( "${queue[@]#*:}" )
    local -a names=()
    local domain mode="interactive" silentReason=""

    for domain in "${domains[@]}"; do
        loadNudge "${domain}" && names+=( "${policyName}" )
    done

    notice "Enforcing ${#domains} nudge(s): $( joinNames "${names[@]}" )"

    loadNudge "${domains[1]}"
    quietLogging=1; evaluateNudge; quietLogging=""

    if [[ -z "${loggedInUser}" ]]; then
        mode="silent"; silentReason="no user logged in"
    elif screenIsLocked; then
        mode="silent"; silentReason="screen locked"
    else
        # Give a call or presentation up to meetingGraceMinutes to finish.
        local waitedMinutes=0
        while userIsInMeeting && (( waitedMinutes < meetingGraceMinutes )); do
            (( waitedMinutes % 10 == 0 )) && info "In a call/presenting (${meetingReason}); waiting (${waitedMinutes}/${meetingGraceMinutes} min) …"
            sleep 60
            (( waitedMinutes++ ))
        done

        if userIsInMeeting; then
            warning "Still in a call/presenting after ${meetingGraceMinutes} min (${meetingReason}); installing silently so no dialog interrupts it."
            mode="silent"; silentReason="meeting grace expired"
        elif dialogIsTrusted; then
            buildPlaceholderValues "${deferralCount}"
            policyName="$( joinNames "${names[@]}" )"
            info "Showing ${enforcementCountdownMinutes}-minute countdown to ${loggedInUser}."
            showEnforcementDialog
        else
            mode="silent"; silentReason="swiftDialog unavailable"
        fi
    fi

    for domain in "${domains[@]}"; do
        loadNudge "${domain}" || continue
        # Re-check: an earlier policy in this run may already have installed this one.
        quietLogging=1; evaluateNudge; quietLogging=""
        [[ "${nudgeStatus}" == "enforce" ]] || continue
        stateWrite LastAction -string "enforced"
        installPolicy "${mode}" "${enforceReason}${silentReason:+; ${silentReason}}"
    done

}



####################################################################################################
#
# Pre-flight Checks
#
####################################################################################################

if [[ $( id -u ) -ne 0 ]]; then
    echo "This script must be run as root; exiting." >&2
    exit 1
fi

assertTrustedRootPath "${0:A}"
assertTrustedRootPath "${scriptLog}"

if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
    chown root:wheel "${scriptLog}"
    chmod 644 "${scriptLog}"
fi

initialiseStateDirectory
discoverNudges
nowEpoch=$( date +%s )



####################################################################################################
#
# Local Test Modes (sudo zsh policyNudger.zsh demo | demo enforce | status)
#
####################################################################################################

if [[ "${runMode}" == "status" ]]; then
    (( ${#nudgeDomains} )) || { echo "No nudges configured."; exit 0; }
    for domain in "${nudgeDomains[@]}"; do
        echo "━━ ${domain}"
        if loadNudge "${domain}"; then
            echo "Nudge ID:   ${nudgeID}"
            echo "Policy:     ${policyTrigger:+event ${policyTrigger}}${policyID:+id ${policyID}} (${policyName})"
            echo "State file: ${stateFile}.plist"
            [[ -f "${stateFile}.plist" ]] && defaults read "${stateFile}" || echo "(no state yet)"
        else
            echo "(invalid — see ${scriptLog})"
        fi
    done
    exit 0
fi

if [[ "${runMode}" == "demo" ]]; then
    dialogIsTrusted || { echo "swiftDialog is not installed or not trusted." >&2; exit 1; }
    if ! { (( ${#nudgeDomains} )) && loadNudge "${nudgeDomains[1]}"; }; then
        nudgeDomain="${preferenceDomain}"; nudgeManagedPlist=""; nudgeLocalPlist=""
        setDefaults; loadPreferences; nudgeID="demo"
    fi
    currentLoggedInUser
    deadlineEpoch=$(( nowEpoch + 3 * 86400 + 5 * 3600 ))
    deadlineHumanReadable=$( formatEpoch "${deadlineEpoch}" )
    secondsRemaining=$(( deadlineEpoch - nowEpoch ))
    deferralCount=1
    buildPlaceholderValues "${deferralCount}"
    if [[ "${runModeOption}" == "enforce" ]]; then
        enforcementCountdownMinutes=1
        showEnforcementDialog
        echo "Enforcement dialog closed (a real run would now install the policy)."
    else
        showNudgeDialog
        echo "Exit code: ${dialogExitCode}"
        echo "Output:    ${dialogOutput}"
    fi
    exit 0
fi



####################################################################################################
#
# Program
#
####################################################################################################

(( ${#nudgeDomains} )) || exit 0

acquireLock || quitOut "Another ${humanReadableScriptName} run is in progress."
trap cleanup EXIT

currentLoggedInUser

enforceQueue=()
nudgeCandidate=""
nudgeCandidateDeadline=""
seenNudgeIDs=()

for domain in "${nudgeDomains[@]}"; do

    loadNudge "${domain}" || continue

    if (( ${seenNudgeIDs[(Ie)${nudgeID}]} )); then
        warning "[${domain}] NudgeID '${nudgeID}' is already used by another profile; skipping this one. Give each profile a unique NudgeID or PolicyTrigger."
        continue
    fi
    seenNudgeIDs+=( "${nudgeID}" )

    evaluateNudge

    case "${nudgeStatus}" in
        enforce)
            enforceQueue+=( "${deadlineEpoch}:${domain}" )
            ;;
        nudge)
            if [[ -z "${nudgeCandidate}" ]] || (( deadlineEpoch < nudgeCandidateDeadline )); then
                nudgeCandidate="${domain}"
                nudgeCandidateDeadline="${deadlineEpoch}"
            fi
            ;;
    esac

done

# Deadlines first; no nudge dialog in the same run as an enforcement.
if (( ${#enforceQueue} )); then
    enforceAll
    exit 0
fi

[[ -z "${nudgeCandidate}" ]] && exit 0

[[ -z "${loggedInUser}" ]] && quitOut "No user logged in; will try again later."
screenIsLocked && quitOut "Screen is locked; will try again later."

# Meeting detection uses the chosen nudge's settings (MeetingProcesses etc. may be overridden per nudge).
loadNudge "${nudgeCandidate}"
quietLogging=1; evaluateNudge; quietLogging=""

userIsInMeeting && quitOut "User is in a call or presenting (${meetingReason}); will try again later."
dialogIsTrusted || quitOut "swiftDialog unavailable; cannot nudge (policies will still be enforced at their deadlines)."

nudge

exit 0
