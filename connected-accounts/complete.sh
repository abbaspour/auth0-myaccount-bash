#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-11-03
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: Complete a connect flow for an external (social/OIDC) account
# Reference:
# - MyAccount API (Connected Accounts): complete connect flow
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-t tenant] [-d domain] [-m access_token] [-a auth_session] [-c connect_code] [-r redirect_uri] [-h|-v]
        -e file        # .env file location (default cwd)
        -t tenant      # Auth0 tenant@region (optional; host is derived from me_token iss)
        -d domain      # Auth0 custom domain (optional; host is derived from me_token iss)
        -m token       # MyAccount ME_TOKEN
        -a session     # Auth session ID from connect initiation
        -c code        # Connect code from provider callback
        -r url         # Redirect URI (must match the one used in connect initiation)
        -h|?           # usage
        -v             # verbose

Notes:
- Host is extracted from the me_token's iss claim per project guidelines.
- This script validates expected MyAccount scope in the me_token.

eg,
     $0 -m eyJ... -a auth_session_123 -c connect_code_456 -r https://app.example.com/callback
END
  exit $1
}

# Load local .env if present
[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

# Defaults
declare opt_verbose=''
declare curl_verbose='-s'

# Common parameters
declare me_token="${access_token:-}"
# Optional tenant/domain (not used when iss is present)
declare AUTH0_DOMAIN="${AUTH0_DOMAIN:-}"

# Command-specific parameters
declare auth_session=""
declare connect_code=""
declare redirect_uri=""

# shellcheck disable=SC1090
while getopts "e:t:d:m:a:c:r:hv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    t) : ;; # accepted but not used (host comes from iss)
    d) AUTH0_DOMAIN=${OPTARG} ;;
    m) me_token="${OPTARG}" ;;
    a) auth_session="${OPTARG}" ;;
    c) connect_code="${OPTARG}" ;;
    r) redirect_uri="${OPTARG}" ;;
    v) opt_verbose=1; curl_verbose='-s' ;;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -z "${me_token:-}" ]] && { echo >&2 "Error: me_token is required. Provide with -m or ME_TOKEN env var."; usage 2; }
[[ -z "${auth_session}" ]] && { echo >&2 "Error: auth_session is required (-a)."; usage 2; }
[[ -z "${connect_code}" ]] && { echo >&2 "Error: connect_code is required (-c)."; usage 2; }
[[ -z "${redirect_uri}" ]] && { echo >&2 "Error: redirect_uri is required (-r)."; usage 2; }

# Validate scope in me_token
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${me_token}")
declare -r EXPECTED_SCOPE="create:me:connected_accounts"
[[ " ${AVAILABLE_SCOPES} " == *" ${EXPECTED_SCOPE} "* ]] || {
  echo >&2 "ERROR: Insufficient scope in ME_TOKEN. Expected: '${EXPECTED_SCOPE}', Available: '${AVAILABLE_SCOPES}'";
  exit 1;
}

# Host derived from iss claim
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${me_token}")
[[ -z "${iss}" || "${iss}" == "null" ]] && {
  # As a fallback, try AUTH0_DOMAIN if iss is missing (non-standard for MyAccount tokens)
  if [[ -n "${AUTH0_DOMAIN}" ]]; then
    host="https://${AUTH0_DOMAIN%/}"
  else
    echo >&2 "Error: 'iss' claim not found in me_token payload and AUTH0_DOMAIN not provided"; exit 1;
  fi
} || host="${iss%/}"

# Build request body
readonly BODY=$(
  jq -n \
    --arg auth_session "${auth_session}" \
    --arg connect_code "${connect_code}" \
    --arg redirect_uri "${redirect_uri}" \
    '
    {
      auth_session: $auth_session,
      connect_code: $connect_code,
      redirect_uri: $redirect_uri
    }
    '
)

# Endpoint
readonly url="${host}/me/v1/connected-accounts/complete"

[[ -n "${opt_verbose}" ]] && {
  echo "Calling ${url}" >&2
  echo "Request Body:" >&2
  echo "${BODY}" | jq . >&2
}

response=$(curl ${curl_verbose} --url "${url}" \
  -X POST \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${me_token}" \
  -d "${BODY}" \
  -w '\n%{http_code}')

http_code=$(tail -n1 <<< "${response}")
body=$(sed '$d' <<< "${response}")

if [[ -n "${opt_verbose}" ]]; then
  echo "HTTP status: ${http_code}" >&2
  if jq -e . >/dev/null 2>&1 <<< "${body}"; then
    echo "Response Body:" >&2
    echo "${body}" | jq . >&2
  else
    echo "Non-JSON response body:" >&2
    echo "${body}" >&2
  fi
fi

if ! [[ "${http_code}" =~ ^2 ]]; then
  echo >&2 "ERROR: HTTP ${http_code} from ${url}"
  if jq -e . >/dev/null 2>&1 <<< "${body}"; then
    echo "${body}" | jq . >&2
  else
    echo "${body}" >&2
  fi
  exit 1
fi

# Output the response body for successful completion
echo "${body}"