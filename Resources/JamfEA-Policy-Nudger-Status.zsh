#!/bin/zsh --no-rcs
# shellcheck shell=bash

####################################################################################################
#
# Jamf Pro Extension Attribute: Policy Nudger Status
#
# Reports one line per nudge configured on this Mac (com.lbg.policynudger.<name>
# profiles, plus the base com.lbg.policynudger profile if it names a policy), e.g.:
#
#   zoom-6.2: Completed 2026-10-06 14:12 | Deferrals: 2 | Last: user chose to install
#   office-2026: Pending | Deferrals: 1 | Deferred until: 2026-10-07 09:00 | Last: deferred 1 day
#   chrome: Pending | Deferrals: 0 | Retry after: 2026-10-07 10:15 | Last: failed (user chose to install)
#   chrome: Not started
#
# or "Not configured" if there are no nudges.
#
# Data Type: String. Smart Group tip: "Policy Nudger Status" like "zoom-6.2: Pending".
#
####################################################################################################

setopt nullglob

managedDirectory="/Library/Managed Preferences"
baseDomain="com.lbg.policynudger"
stateDirectory="/Library/Management/com.lbg/policynudger"

typeset -a profiles lines seen
profiles=( "${managedDirectory}/${baseDomain}".*.plist )
if [[ -f "${managedDirectory}/${baseDomain}.plist" ]] && \
   [[ -n "$( defaults read "${managedDirectory}/${baseDomain}" PolicyTrigger 2>/dev/null )$( defaults read "${managedDirectory}/${baseDomain}" PolicyID 2>/dev/null )" ]]; then
    profiles+=( "${managedDirectory}/${baseDomain}.plist" )
fi

for profile in "${profiles[@]}"; do

    plist="${profile%.plist}"

    nudgeID=$( defaults read "${plist}" NudgeID 2>/dev/null )
    if [[ -z "${nudgeID}" ]]; then
        policyTrigger=$( defaults read "${plist}" PolicyTrigger 2>/dev/null )
        policyID=$( defaults read "${plist}" PolicyID 2>/dev/null )
        if [[ -n "${policyTrigger}" ]]; then
            nudgeID="${policyTrigger}"
        elif [[ -n "${policyID}" ]]; then
            nudgeID="policy-${policyID}"
        fi
    fi

    if [[ -z "${nudgeID}" ]]; then
        lines+=( "${${profile:t}%.plist}: No PolicyTrigger or PolicyID" )
        continue
    elif [[ ! "${nudgeID}" =~ '^[A-Za-z0-9._-]{1,64}$' ]]; then
        lines+=( "${${profile:t}%.plist}: Invalid NudgeID/PolicyTrigger" )
        continue
    fi
    (( ${seen[(Ie)${nudgeID}]} )) && continue
    seen+=( "${nudgeID}" )

    stateFile="${stateDirectory}/${nudgeID}"

    if [[ ! -f "${stateFile}.plist" || -L "${stateFile}.plist" ]]; then
        lines+=( "${nudgeID}: Not started" )
        continue
    fi

    completed=$( defaults read "${stateFile}" Completed 2>/dev/null )
    deferrals=$( defaults read "${stateFile}" DeferralCount 2>/dev/null )
    lastAction=$( defaults read "${stateFile}" LastAction 2>/dev/null )

    if [[ "${completed}" == "1" ]]; then
        completedDate=$( defaults read "${stateFile}" CompletedDate 2>/dev/null )
        [[ "${completedDate}" == <-> ]] && completedDate=$( date -j -f "%s" "${completedDate}" "+%Y-%m-%d %H:%M" )
        lines+=( "${nudgeID}: Completed ${completedDate} | Deferrals: ${deferrals:-0} | Last: ${lastAction:-none}" )
    else
        now=$( date +%s )
        retryAfter=$( defaults read "${stateFile}" RetryAfter 2>/dev/null )
        deferUntil=$( defaults read "${stateFile}" DeferUntil 2>/dev/null )
        if [[ "${retryAfter}" == <-> ]] && (( retryAfter > now )); then
            waitingFor="Retry after: $( date -j -f "%s" "${retryAfter}" "+%Y-%m-%d %H:%M" )"
        elif [[ "${deferUntil}" == <-> ]] && (( deferUntil > now )); then
            waitingFor="Deferred until: $( date -j -f "%s" "${deferUntil}" "+%Y-%m-%d %H:%M" )"
        else
            waitingFor="Due"
        fi
        lines+=( "${nudgeID}: Pending | Deferrals: ${deferrals:-0} | ${waitingFor} | Last: ${lastAction:-none}" )
    fi

done

if (( ${#lines} == 0 )); then
    echo "<result>Not configured</result>"
else
    echo "<result>${(F)lines}</result>"
fi

exit 0
