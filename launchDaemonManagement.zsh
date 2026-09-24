#!/bin/zsh --no-rcs
# shellcheck shell=bash

####################################################################################################
#
# Policy Nudger — Installer / LaunchDaemon Management
#
# Deployed as a single Jamf Pro policy Script payload (after running assemble.zsh,
# which embeds policyNudger.zsh below). Every run is idempotent:
#   1. Verifies swiftDialog is installed, current, and signed by the expected
#      Team ID; installs/updates it from GitHub if not.
#   2. Writes the nudge script to /Library/Management/com.lbg/policynudger.zsh,
#      replacing it only if the embedded copy differs.
#   3. Writes and loads the LaunchDaemon, replacing it only if it differs.
#      (AbandonProcessGroup is set so the post-install result dialog isn't killed
#      by launchd when the nudge script exits.)
#   4. Verifies all three are present and loaded; exits non-zero (so the Jamf
#      policy log shows a failure) if anything is missing.
#
# Jamf policy Script Parameters:
#   Parameter 4: Action               (blank = install/repair | ResetState | Uninstall)
#   Parameter 5: Check Interval (min) (default 15; 5–240) — how often the nudge
#                                      script wakes to decide whether to prompt
#
####################################################################################################



####################################################################################################
#
# Global Variables
#
####################################################################################################

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

scriptVersion="1.1.0"
scriptLog="/var/log/com.lbg.policynudger.log"

swiftDialogMinimumRequiredVersion="2.5.6.4805"
expectedDialogTeamID="PWA5E9TQ59"
dialogBinary="/usr/local/bin/dialog"

autoload -Uz is-at-least



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# MDM Script Parameters
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

actionParameter="${4:-}"
checkIntervalParameter="${5:-15}"



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Organization Variables
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

reverseDomainNameNotation="com.lbg"
humanReadableScriptName="Policy Nudger"
organizationScriptName="policynudger"
organizationDirectory="/Library/Management/${reverseDomainNameNotation}"
nudgeScriptPath="${organizationDirectory}/${organizationScriptName}.zsh"
stateDirectory="${organizationDirectory}/${organizationScriptName}"

launchDaemonLabel="${reverseDomainNameNotation}.${organizationScriptName}"
launchDaemonPath="/Library/LaunchDaemons/${launchDaemonLabel}.plist"



####################################################################################################
#
# Functions
#
####################################################################################################

function updateScriptLog() {
    echo "${organizationScriptName}-installer (${scriptVersion}): $( date +%Y-%m-%d\ %H:%M:%S ) - ${1}" | tee -a "${scriptLog}"
}

function preFlight()    { updateScriptLog "[PRE-FLIGHT]      ${1}"; }
function logComment()   { updateScriptLog "                  ${1}"; }
function notice()       { updateScriptLog "[NOTICE]          ${1}"; }
function info()         { updateScriptLog "[INFO]            ${1}"; }
function warning()      { updateScriptLog "[WARNING]         ${1}"; }
function fatal()        { updateScriptLog "[FATAL ERROR]     ${1}"; [[ -n "${tempDirectory}" ]] && rm -rf "${tempDirectory}"; exit 1; }



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Security Helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function assertTrustedRootPath() {

    local targetPath="${1}"

    if [[ -L "${targetPath}" ]]; then
        fatal "Refusing to use '${targetPath}': path is a symlink."
    fi

    if [[ -e "${targetPath}" ]]; then
        local owner
        owner=$( stat -f "%Su" "${targetPath}" 2>/dev/null )
        if [[ "${owner}" != "root" ]]; then
            fatal "Refusing to use '${targetPath}': owned by '${owner}', not root (possible tampering)."
        fi
    fi

}

function verifyTeamID() {

    local teamID
    teamID=$( codesign -dv --verbose=4 "${1}" 2>&1 | awk -F'=' '/^TeamIdentifier/ {print $2}' )
    [[ "${teamID}" == "${expectedDialogTeamID}" ]]

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# swiftDialog
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function dialogInstall() {

    local dialogURL
    dialogURL=$( curl --proto '=https' --tlsv1.2 --max-time 15 -L --silent --fail "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" | awk -F '"' "/browser_download_url/ && /pkg\"/ { print \$4; exit }" )

    if [[ "${dialogURL}" != https://github.com/* ]]; then
        fatal "Unexpected swiftDialog download URL (refusing to fetch): '${dialogURL}'"
    fi

    preFlight "Installing swiftDialog from ${dialogURL} …"

    tempDirectory=$( mktemp -d "/private/tmp/${organizationScriptName}.XXXXXX" )
    chmod 700 "${tempDirectory}"

    curl --proto '=https' --tlsv1.2 --max-time 120 --location --silent --fail "${dialogURL}" -o "${tempDirectory}/Dialog.pkg" \
        || fatal "swiftDialog download failed."

    local teamID
    teamID=$( spctl -a -vv -t install "${tempDirectory}/Dialog.pkg" 2>&1 | awk '/origin=/ {print $NF }' | tr -d '()' )

    if [[ "${teamID}" != "${expectedDialogTeamID}" ]]; then
        fatal "swiftDialog package Team ID verification failed (found: '${teamID:-none}', expected: '${expectedDialogTeamID}'); refusing to install."
    fi

    installer -pkg "${tempDirectory}/Dialog.pkg" -target / >/dev/null
    sleep 2

    rm -rf "${tempDirectory}"
    tempDirectory=""

    if [[ ! -x "${dialogBinary}" ]] || ! verifyTeamID "${dialogBinary}"; then
        fatal "swiftDialog failed post-install verification; refusing to proceed."
    fi

    preFlight "swiftDialog $( "${dialogBinary}" --version ) installed and verified."

}

function dialogCheck() {

    notice "Verifying swiftDialog"

    if [[ ! -x "${dialogBinary}" ]]; then
        preFlight "swiftDialog not found; installing …"
        dialogInstall
    elif ! verifyTeamID "${dialogBinary}"; then
        warning "Existing swiftDialog failed Team ID verification; reinstalling from a known-good source."
        dialogInstall
    else
        local dialogVersion
        dialogVersion=$( "${dialogBinary}" --version )
        if is-at-least "${swiftDialogMinimumRequiredVersion}" "${dialogVersion}"; then
            preFlight "swiftDialog ${dialogVersion} found and verified."
        else
            preFlight "swiftDialog ${dialogVersion} is older than ${swiftDialogMinimumRequiredVersion}; updating …"
            dialogInstall
        fi
    fi

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# LaunchDaemon helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function launchDaemonIsLoaded() {
    launchctl print "system/${launchDaemonLabel}" >/dev/null 2>&1
}

function unloadLaunchDaemon() {
    if launchDaemonIsLoaded; then
        logComment "Unloading ${launchDaemonLabel} …"
        launchctl bootout "system/${launchDaemonLabel}" 2>/dev/null
        sleep 1
    fi
}

function removeEverything() {
    unloadLaunchDaemon
    rm -f "${launchDaemonPath}"
    rm -f "${nudgeScriptPath}"
    rm -rf "${stateDirectory}"
    logComment "Removed LaunchDaemon, nudge script and nudge state."
}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Nudge script (embedded by assemble.zsh)
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function writeNudgeScript() {

    notice "Verifying nudge script: ${nudgeScriptPath}"

    local stagedScript="${organizationDirectory}/.${organizationScriptName}.zsh.staged"
    rm -f "${stagedScript}"

(
cat <<'ENDOFSCRIPT'
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#   assemble.zsh embeds policyNudger.zsh between the "cat <<'ENDOFSCRIPT'"
#   and "ENDOFSCRIPT" lines. Do not paste this un-assembled file into Jamf.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
ENDOFSCRIPT
) > "${stagedScript}"

    if ! grep -q '^scriptVersion=' "${stagedScript}"; then
        rm -f "${stagedScript}"
        fatal "This installer has not been assembled (no nudge script embedded). Run assemble.zsh and paste its output into Jamf."
    fi

    chown root:wheel "${stagedScript}"
    chmod 755 "${stagedScript}"

    if [[ -f "${nudgeScriptPath}" ]] && cmp -s "${stagedScript}" "${nudgeScriptPath}"; then
        rm -f "${stagedScript}"
        logComment "Nudge script is current ($( awk -F'"' '/^scriptVersion=/ {print $2; exit}' "${nudgeScriptPath}" ))."
    else
        mv -f "${stagedScript}" "${nudgeScriptPath}"
        logComment "Nudge script written ($( awk -F'"' '/^scriptVersion=/ {print $2; exit}' "${nudgeScriptPath}" ))."
    fi

}



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# LaunchDaemon
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

function writeLaunchDaemon() {

    notice "Verifying LaunchDaemon: ${launchDaemonPath}"

    local stagedDaemon="${organizationDirectory}/.${launchDaemonLabel}.plist.staged"

    cat > "${stagedDaemon}" <<ENDOFLAUNCHDAEMON
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${launchDaemonLabel}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>--no-rcs</string>
        <string>${nudgeScriptPath}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StartInterval</key>
    <integer>$(( checkIntervalMinutes * 60 ))</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin</string>
    </dict>
    <key>StandardErrorPath</key>
    <string>${scriptLog}</string>
    <key>StandardOutPath</key>
    <string>${scriptLog}</string>
</dict>
</plist>
ENDOFLAUNCHDAEMON

    plutil -lint "${stagedDaemon}" >/dev/null || { rm -f "${stagedDaemon}"; fatal "Generated LaunchDaemon failed plutil -lint."; }
    chown root:wheel "${stagedDaemon}"
    chmod 644 "${stagedDaemon}"

    if [[ -f "${launchDaemonPath}" ]] && cmp -s "${stagedDaemon}" "${launchDaemonPath}"; then
        rm -f "${stagedDaemon}"
        logComment "LaunchDaemon is current (every ${checkIntervalMinutes} min)."
    else
        unloadLaunchDaemon
        mv -f "${stagedDaemon}" "${launchDaemonPath}"
        logComment "LaunchDaemon written (every ${checkIntervalMinutes} min)."
    fi

    if ! launchDaemonIsLoaded; then
        logComment "Loading ${launchDaemonLabel} …"
        launchctl bootstrap system "${launchDaemonPath}" 2>&1 | while IFS= read -r line; do logComment "launchctl: ${line}"; done
    fi

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

assertTrustedRootPath "${scriptLog}"
if [[ ! -f "${scriptLog}" ]]; then
    touch "${scriptLog}"
    chown root:wheel "${scriptLog}"
    chmod 644 "${scriptLog}"
fi

case "${actionParameter}" in
    ""|"Install"|"ResetState"|"Uninstall") ;;
    *) fatal "Unrecognised Parameter 4 '${actionParameter}' (expected blank, ResetState or Uninstall)." ;;
esac

if [[ "${checkIntervalParameter}" == <-> ]]; then
    checkIntervalMinutes="${checkIntervalParameter}"
    (( checkIntervalMinutes < 5 ))   && checkIntervalMinutes=5
    (( checkIntervalMinutes > 240 )) && checkIntervalMinutes=240
else
    warning "Parameter 5 '${checkIntervalParameter}' is not a number; using 15 minutes."
    checkIntervalMinutes=15
fi

preFlight "${humanReadableScriptName} installer (${scriptVersion}) — action: ${actionParameter:-Install}"

assertTrustedRootPath "/Library/Management"
assertTrustedRootPath "${organizationDirectory}"
mkdir -p "${organizationDirectory}"
chown root:wheel "${organizationDirectory}"
chmod 755 "${organizationDirectory}"



####################################################################################################
#
# Program
#
####################################################################################################

case "${actionParameter}" in

    "Uninstall")
        notice "Uninstalling ${humanReadableScriptName}"
        removeEverything
        rmdir "${organizationDirectory}" 2>/dev/null && logComment "Removed empty ${organizationDirectory}"
        exit 0
        ;;

    "ResetState")
        notice "Resetting nudge state (deferrals / first-seen dates)"
        rm -rf "${stateDirectory}"
        logComment "Removed ${stateDirectory}"
        ;;

esac

dialogCheck
writeNudgeScript
writeLaunchDaemon



# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Final verification — fail the Jamf policy if any component is missing
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

notice "Final verification"
sleep 1

failures=0

if [[ -x "${dialogBinary}" ]] && verifyTeamID "${dialogBinary}"; then
    logComment "✔ swiftDialog $( "${dialogBinary}" --version ) (Team ID ${expectedDialogTeamID})"
else
    logComment "✘ swiftDialog missing or untrusted"; (( failures++ ))
fi

if [[ -f "${nudgeScriptPath}" ]] && zsh -n "${nudgeScriptPath}" 2>/dev/null; then
    logComment "✔ Nudge script ${nudgeScriptPath}"
else
    logComment "✘ Nudge script missing or has a syntax error"; (( failures++ ))
fi

if [[ -f "${launchDaemonPath}" ]] && launchDaemonIsLoaded; then
    logComment "✔ LaunchDaemon ${launchDaemonLabel} loaded"
else
    logComment "✘ LaunchDaemon ${launchDaemonLabel} not loaded"; (( failures++ ))
fi

nudgeProfiles=( "/Library/Managed Preferences/${launchDaemonLabel}".*.plist(N) )
if [[ -f "/Library/Managed Preferences/${launchDaemonLabel}.plist" ]]; then
    logComment "✔ Base Configuration Profile (${launchDaemonLabel}) present"
else
    logComment "ℹ Base Configuration Profile (${launchDaemonLabel}) not present — built-in defaults will be used for shared settings."
fi
if (( ${#nudgeProfiles} )); then
    logComment "✔ ${#nudgeProfiles} nudge profile(s): ${(j:, :)${nudgeProfiles[@]:t:r}}"
else
    logComment "ℹ No nudge profiles (${launchDaemonLabel}.<name>) yet — the nudger stays idle until one arrives."
fi

if (( failures > 0 )); then
    fatal "${failures} component(s) failed verification."
fi

notice "${humanReadableScriptName} installed and verified."
exit 0
