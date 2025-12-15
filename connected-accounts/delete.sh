#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-12-15
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: Delete a connected account for the authenticated user by ID
# Reference:
# - MyAccount API (Connected Accounts): delete account
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-a access_token] -i connected_account_id [-h|-v]
        -e file        # .env file location (default cwd)
        -a token       # MyAccount access_token
        -i id          # Connected Account ID to delete
        -h|?           # usage
        -v             # verbose

Notes:
- Host is extracted from the access token's iss claim per project guidelines.
- This script validates expected MyAccount scope in the access token.

eg,
     $0 -a eyJ... -i acc_12345
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
declare connected_account_id=""

# shellcheck disable=SC1090
while getopts "e:a:i:hv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    a) token="${OPTARG}" ;;
    i) connected_account_id="${OPTARG}" ;;
    v) opt_verbose=1; curl_verbose='-s' ;;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }
[[ -z "${connected_account_id}" ]] && { echo >&2 "Error: connected_account_id is required (-i)."; usage 2; }

# Validate required scope
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="delete:me:connected_accounts"
[[ " ${AVAILABLE_SCOPES} " == *" ${EXPECTED_SCOPE} "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '${EXPECTED_SCOPE}', Available: '${AVAILABLE_SCOPES}'";
  exit 1;
}

# Host derived from iss claim
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")
[[ -z "${iss}" || "${iss}" == "null" ]] && { echo >&2 "Error: 'iss' claim not found in access token payload"; exit 1; }

# Trim trailing slash from iss if present
declare host="${iss%/}"

# Endpoint
declare -r encoded_id=$(jq -rn --arg v "${connected_account_id}" '$v|@uri')
declare -r url="${host}/me/v1/connected-accounts/accounts/${encoded_id}"

[[ -n "${opt_verbose}" ]] && echo "Calling ${url}" >&2

response=$(curl ${curl_verbose} --url "${url}" \
  -X DELETE \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${token}" \
  -w '\n%{http_code}')

http_code=$(tail -n1 <<< "${response}")
body=$(sed '$d' <<< "${response}")

if [[ -n "${opt_verbose}" ]]; then
  echo "HTTP status: ${http_code}" >&2
  if [[ -n "${body}" ]]; then
    if jq -e . >/dev/null 2>&1 <<< "${body}"; then
      echo "Response Body:" >&2
      echo "${body}" | jq . >&2
    else
      echo "Non-JSON response body:" >&2
      echo "${body}" >&2
    fi
  fi
fi

if ! [[ "${http_code}" =~ ^2 ]]; then
  echo >&2 "ERROR: HTTP ${http_code} from ${url}"
  if [[ -n "${body}" ]]; then
    if jq -e . >/dev/null 2>&1 <<< "${body}"; then
      echo "${body}" | jq . >&2
    else
      echo "${body}" >&2
    fi
  fi
  exit 1
fi

# For successful delete, there may be no response body (e.g., 204 No Content).
[[ -n "${body}" ]] && echo "${body}"
