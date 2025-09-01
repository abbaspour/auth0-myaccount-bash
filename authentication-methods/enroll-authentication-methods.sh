#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-08-25
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myaccout-bash/blob/master/LICENSE)
#
# Description: Start enrollment for an authentication method (e.g., passkey)
# Reference:
# - https://auth0.com/docs/api/myaccount/authentication-methods/create-authentication-method
# - https://auth0.com/docs/native-passkeys-api#initiate-passkey-enrollment
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-a access_token] [-m type] [-c connection] [-o organization] [-h|-v]
        -e file        # .env file location (default cwd)
        -a token       # MyAccount access_token
        -m type        # authentication method type (default: passkey)
        -c connection  # optional: connection to use for enrollment
        -o organization # optional: organization to use for enrollment
        -k file        # private key file
        -h|?           # usage
        -v             # verbose

eg,
     $0 -a eyJ... -m passkey
     $0 -a eyJ... -m passkey -c Username-Password-Authentication
     $0 -a eyJ... -m passkey -o org_12345
END
  exit $1
}

[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

declare opt_verbose=''
declare curl_verbose='-s'
declare token="${access_token:-}"
declare method_type="${type:-passkey}"
declare connection="${connection:-}"
declare organization="${organization:-}"
declare PRIVATE_KEY_FILE="private-key.pem"

# shellcheck disable=SC1090
while getopts "e:a:m:c:o:k:hv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    a) token="$OPTARG" ;;
    m) method_type="$OPTARG" ;;
    c) connection="$OPTARG" ;;
    o) organization="$OPTARG" ;;
    k) PRIVATE_KEY_FILE=${OPTARG} ;;
    v) opt_verbose=1; curl_verbose='-s';;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }
if [[ ! -f $PRIVATE_KEY_FILE ]]; then
    echo "Private key not found! Run the bootstrap script first."
    exit 1
fi

# Validate required scope
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="create:me:authentication_methods"
[[ " $AVAILABLE_SCOPES " == *" $EXPECTED_SCOPE "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '$EXPECTED_SCOPE', Available: '$AVAILABLE_SCOPES'"
  exit 1
}

# Extract issuer to build host
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")

[[ -z "$iss" ]] || [[ "$iss" == "null" ]] && { echo >&2 "Error: 'iss' claim not found in access token payload"; exit 1; }

# Trim trailing slash from iss if present
declare host="${iss%/}"

# Endpoint
declare url="${host}/me/v1/authentication-methods"

readonly BODY=$(
  jq -n \
    --arg type "${method_type}" \
    --arg connection "${connection:-}" \
    --arg organization "${organization:-}" \
    '
    { type: $type }
    + ( if ($connection | length) > 0 then { connection: $connection } else {} end )
    + ( if ($organization | length) > 0 then { organization: $organization } else {} end )
    '
)

[[ -n "${opt_verbose}" ]] && {
  echo "Calling ${url}"
  echo "${BODY}"
}

declare SIGNUP_RESPONSE
SIGNUP_RESPONSE=$(curl -s --url "$url" \
  -X POST \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${token}" \
  --data "${BODY}")

readonly register_error=$(echo "$SIGNUP_RESPONSE" | jq -r '.error // empty')

if [[ -n "${register_error}" ]]; then
  echo >&2 "ERROR: passkey register error: ${SIGNUP_RESPONSE}"
  exit 1
fi

[[ -n "${opt_verbose}" ]] && { echo "SIGNUP_RESPONSE:"; jq . <<< "${SIGNUP_RESPONSE}"; }

declare CHALLENGE SESSION_ID USER_ID USER_NAME

CHALLENGE=$(echo "$SIGNUP_RESPONSE" | jq -r '.authn_params_public_key.challenge // empty')
RP_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.authn_params_public_key.rp.id // empty')
SESSION_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.auth_session // empty')
USER_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.authn_params_public_key.user.id // empty')
USER_NAME=$(echo "$SIGNUP_RESPONSE" | jq -r '.authn_params_public_key.user.name // empty')

if [[ -z "$CHALLENGE" || -z "$SESSION_ID" ]]; then
    echo "Failed to obtain challenge and session ID. Response: $SIGNUP_RESPONSE"
    exit 1
fi

echo "Signup challenge obtained. Challenge: $CHALLENGE, Session ID: $SESSION_ID"

[[ ! -d "${DIR}/.store" ]] && mkdir -p "${DIR}/.store"

declare STORE="./.store/${USER_NAME}.json"
if [[ -f $STORE ]]; then
    echo "WARNING: store already exists at $STORE"
    #exit 1
fi

"${DIR}/attestation.sh" --rp "${RP_ID}" --challenge "${CHALLENGE}" --username "${USER_NAME}" --userid "${USER_ID}" --key "${PRIVATE_KEY_FILE}" > "${STORE}"
#go run attestation.go --rp "${RP_ID}" --challenge "${CHALLENGE}" --username "${USER_NAME}" --userid "${USER_ID}" --key "${PRIVATE_KEY_FILE}" > "${STORE}"

declare ATTESTATION_OBJECT CLIENT_DATA_JSON CREDENTIAL_ID

ATTESTATION_OBJECT=$(jq -r .response.attestationObject "${STORE}")
CLIENT_DATA_JSON=$(jq -r .response.clientDataJSON "${STORE}")
CREDENTIAL_ID=$(jq -r .responseDecoded.rawId "${STORE}")

readonly VERIFY_BODY=$(cat <<EOF
{
  "auth_session": "${SESSION_ID}",
  "authn_response": {
    "id": "${CREDENTIAL_ID}",
    "rawId": "${CREDENTIAL_ID}",
    "clientExtensionResults": {},
    "type": "public-key",
    "authenticatorAttachment": "platform",
    "response": {
      "attestationObject": "${ATTESTATION_OBJECT}",
      "clientDataJSON": "${CLIENT_DATA_JSON}"
    }
  }
}
EOF
)

readonly authentication_method_id="${method_type}|new"
readonly verify_url="${host}/me/v1/authentication-methods/${authentication_method_id}/verify"

[[ -n "${opt_verbose}" ]] && {
  echo "Calling ${verify_url}"
  echo "${VERIFY_BODY}"
}

readonly VERIFY_RESPONSE=$(curl -s "${verify_url}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -d "${VERIFY_BODY}")

echo "enrollment successful."

jq . <<< "${VERIFY_RESPONSE}"



