#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-11-04
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: List connected accounts grouped/by connection for the user
# Reference:
# - MyAccount API (Connected Accounts): list connections
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-a access_token] [-h|-v]
        -e file        # .env file location (default cwd)
        -a token       # MyAccount access_token
        -h|?           # usage
        -v             # verbose

eg,
     $0 -a eyJ...
END
  exit $1
}

# Load local .env if present
[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

# Defaults
declare opt_verbose=''
declare curl_verbose='-s'

# Params
declare token="${access_token:-}"

# shellcheck disable=SC1090
while getopts "e:a:hv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    a) token="$OPTARG" ;;
    v) opt_verbose=1; curl_verbose='-s' ;;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac

done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }

# Validate required scope
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="read:me:connected_accounts"
[[ " ${AVAILABLE_SCOPES} " == *" ${EXPECTED_SCOPE} "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '${EXPECTED_SCOPE}', Available: '${AVAILABLE_SCOPES}'";
  exit 1;
}

# Host derived from iss claim
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")

[[ -z "$iss" ]] || [[ "$iss" == "null" ]] && { echo >&2 "Error: 'iss' claim not found in access token payload"; exit 1; }

# Trim trailing slash from iss if present
declare host="${iss%/}"

# Endpoint
declare url="${host}/me/v1/connected-accounts/connections"

[[ -n "${opt_verbose}" ]] && echo "Calling ${url}"

curl ${curl_verbose} --url "${url}" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer ${token}" | jq .
