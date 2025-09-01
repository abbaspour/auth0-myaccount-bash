#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-09-01
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: Delete an authentication method
# Reference:
# - https://auth0.com/docs/api/myaccount/authentication-methods/delete-authentication-method
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-a access_token] [-i authentication_method_id] [-h|-v]
        -e file        # .env file location (default cwd)
        -a token       # MyAccount access_token
        -i id          # authentication method ID to delete
        -h|?           # usage
        -v             # verbose

eg,
     $0 -i "auth_method_123"
END
  exit $1
}

[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

declare opt_verbose=''
declare curl_verbose='-s'
declare token="${access_token:-}"
declare method_id=""

# shellcheck disable=SC1090
while getopts "e:a:i:hv?" opt; do
    case ${opt} in
      e) source "${OPTARG}" ;;
      a) token="$OPTARG" ;;
      i) method_id="$OPTARG" ;;
      v) opt_verbose=1; curl_verbose='-s';;
      h | ?) usage 0 ;;
      *) usage 1 ;;
  esac
done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }
[[ -z "${method_id}" ]] && { echo >&2 "Error: authentication_method_id is required. Provide with -i."; usage 2; }

declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="delete:me:authentication_methods"
[[ " $AVAILABLE_SCOPES " == *" $EXPECTED_SCOPE "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '$EXPECTED_SCOPE', Available: '$AVAILABLE_SCOPES'"
  exit 1
}

declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")

[[ -z "$iss" ]] || [[ "$iss" == "null" ]] && { echo >&2 "Error: 'iss' claim not found in access token payload"; exit 1; }

# Trim trailing slash from iss if present
declare host="${iss%/}"

# Perform request
declare url="${host}/me/v1/authentication-methods/${method_id}"

[[ -n "${opt_verbose}" ]] && echo "Calling DELETE ${url}"

curl ${curl_verbose} --request DELETE --url "$url" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $token"

echo "Authentication method ${method_id} deleted successfully"