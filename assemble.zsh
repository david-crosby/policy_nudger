#!/bin/zsh --no-rcs
# shellcheck shell=bash

####################################################################################################
#
# Build-time only. Embeds policyNudger.zsh into launchDaemonManagement.zsh,
# producing one self-contained script to paste into a Jamf Pro Script payload.
# Never deployed to an end-user Mac — only its output is.
#
# Usage:   zsh assemble.zsh
# Output:  Resources/policy-nudger-assembled-<timestamp>.zsh
#
####################################################################################################

set -euo pipefail

projectDir="$( cd "$( dirname "${0}" )" && pwd )"
resourcesDir="${projectDir}/Resources"
baseScript="${projectDir}/launchDaemonManagement.zsh"
nudgeScript="${projectDir}/policyNudger.zsh"
timestamp="$( date '+%Y-%m-%d-%H%M%S' )"
outputScript="${resourcesDir}/policy-nudger-assembled-${timestamp}.zsh"

[[ -f "${baseScript}" ]]  || { echo "❌ Not found: ${baseScript}";  exit 1; }
[[ -f "${nudgeScript}" ]] || { echo "❌ Not found: ${nudgeScript}"; exit 1; }
mkdir -p "${resourcesDir}"

zsh -n "${nudgeScript}" || { echo "❌ Syntax error in ${nudgeScript}"; exit 1; }

if grep -qx 'ENDOFSCRIPT' "${nudgeScript}"; then
    echo "❌ ${nudgeScript} contains a bare 'ENDOFSCRIPT' line, which would terminate the heredoc early."
    exit 1
fi

# Replace everything between "cat <<'ENDOFSCRIPT'" and "ENDOFSCRIPT" with the nudge script.
awk -v nudge="${nudgeScript}" '
    /^cat <<'\''ENDOFSCRIPT'\''$/ { print; while ((getline line < nudge) > 0) print line; skipping = 1; next }
    skipping && /^ENDOFSCRIPT$/     { skipping = 0 }
    !skipping                       { print }
' "${baseScript}" > "${outputScript}.tmp"

if ! grep -q '^scriptVersion="' "${outputScript}.tmp" || [[ $( grep -c '^ENDOFSCRIPT$' "${outputScript}.tmp" ) -ne 1 ]]; then
    rm -f "${outputScript}.tmp"
    echo "❌ Assembly failed (markers not found in ${baseScript})."
    exit 1
fi

zsh -n "${outputScript}.tmp" || { rm -f "${outputScript}.tmp"; echo "❌ Assembled script failed syntax check."; exit 1; }

mv "${outputScript}.tmp" "${outputScript}"
chmod 644 "${outputScript}"

echo "✅ Assembled: ${outputScript}"
echo "   Nudge script version: $( awk -F'"' '/^scriptVersion=/ {print $2; exit}' "${nudgeScript}" )"
echo "   SHA-256: $( shasum -a 256 "${outputScript}" | awk '{print $1}' )"
echo "   Paste the contents into Jamf Pro → Settings → Computer Management → Scripts."
