# Project Guidelines for Auth0 MyAccount Bash Scripts

## Project Overview
Auth0 MyAccount Bash Scripts is a comprehensive collection of Bash scripts designed to interact with Auth0's [MyAccount API](https://auth0.com/docs/api/myaccount).

## Project Structure
The repository is organized into directories that correspond to Auth0 features and resources:

- **factors/** : scripts for factors enabled at the tenant level
- **authentication-methods/** : scripts for authentication methods belonging to the authenticated user.

## Usage Guidelines
1. Most scripts require an Auth0 MyAccount API access token, which can be provided via:
    - Command-line argument: `-a <token>`
    - Environment variable: `export access_token=<token>`

2. Scripts provide detailed usage instructions when run with the `-h` flag.

3. Scripts validate that the access token has the required scopes before making API requests. The `host` used is extracted from `iss` value of the access_token.

4. Common parameters across scripts include:
    - `-e <file>`: Path to .env file for environment variables. default is `pwd`
    - `-v`: Verbose mode for debugging
    - `-h`: Display help/usage information
    - `-t tenant`: Auth0 tenant in the format of tenant@region if needed
    - `-d domain`: fully qualified Auth0 domain if needed
    - `-a token`: access_token

## Code Style Guidelines
1. Follow the existing pattern for script structure:
    - Start with shebang (`#!/usr/bin/env bash`)
    - Include header with author, date, and license information
    - Set `set -euo pipefail` for error handling
    - Define a usage function
    - Process command-line arguments with `getopts`
    - Check for external commands using `command -v`
    - Prefer `$(command)` over backticks
    - Always quote variables to prevent word splitting
    - Always use `${variable}` notation
    - Validate required parameters
    - Perform the API request with `curl`
    - Produce portable code that works in Linux and MacOS. Avoid platform-specific commands without portable alternatives
    - Use latest features and syntax in Bash 5
    - Maintain bash scripting best practices
    - When a functionality is not available in native Bash, use other portable commands like `jq`, `grep`, `openssl`, `sed` and `awk`
    - Try to keep arguments consistent across different scripts

2. Maintain consistent error handling:
    - Check for required parameters
    - Validate access token scopes
    - Provide meaningful error messages

3. Keep scripts focused on a single Auth0 operation

4. Use descriptive variable names and add comments for complex logic

5. Use `./authentication-methods/list-authentication-methods.sh` as a template for generating other scripts.