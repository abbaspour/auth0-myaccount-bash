#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-11-03
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: Initiate a connect flow for an external (social/OIDC) account
# Reference:
# - MyAccount API (Connected Accounts): initiate connect flow
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-t tenant] [-d domain] [-a access_token] [-c connection] [-S state] [-r redirect_uri] [-s scope] [-p param] [-A access_type] [-C] [-h|-v]
        -e file        # .env file location (default cwd)
        -t tenant      # Auth0 tenant@region (optional; host is derived from access token iss)
        -d domain      # Auth0 custom domain (optional; host is derived from access token iss)
        -a token       # MyAccount access_token
        -c connection  # Connection name (e.g., google-oauth2)
        -S state       # CSRF protection state value (unique random string)
        -r url         # Redirect URI to return after provider completes (required)
        -s scope       # Provider scopes (default: "openid profile")
        -p param       # Optional: authorization_params.param (omit if not provided)
        -A access_type # Optional: authorization_params.access_type (omit if not provided)
        -C             # Copy final_url to clipboard
        -h|?           # usage
        -v             # verbose

Notes:
- Host is extracted from the access token's iss claim per project guidelines.
- This script validates expected MyAccount scope in the access token.

eg,
     $0 -a eyJ... -c google-oauth2 -S 123456 -r https://app.example.com/callback -s "openid profile offline_access" -p prompt=consent -A offline
END
  exit $1
}

# Load local .env if present
[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

# Defaults
declare opt_verbose=''
declare opt_clipboard=''
declare curl_verbose='-s'

# Common parameters
declare token="${access_token:-}"
# Optional tenant/domain (not used when iss is present)
declare AUTH0_DOMAIN="${AUTH0_DOMAIN:-}"

# Command-specific parameters
declare connection=""
declare state="my-state"
declare redirect_uri=""
declare scope="openid profile"
declare auth_param=""
declare access_type="offline"

# shellcheck disable=SC1090
while getopts "e:t:d:a:c:S:r:s:p:A:Chv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    t) : ;; # accepted but not used (host comes from iss)
    d) AUTH0_DOMAIN=${OPTARG} ;;
    a) token="${OPTARG}" ;;
    c) connection="${OPTARG}" ;;
    S) state="${OPTARG}" ;;
    r) redirect_uri="${OPTARG}" ;;
    s) scope="${OPTARG}" ;;
    p) auth_param="${OPTARG}" ;;
    A) access_type="${OPTARG}" ;;
    C) opt_clipboard=1 ;;
    v) opt_verbose=1; curl_verbose='-s' ;;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }
[[ -z "${connection}" ]] && { echo >&2 "Error: connection is required (-c)."; usage 2; }
[[ -z "${state}" ]] && { echo >&2 "Error: state is required (-S)."; usage 2; }
[[ -z "${redirect_uri}" ]] && { echo >&2 "Error: redirect_uri is required (-r)."; usage 2; }

# Validate scope in access token
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="create:me:connected_accounts"
[[ " ${AVAILABLE_SCOPES} " == *" ${EXPECTED_SCOPE} "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '${EXPECTED_SCOPE}', Available: '${AVAILABLE_SCOPES}'";
  exit 1;
}

# Host derived from iss claim
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")
[[ -z "${iss}" || "${iss}" == "null" ]] && {
  # As a fallback, try AUTH0_DOMAIN if iss is missing (non-standard for MyAccount tokens)
  if [[ -n "${AUTH0_DOMAIN}" ]]; then
    host="https://${AUTH0_DOMAIN%/}"
  else
    echo >&2 "Error: 'iss' claim not found in access token payload and AUTH0_DOMAIN not provided"; exit 1;
  fi
} || host="${iss%/}"

# Build request body
readonly BODY=$(
  jq -n \
    --arg connection "${connection}" \
    --arg scope "${scope}" \
    --arg state "${state}" \
    --arg redirect_uri "${redirect_uri}" \
    --arg param "${auth_param}" \
    --arg access_type "${access_type}" \
    '
    {
      connection: $connection,
      state: $state,
      redirect_uri: $redirect_uri,
      authorization_params:
            ( { scope: $scope  }
              + ( if ($param|length)>0 then { param: $param } else {} end )
              + ( if ($access_type|length)>0 then { access_type: $access_type } else {} end )
            )
    }
    '
)

# Endpoint
readonly url="${host}/me/v1/connected-accounts/connect"

[[ -n "${opt_verbose}" ]] && {
  echo "Calling ${url}" >&2
  echo "Request Body:" >&2
  echo "${BODY}" | jq . >&2
}

response=$(curl ${curl_verbose} --url "${url}" \
  -X POST \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${token}" \
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

connect_uri=$(jq -r '.connect_uri // empty' <<< "${body}")
ticket=$(jq -r '.connect_params.ticket // empty' <<< "${body}")
auth_session=$(jq -r '.auth_session // empty' <<< "${body}")

if [[ -z "${connect_uri}" || -z "${ticket}" ]]; then
  echo >&2 "ERROR: Missing connect_uri or ticket in response."
  echo "${body}" | jq . >&2 || echo "${body}" >&2
  exit 1
fi

encoded_ticket=$(jq -rn --arg t "${ticket}" '$t|@uri')
sep='?'
[[ "${connect_uri}" == *\?* ]] && sep='&'
final_url="${connect_uri}${sep}ticket=${encoded_ticket}"

if [[ -n "${opt_clipboard}" ]]; then
  if command -v pbcopy >/dev/null; then
    echo "${final_url}" | pbcopy
    echo "Final URL copied to clipboard" >&2
  elif command -v xclip >/dev/null; then
    echo "${final_url}" | xclip -selection clipboard
    echo "Final URL copied to clipboard" >&2
  else
    echo >&2 "Warning: No clipboard utility found (pbcopy or xclip)"
  fi
fi

echo "auth_session: ${auth_session}"
echo "${final_url}"
