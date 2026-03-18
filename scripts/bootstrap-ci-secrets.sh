#!/usr/bin/env zsh
set -euo pipefail
IFS=$'\n\t'

# Ensure Apple-provided core utils are available even in minimal environments.
typeset -gx PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH-}"

log() {
  print -r -- "[bootstrap] $*" >&2
}

die() {
  print -r -- "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bootstrap-ci-secrets.sh [--force] [--dry-run] [--gh] [--gh-repo OWNER/REPO] [--gh-env ENVIRONMENT]

Generate gitignored local credential handoff file:
  .env.local   - sourceable environment variables for local builds

The script prompts for release/signing values once and writes .env.local.
Use --force to overwrite an existing file after creating a timestamped backup.

If you prefer file-based secrets, place them in the gitignored secrets/ folder:
  - secrets/AuthKey_<ASC_KEY_ID>.p8   (App Store Connect API key)
  - secrets/<anything>.p12           (signing identity export)
The script will detect these and base64-encode them automatically. If it exports
from Keychain, it will also save secrets/signing-cert.p12 for future runs.

GitHub upload uses a curated subset of values (e.g. it intentionally excludes
the machine-local KEYCHAIN_PASSWORD).

Optional GitHub CLI integration:
  --gh                 Upload the GitHub-ready secrets to GitHub using `gh`.
  --gh-repo OWNER/REPO Target a specific repository (recommended).
  --gh-env NAME        Set deployment environment secrets instead of repository secrets.

Notes:
  - Non-interactive uploads require --gh-repo.
  - If --gh-repo is not provided, the script will infer the repo from git remote 'origin'
    and require you to type the repo name to confirm before uploading.

Dry run:
  --dry-run             Run detection/prompts but do not write files or upload secrets.
EOF
}

# Globals (declare early for `set -u` safety)
typeset -gi dry_run=0
typeset -gi has_missing_required=0
typeset -ga missing_required_vars
missing_required_vars=()

record_missing_required() {
  local var_name="$1"
  has_missing_required=1
  missing_required_vars+=("$var_name")
}

show_manual_value_help() {
  local var_name="$1"

  case "$var_name" in
    ASC_KEY_ID)
      cat <<'EOF' >&2
App Store Connect API Key ID:
  1. Open App Store Connect.
     https://appstoreconnect.apple.com/access/integrations/api
  2. Go to Users and Access.
  3. Open the Keys tab.
  4. Create a key or copy the Key ID from an existing one.
EOF
      ;;
    ASC_ISSUER_ID)
      cat <<'EOF' >&2
App Store Connect Issuer ID:
  1. Open App Store Connect.
     https://appstoreconnect.apple.com/access/integrations/api
  2. Go to Users and Access.
  3. Open the Keys tab.
  4. Copy the Issuer ID shown at the top of the page.
EOF
      ;;
    ASC_PRIVATE_KEY_B64)
      cat <<'EOF' >&2
Base64-encoded App Store Connect .p8 key:
  Option A (recommended): put the file in the gitignored secrets/ folder:
       secrets/AuthKey_<KEYID>.p8
     The script will auto-detect it and base64-encode it.

  Option B: encode it yourself:
  1. Create or download the .p8 file from App Store Connect.
  2. Encode it with:
       /usr/bin/base64 < AuthKey_XXXXXX.p8 | tr -d '\n'
  3. The value must be a single line with no whitespace.
EOF
      ;;
    APPLE_CERTIFICATE_P12_B64)
      cat <<'EOF' >&2
Base64-encoded .p12 certificate:
  Option A: put the .p12 in the gitignored secrets/ folder:
       secrets/your-certificate.p12
     The script will base64-encode it, but you must still provide the .p12 export password.
     This is NOT your macOS login keychain password.
     CI uses this password to import the .p12.

     If the script exports from Keychain, it will save the exported .p12 as:
       secrets/signing-cert.p12

  Option B: export & encode it yourself:
  1. Export the signing identity as a .p12 from Keychain Access.
  2. Encode it with:
       /usr/bin/base64 < your-certificate.p12 | tr -d '\n'
  3. The value must be a single line with no whitespace.
EOF
      ;;
  esac
}

typeset -g HELP_SHOWN='|'

maybe_show_manual_value_help() {
  local var_name="$1"
  local marker="|${var_name}|"

  case "$var_name" in
    ASC_KEY_ID|ASC_ISSUER_ID|ASC_PRIVATE_KEY_B64|APPLE_CERTIFICATE_P12_B64)
      ;;
    *)
      return 0
      ;;
  esac

  if [[ "$HELP_SHOWN" == *"$marker"* ]]; then
    return 0
  fi

  show_manual_value_help "$var_name"
  HELP_SHOWN+="${var_name}|"
}

trim_whitespace() {
  local value="$1"
  value="${value#${value%%[!$' \t\r\n']*}}"
  value="${value%${value##*[!$' \t\r\n']}}"
  print -r -- "$value"
}

normalize_value_for_var() {
  local var_name="$1"
  local value="$2"

  case "$var_name" in
    *_B64)
      value="$(print -r -- "$value" | tr -d '[:space:]')"
      ;;
    *)
      value="$(trim_whitespace "$value")"
      ;;
  esac

  print -r -- "$value"
}

encode_file_b64_single_line() {
  local file_path="$1"

  log "Encoding ${file_path:t} as base64 (single line)"
  /usr/bin/base64 < "$file_path" 2>/dev/null | tr -d '[:space:]'
}

b64_decode() {
  local input="$1"
  print -r -- "$input" | /usr/bin/base64 -D 2>/dev/null \
    || print -r -- "$input" | /usr/bin/base64 -d 2>/dev/null \
    || print -r -- "$input" | /usr/bin/base64 --decode 2>/dev/null
}

is_probably_base64() {
  local v="$1"
  [[ -n "$v" ]] || return 1
  [[ "$v" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  return 0
}

validate_asc_private_key_b64() {
  local v="$1"
  local decoded

  is_probably_base64 "$v" || return 1
  decoded="$(b64_decode "$v" | head -n 1 || true)"
  [[ "$decoded" == "-----BEGIN PRIVATE KEY-----"* ]] || return 1
  return 0
}

prompt_file_selection() {
  local prompt="$1"
  shift
  local -a files
  files=("$@")
  local choice total index

  total=${#files[@]}
  if [[ "$total" -eq 0 ]]; then
    return 1
  fi
  if [[ "$total" -eq 1 ]]; then
    print -r -- "${files[1]}"
    return 0
  fi

  print -r -- "$prompt"
  index=1
  while [[ $index -le $total ]]; do
    print -r -- "  $index) ${files[$index]}"
    index=$((index + 1))
  done

  while true; do
    read -r "?Choose a file [1-${total}]: " choice
    choice="${choice:-1}"
    if [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= total )); then
      print -r -- "${files[$choice]}"
      return 0
    fi
    print -r -- "Invalid selection." >&2
  done
}

prompt_value() {
  local var_name="$1"
  local label="$2"
  local required="${3:-1}"
  local secret="${4:-0}"
  local default_value="${5:-}"
  local response normalized

  if (( ${+parameters[$var_name]} )) && [[ -n "${(P)var_name-}" ]]; then
    print -r -- "${(P)var_name-}"
    return 0
  fi

  # Note: `resolve_value` uses command substitution, so stdout is not a TTY even
  # in interactive use. Only check stdin to decide whether we can prompt.
  if [[ ! -t 0 ]]; then
    if [[ "$required" -eq 1 ]]; then
      record_missing_required "$var_name"
    fi
    print -r -- ""
    return 0
  fi

  while true; do
    if [[ "$secret" -eq 1 ]]; then
      if [[ -n "$default_value" ]]; then
        read -rs "?$label [$default_value]: " response
      else
        read -rs "?$label: " response
      fi
      # Newline for nicer UX, but MUST NOT go to stdout because this function's
      # output is frequently captured via $(...).
      print -r -- >&2
    else
      if [[ -n "$default_value" ]]; then
        read -r "?$label [$default_value]: " response
      else
        read -r "?$label: " response
      fi
    fi

    if [[ -z "$response" ]]; then
      response="$default_value"
    fi

    normalized="$(normalize_value_for_var "$var_name" "$response")"

    if [[ "$var_name" == "ASC_PRIVATE_KEY_B64" ]] && [[ "$normalized" == -----BEGIN* ]]; then
      print -r -- "This must be base64 (not the raw .p8 contents). See the instructions above." >&2
      normalized=""
    fi
    if [[ "$var_name" == "APPLE_TEAM_ID" ]] && [[ -n "$normalized" ]] && [[ ! "$normalized" =~ ^[A-Z0-9]{10}$ ]]; then
      print -r -- "Apple Team ID must be exactly 10 letters/numbers (e.g. ABCDE12345)." >&2
      normalized=""
    fi
    if [[ "$var_name" == "ASC_PRIVATE_KEY_B64" ]] && [[ -n "$normalized" ]] && ! validate_asc_private_key_b64 "$normalized"; then
      print -r -- "ASC_PRIVATE_KEY_B64 does not decode to a valid .p8 private key. Re-check the value." >&2
      normalized=""
    fi

    if [[ -n "$normalized" ]]; then
      print -r -- "$normalized"
      return 0
    fi

    if [[ "$required" -eq 0 ]]; then
      print -r -- ""
      return 0
    fi

    print -r -- "This value is required." >&2
  done
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\"\'\"\'}"
  print -r -- "'$value'"
}

write_env_line() {
  local key="$1" value="$2"
  [[ -n "$value" ]] || return 0
  print -r -- "export ${key}=$(shell_quote "$value")"
}

write_gh_line() {
  local key="$1" value="$2"
  [[ -n "$value" ]] || return 0
  print -r -- "${key}=${value}"
}

build_github_secrets_dotenv() {
  # Emit KEY=VALUE lines for GitHub secrets upload.
  # Intentionally excludes local-only values (e.g. KEYCHAIN_PASSWORD).
  write_gh_line "APPLE_TEAM_ID" "$APPLE_TEAM_ID"
  write_gh_line "DEVELOPMENT_TEAM" "$DEVELOPMENT_TEAM"
  write_gh_line "APPLE_CERTIFICATE_P12_B64" "${APPLE_CERTIFICATE_P12_B64-}"
  write_gh_line "APPLE_CERTIFICATE_PASSWORD" "${APPLE_CERTIFICATE_PASSWORD-}"
  write_gh_line "ASC_KEY_ID" "$ASC_KEY_ID"
  write_gh_line "ASC_ISSUER_ID" "$ASC_ISSUER_ID"
  write_gh_line "ASC_PRIVATE_KEY_B64" "$ASC_PRIVATE_KEY_B64"
  write_gh_line "APPLE_ID" "$APPLE_ID"
  write_gh_line "APPLE_APP_SPECIFIC_PASSWORD" "$APPLE_APP_SPECIFIC_PASSWORD"
}

parse_github_repo_from_git_remote() {
  # Return "owner/repo" derived from the git remote 'origin' URL.
  # Supports:
  #   - git@github.com:owner/repo.git
  #   - https://github.com/owner/repo.git
  #   - https://github.com/owner/repo
  local origin_url repo

  command -v git >/dev/null 2>&1 || return 1
  origin_url="$(cd "${repo_root:-.}" && git remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin_url" ]] || return 1

  repo="$(print -r -- "$origin_url" | sed -E 's#^git@github\.com:##; s#^https?://github\.com/##; s#\.git$##')"
  if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    print -r -- "$repo"
    return 0
  fi
  return 1
}

backup_existing_file() {
  local file_path="$1" stamp
  [[ -f "$file_path" ]] || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$file_path" "${file_path}.bak.${stamp}"
  log "Backed up ${file_path:t} -> ${file_path:t}.bak.${stamp}"
}

check_output_path_can_be_written() {
  local file_path="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    if [[ -e "$file_path" ]]; then
      log "[dry-run] Would update ${file_path:t} (existing file present)"
    else
      log "[dry-run] Would create ${file_path:t}"
    fi
    return 0
  fi

  if [[ -e "$file_path" && "$force" -ne 1 ]]; then
    die "$file_path already exists. Re-run with --force to overwrite it."
  fi
  if [[ -e "$file_path" && "$force" -eq 1 ]]; then
    log "Will overwrite existing ${file_path:t} (--force)"
  fi
}

load_env_file_via_subshell() {
  local file_path="$1"
  [[ -f "$file_path" ]] || return 0

  # Only source files that look like our generated output.
  local header
  header="$(head -n 1 "$file_path" 2>/dev/null || true)"
  if [[ "$header" != "# Generated by "*"/bootstrap-ci-secrets.sh"* ]]; then
    log "Skipping ${file_path:t} (unexpected header; not sourcing)"
    return 0
  fi

  local -a keys
  keys=(
    APPLE_CERTIFICATE_IDENTITY_NAME
    APPLE_CERTIFICATE_IDENTITY_SHA1
    APPLE_TEAM_ID
    DEVELOPMENT_TEAM
    FPTN_CODESIGN_IDENTITY
    APPLE_CERTIFICATE_P12_B64
    APPLE_CERTIFICATE_PASSWORD
    KEYCHAIN_PASSWORD
    ASC_KEY_ID
    ASC_ISSUER_ID
    ASC_PRIVATE_KEY_B64
    APPLE_ID
    APPLE_APP_SPECIFIC_PASSWORD
  )

  log "Loading existing ${file_path:t} via subshell (only fills missing values)"

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"

    if (( ! ${+parameters[$key]} )) || [[ -z "${(P)key-}" ]]; then
      value="$(normalize_value_for_var "$key" "$value")"
      typeset -g "$key=$value"
      export "$key"
    fi
  done < <(
    zsh -o errexit -o nounset -o pipefail -c '
      emulate -L zsh
      source -- "$1"
      shift
      for k in "$@"; do
        v="${(P)k-}"
        if [[ -n "$v" ]]; then
          print -r -- "$k=$v"
        fi
      done
    ' zsh "$file_path" "${keys[@]}" 2>/dev/null || true
  )
}

detect_project_team_id() {
  local pbxproj_path="$repo_root/FptnVPN.xcodeproj/project.pbxproj"
  local detected

  [[ -f "$pbxproj_path" ]] || { print -r -- ""; return 0; }
  detected="$(grep -m 1 -E 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$pbxproj_path" | sed -E 's/.*DEVELOPMENT_TEAM = ([A-Z0-9]{10});.*/\1/' || true)"
  print -r -- "$detected"
}

detect_default_keychain() {
  local keychain
  keychain="$(security default-keychain -d user 2>/dev/null | tr -d '"' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
  if [[ -z "$keychain" ]]; then
    keychain="$(security list-keychains -d user 2>/dev/null | head -n 1 | tr -d '"' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
  fi
  if [[ -z "$keychain" ]]; then
    keychain="$HOME/Library/Keychains/login.keychain-db"
  fi
  print -r -- "$keychain"
}

typeset -ga AVAILABLE_CODESIGN_IDENTITY_NAMES
typeset -ga AVAILABLE_CODESIGN_IDENTITY_HASHES
typeset -g SELECTED_CODESIGN_IDENTITY_NAME=""
typeset -g SELECTED_CODESIGN_IDENTITY_HASH=""
typeset -g CERT_EXPORT_FAILED=0

collect_codesign_identities() {
  local line hash name
  local -a all_names all_hashes apple_names apple_hashes

  AVAILABLE_CODESIGN_IDENTITY_NAMES=()
  AVAILABLE_CODESIGN_IDENTITY_HASHES=()
  all_names=(); all_hashes=(); apple_names=(); apple_hashes=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    hash="${line%%|*}"
    name="${line#*|}"
    [[ -n "$hash" && -n "$name" ]] || continue
    all_names+=("$name")
    all_hashes+=("$hash")
    if [[ "$name" == Apple\ Development* || "$name" == Apple\ Distribution* || "$name" == Mac\ Developer* ]]; then
      apple_names+=("$name")
      apple_hashes+=("$hash")
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]*([A-F0-9]+)[[:space:]]+"([^"]+)".*/\1|\2/p')

  if (( ${#apple_names[@]} > 0 )); then
    AVAILABLE_CODESIGN_IDENTITY_NAMES=("${apple_names[@]}")
    AVAILABLE_CODESIGN_IDENTITY_HASHES=("${apple_hashes[@]}")
  else
    AVAILABLE_CODESIGN_IDENTITY_NAMES=("${all_names[@]}")
    AVAILABLE_CODESIGN_IDENTITY_HASHES=("${all_hashes[@]}")
  fi

  (( ${#AVAILABLE_CODESIGN_IDENTITY_NAMES[@]} > 0 ))
}

prompt_codesign_identity_selection() {
  local choice total idx
  total=${#AVAILABLE_CODESIGN_IDENTITY_NAMES[@]}
  (( total > 0 )) || return 1

  print -r -- "Available code signing identities:"
  idx=1
  while [[ $idx -le $total ]]; do
    print -r -- "  $idx) ${AVAILABLE_CODESIGN_IDENTITY_NAMES[$idx]} [${AVAILABLE_CODESIGN_IDENTITY_HASHES[$idx]}]"
    idx=$((idx + 1))
  done

  while true; do
    read -r "?Choose an identity to export [1-${total}]: " choice
    choice="${choice:-1}"
    if [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= total )); then
      SELECTED_CODESIGN_IDENTITY_NAME="${AVAILABLE_CODESIGN_IDENTITY_NAMES[$choice]}"
      SELECTED_CODESIGN_IDENTITY_HASH="${AVAILABLE_CODESIGN_IDENTITY_HASHES[$choice]}"
      return 0
    fi
    print -r -- "Invalid selection." >&2
  done
}

request_sudo_access() {
  print -r -- "The certificate export step may require sudo approval before it can run."
  sudo -v || return 1
}

generate_password() {
  if command -v uuidgen >/dev/null 2>&1; then
    print -r -- "$(uuidgen | tr -d '-' )$(uuidgen | tr -d '-')"
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '[:space:]'
  else
    print -r -- "$(date +%s)$(id -u)$(hostname)" | shasum | awk '{print $1}'
  fi
}

manual_export_help() {
  cat <<'EOF'
Unable to export the selected signing identity automatically.

The script tried to acquire the .p12 from Keychain, but that did not work.

What to check:
  1. The selected certificate must include its private key in Keychain Access.
  2. The login keychain must be unlocked.
  3. If macOS asks for permission, allow access for `security` and `codesign`.
  4. If this still fails, export the identity manually from Keychain Access
     as a .p12 file, then base64-encode it with:
       /usr/bin/base64 < your-certificate.p12 | tr -d '\n'

If you want to retry after fixing the keychain, run the script again.
EOF
}

export_selected_identity_p12_b64() {
  local selected_hash="$1"
  local export_password="$2"

  # Use a subshell so an EXIT trap performs function-scoped cleanup in zsh.
  (
    local keychain_path temp_dir temp_export temp_keychain temp_p12
    local -a temp_hashes
    local line hash

    keychain_path="$(detect_default_keychain)"
    log "Using default keychain: ${keychain_path}"

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fptn-cert-export.XXXXXX")"
    cleanup_temp_dir() { rm -rf "$temp_dir"; }
    trap cleanup_temp_dir EXIT INT TERM HUP
    temp_export="$temp_dir/all-identities.p12"
    temp_keychain="$temp_dir/selected.keychain-db"
    temp_p12="$temp_dir/selected.p12"

    if [[ ! -e "$keychain_path" ]]; then
      die "Could not find a readable login keychain at: $keychain_path"
    fi

    log "Exporting identities from keychain (temporary .p12)"
    if ! security export -k "$keychain_path" -t identities -f pkcs12 -P "$export_password" -o "$temp_export" >/dev/null 2>&1; then
      exit 1
    fi

    log "Creating temporary keychain"
    if ! security create-keychain -p "$export_password" "$temp_keychain" >/dev/null 2>&1; then
      exit 1
    fi
    security unlock-keychain -p "$export_password" "$temp_keychain" >/dev/null 2>&1 || true

    log "Importing identities into temporary keychain"
    if ! security import "$temp_export" -k "$temp_keychain" -f pkcs12 -P "$export_password" -T /usr/bin/security -T /usr/bin/codesign >/dev/null 2>&1; then
      exit 1
    fi

    temp_hashes=()
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      hash="${line%%|*}"
      [[ -n "$hash" ]] || continue
      temp_hashes+=("$hash")
    done < <(security find-identity -v -p codesigning "$temp_keychain" 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]*([A-F0-9]+)[[:space:]]+".*/\1|x/p')

    for hash in "${temp_hashes[@]}"; do
      if [[ "$hash" != "$selected_hash" ]]; then
        security delete-identity -Z "$hash" "$temp_keychain" >/dev/null 2>&1 || true
      fi
    done
    log "Pruned temporary keychain to selected identity"

    if ! security export -k "$temp_keychain" -t identities -f pkcs12 -P "$export_password" -o "$temp_p12" >/dev/null 2>&1; then
      exit 1
    fi
    log "Exported selected identity .p12"

    # Persist the exported p12 into secrets/ for easier future runs (gitignored).
    if [[ "$dry_run" -eq 0 ]]; then
      mkdir -p "$secrets_dir" 2>/dev/null || true
      local secrets_p12
      secrets_p12="$secrets_dir/signing-cert.p12"
      if [[ -e "$secrets_p12" && "$force" -ne 1 ]]; then
        log "secrets/signing-cert.p12 already exists; not overwriting (use --force to overwrite)"
      else
        cp "$temp_p12" "$secrets_p12"
        chmod 600 "$secrets_p12" 2>/dev/null || true
        log "Saved exported .p12 to secrets/signing-cert.p12"
      fi
    fi

    local encoded
    encoded="$(/usr/bin/base64 < "$temp_p12" | tr -d '[:space:]')"
    print -r -- "$encoded"
  )
}

bootstrap_certificate_from_secrets_dir() {
  local selected_p12 p12_b64
  local -a p12_files
  p12_files=()

  [[ -d "$secrets_dir" ]] || return 1
  p12_files=("$secrets_dir"/*.p12(N))
  (( ${#p12_files[@]} > 0 )) || return 1

  log "Found .p12 file(s) in secrets/"
  selected_p12="$(prompt_file_selection "Found multiple .p12 files in secrets/." "${p12_files[@]}")" || return 1
  log "Using .p12: ${selected_p12:t}"

  if (( ! ${+APPLE_CERTIFICATE_PASSWORD} )) || [[ -z "${APPLE_CERTIFICATE_PASSWORD-}" ]]; then
    maybe_show_manual_value_help APPLE_CERTIFICATE_P12_B64
    print -r -- "If you don't know the existing .p12 password, type SKIP to export from Keychain instead (the script will generate a random password)." >&2
    APPLE_CERTIFICATE_PASSWORD="$(prompt_value APPLE_CERTIFICATE_PASSWORD "Password for ${selected_p12:t} (.p12 export password used by CI; type SKIP to auto-export)" 1 1)"
    if [[ "${APPLE_CERTIFICATE_PASSWORD:u}" == "SKIP" ]]; then
      log "User chose to skip secrets/ .p12 and use Keychain export instead"
      unset APPLE_CERTIFICATE_PASSWORD
      return 1
    fi
    export APPLE_CERTIFICATE_PASSWORD
  fi

  p12_b64="$(encode_file_b64_single_line "$selected_p12")" || return 1
  APPLE_CERTIFICATE_P12_B64="$(normalize_value_for_var APPLE_CERTIFICATE_P12_B64 "$p12_b64")"
  export APPLE_CERTIFICATE_P12_B64
  log "Prepared APPLE_CERTIFICATE_P12_B64 from .p12"
  return 0
}

detect_asc_from_secrets_dir() {
  local selected_p8 path_b64 key_id
  local -a p8_files
  p8_files=()

  [[ -d "$secrets_dir" ]] || return 0
  p8_files=("$secrets_dir"/AuthKey_*.p8(N))
  (( ${#p8_files[@]} > 0 )) || return 0

  log "Found App Store Connect .p8 key(s) in secrets/"
  selected_p8="$(prompt_file_selection "Found multiple App Store Connect .p8 keys in secrets/." "${p8_files[@]}")" || return 0
  log "Using .p8: ${selected_p8:t}"

  if [[ "$initial_asc_key_id_set" -eq 0 ]]; then
    key_id="${selected_p8:t}"
    key_id="${key_id#AuthKey_}"
    key_id="${key_id%.p8}"
    if [[ "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
      ASC_KEY_ID="$key_id"
      export ASC_KEY_ID
      log "Derived ASC_KEY_ID from filename"
    fi
  fi

  if [[ "$initial_asc_private_key_b64_set" -eq 0 ]]; then
    path_b64="$(encode_file_b64_single_line "$selected_p8")" || return 0
    path_b64="$(normalize_value_for_var ASC_PRIVATE_KEY_B64 "$path_b64")"
    if validate_asc_private_key_b64 "$path_b64"; then
      ASC_PRIVATE_KEY_B64="$path_b64"
      export ASC_PRIVATE_KEY_B64
      log "Prepared ASC_PRIVATE_KEY_B64 from .p8"
    else
      log "Detected .p8 but produced invalid base64; ignoring"
    fi
  fi
}

bootstrap_certificate_from_keychain() {
  local exported

  # Never attempt interactive identity selection in non-TTY runs.
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi

  if (( ${+APPLE_CERTIFICATE_P12_B64} )) && [[ -n "${APPLE_CERTIFICATE_P12_B64-}" ]]; then
    return 0
  fi

  collect_codesign_identities || return 1
  log "Enumerated ${#AVAILABLE_CODESIGN_IDENTITY_NAMES[@]} code signing identity candidate(s)"
  prompt_codesign_identity_selection || return 1

  [[ -n "$SELECTED_CODESIGN_IDENTITY_NAME" && -n "$SELECTED_CODESIGN_IDENTITY_HASH" ]] || return 1
  APPLE_CERTIFICATE_IDENTITY_NAME="$SELECTED_CODESIGN_IDENTITY_NAME"
  APPLE_CERTIFICATE_IDENTITY_SHA1="$SELECTED_CODESIGN_IDENTITY_HASH"
  export APPLE_CERTIFICATE_IDENTITY_NAME APPLE_CERTIFICATE_IDENTITY_SHA1

  log "Selected identity: ${APPLE_CERTIFICATE_IDENTITY_NAME}"
  APPLE_CERTIFICATE_PASSWORD="$(generate_password)"
  export APPLE_CERTIFICATE_PASSWORD
  print -r -- "Generated certificate export password for the .p12 automatically."
  print -r -- "Attempting to acquire the .p12 from Keychain automatically..."

  if ! request_sudo_access; then
    CERT_EXPORT_FAILED=1
    return 1
  fi
  if exported="$(export_selected_identity_p12_b64 "$SELECTED_CODESIGN_IDENTITY_HASH" "$APPLE_CERTIFICATE_PASSWORD")"; then
    APPLE_CERTIFICATE_P12_B64="$exported"
    export APPLE_CERTIFICATE_P12_B64
    FPTN_CODESIGN_IDENTITY="$SELECTED_CODESIGN_IDENTITY_NAME"
    export FPTN_CODESIGN_IDENTITY
    print -r -- "Acquired the .p12 from Keychain automatically."
    return 0
  fi

  CERT_EXPORT_FAILED=1
  return 1
}

resolve_value() {
  local var_name="$1"
  local detected_value="$2"
  local prompt_label="${3:-}"
  local required="${4:-1}"
  local secret="${5:-0}"
  local allow_prompt="${6:-1}"

  if (( ${+parameters[$var_name]} )) && [[ -n "${(P)var_name-}" ]]; then
    print -r -- "$(normalize_value_for_var "$var_name" "${(P)var_name-}")"
    return 0
  fi

  if [[ -n "$detected_value" ]]; then
    print -r -- "$(normalize_value_for_var "$var_name" "$detected_value")"
    return 0
  fi

  if [[ "$allow_prompt" -eq 1 && -n "$prompt_label" ]]; then
    maybe_show_manual_value_help "$var_name"
    print -r -- "$(prompt_value "$var_name" "$prompt_label" "$required" "$secret")"
    return 0
  fi

  if [[ "$required" -eq 1 ]]; then
    record_missing_required "$var_name"
  fi
  print -r -- ""
}

upload_github_secrets_with_gh() {
  local -a gh_cmd
  local target_repo resolved_repo confirm

  if [[ "$use_gh" -ne 1 ]]; then
    return 0
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] Skipping gh upload"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || die "--gh was provided but GitHub CLI (gh) is not installed"

  if [[ -n "$gh_repo" ]]; then
    target_repo="$gh_repo"
  else
    target_repo="$(parse_github_repo_from_git_remote || true)"
  fi

  if [[ -z "$target_repo" ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      die "Non-interactive upload requires --gh-repo OWNER/REPO to avoid targeting the wrong repository."
    fi
    read -r "?Enter target GitHub repo as OWNER/REPO (blank to abort): " target_repo
    target_repo="$(trim_whitespace "${target_repo:-}")"
    [[ -n "$target_repo" ]] || die "Aborted GitHub upload."
  fi

  if [[ ! "$target_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    die "Invalid --gh-repo value: '$target_repo' (expected OWNER/REPO)"
  fi

  gh_cmd=(gh secret set -f -)
  gh_cmd+=(--repo "$target_repo")
  if [[ -n "$gh_env" ]]; then
    gh_cmd+=(--env "$gh_env")
  fi

  resolved_repo="$(cd "$repo_root" && gh repo view --repo "$target_repo" --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  resolved_repo="${resolved_repo:-"$target_repo"}"

  if [[ -n "$gh_env" ]]; then
    print -r -- "Uploading secrets via gh to: ${resolved_repo} (environment: ${gh_env})"
  else
    print -r -- "Uploading secrets via gh to: ${resolved_repo} (repository secrets)"
  fi

  # Safety: if the user didn't explicitly provide --gh-repo, require a strong confirmation.
  if [[ -z "$gh_repo" ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      die "Non-interactive upload requires --gh-repo OWNER/REPO to avoid targeting the wrong repository."
    fi
    print -r -- "About to upload secrets to GitHub repo: ${resolved_repo}" >&2
    read -r "?Type '${resolved_repo}' to confirm: " confirm
    confirm="$(trim_whitespace "${confirm:-}")"
    if [[ "$confirm" != "$resolved_repo" ]]; then
      die "Aborted: confirmation did not match. Re-run with --gh-repo ${resolved_repo} if you intended this target."
    fi
  fi

  build_github_secrets_dotenv | "${gh_cmd[@]}"
}

maybe_offer_gh_upload() {
  local response

  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] Skipping gh upload"
    return 0
  fi

  if [[ "$use_gh" -eq 1 ]]; then
    log "--gh provided; uploading secrets via gh"
    upload_github_secrets_with_gh
    return $?
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] Skipping optional gh upload prompt"
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    log "Non-interactive run; skipping optional gh upload prompt"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    log "GitHub CLI (gh) not installed; skipping optional upload prompt"
    return 0
  fi

  read -r "?Upload secrets to GitHub now using gh? [y/N]: " response
  response="$(trim_whitespace "${response:-}")"
  if [[ "$response" == (y|Y|yes|YES) ]]; then
    use_gh=1
    log "User opted in to gh upload"
    upload_github_secrets_with_gh
  else
    log "User declined gh upload"
  fi
}

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
env_file="$repo_root/.env.local"
secrets_dir="$repo_root/secrets"

force=0
use_gh=0
gh_repo=""
gh_env=""

# Track values explicitly set in the environment BEFORE loading any files.
initial_asc_key_id_set=0
initial_asc_private_key_b64_set=0
if (( ${+ASC_KEY_ID} )) && [[ -n "${ASC_KEY_ID-}" ]]; then
  initial_asc_key_id_set=1
fi
if (( ${+ASC_PRIVATE_KEY_B64} )) && [[ -n "${ASC_PRIVATE_KEY_B64-}" ]]; then
  initial_asc_private_key_b64_set=1
fi

while (( $# > 0 )); do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --gh)
      use_gh=1
      shift
      ;;
    --gh-repo)
      (( $# >= 2 )) || die "--gh-repo requires OWNER/REPO"
      gh_repo="$2"
      shift 2
      ;;
    --gh-env)
      (( $# >= 2 )) || die "--gh-env requires an environment name"
      gh_env="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

log "Repo root: ${repo_root}"
if [[ -d "$secrets_dir" ]]; then
  log "Secrets folder present: ${secrets_dir}"
fi

if [[ -f "$env_file" ]]; then
  load_env_file_via_subshell "$env_file"
fi

# If an old run left a poisoned ASC_PRIVATE_KEY_B64, ignore it.
if (( ${+ASC_PRIVATE_KEY_B64} )) && [[ -n "${ASC_PRIVATE_KEY_B64-}" ]] && ! validate_asc_private_key_b64 "$ASC_PRIVATE_KEY_B64"; then
  log "Existing ASC_PRIVATE_KEY_B64 is invalid; will regenerate/prompt"
  unset ASC_PRIVATE_KEY_B64
fi

# Prefer pulling secrets from the gitignored secrets/ folder when present.
detect_asc_from_secrets_dir || true

check_output_path_can_be_written "$env_file"

log "Generating .env.local"

if (( ! ${+APPLE_CERTIFICATE_P12_B64} )) || [[ -z "${APPLE_CERTIFICATE_P12_B64-}" ]]; then
  bootstrap_certificate_from_secrets_dir || true
  if (( ! ${+APPLE_CERTIFICATE_P12_B64} )) || [[ -z "${APPLE_CERTIFICATE_P12_B64-}" ]]; then
    log "No usable .p12 found in secrets/; attempting Keychain export"
    bootstrap_certificate_from_keychain || true
  fi
fi

if [[ "$CERT_EXPORT_FAILED" -eq 1 ]] && { (( ! ${+APPLE_CERTIFICATE_P12_B64} )) || [[ -z "${APPLE_CERTIFICATE_P12_B64-}" ]]; }; then
  manual_export_help
  exit 1
fi

APPLE_TEAM_ID="$(resolve_value APPLE_TEAM_ID "$(detect_project_team_id)" "Apple Team ID (10 characters)" 1 0 1)"
export APPLE_TEAM_ID

DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
export DEVELOPMENT_TEAM

FPTN_CODESIGN_IDENTITY="${FPTN_CODESIGN_IDENTITY-}"
APPLE_CERTIFICATE_P12_B64="${APPLE_CERTIFICATE_P12_B64-}"
APPLE_CERTIFICATE_PASSWORD="${APPLE_CERTIFICATE_PASSWORD-}"

KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD-}"
if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
  KEYCHAIN_PASSWORD="$(generate_password)"
  export KEYCHAIN_PASSWORD
fi

ASC_KEY_ID="$(resolve_value ASC_KEY_ID "" "App Store Connect API Key ID" 1 0 1)"
export ASC_KEY_ID
ASC_ISSUER_ID="$(resolve_value ASC_ISSUER_ID "" "App Store Connect Issuer ID" 1 0 1)"
export ASC_ISSUER_ID
ASC_PRIVATE_KEY_B64="$(resolve_value ASC_PRIVATE_KEY_B64 "" "Base64-encoded App Store Connect .p8 key" 1 1 1)"
export ASC_PRIVATE_KEY_B64

APPLE_ID="$(resolve_value APPLE_ID "" "Apple ID email for notarization (optional)" 0 0 1)"
export APPLE_ID
APPLE_APP_SPECIFIC_PASSWORD="$(resolve_value APPLE_APP_SPECIFIC_PASSWORD "" "Apple app-specific password (optional)" 0 1 1)"
export APPLE_APP_SPECIFIC_PASSWORD

if [[ "$has_missing_required" -eq 1 ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    log "[dry-run] Missing required values: ${missing_required_vars[*]}"
  else
    die "Missing required values: ${missing_required_vars[*]}"
  fi
fi

if [[ "$dry_run" -eq 0 ]]; then
  tmp_env_file="$(mktemp "${TMPDIR:-/tmp}/fptn-env.XXXXXX")"
  cleanup_tmp_files() { rm -f "$tmp_env_file"; }
  trap cleanup_tmp_files EXIT

  {
    print -r -- "# Generated by ${script_dir}/bootstrap-ci-secrets.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')"
    print -r -- "# Source this file in a shell before running local build helpers."
    write_env_line "APPLE_CERTIFICATE_IDENTITY_NAME" "${APPLE_CERTIFICATE_IDENTITY_NAME-}"
    write_env_line "APPLE_CERTIFICATE_IDENTITY_SHA1" "${APPLE_CERTIFICATE_IDENTITY_SHA1-}"
    write_env_line "APPLE_TEAM_ID" "$APPLE_TEAM_ID"
    write_env_line "DEVELOPMENT_TEAM" "$DEVELOPMENT_TEAM"
    write_env_line "FPTN_CODESIGN_IDENTITY" "${FPTN_CODESIGN_IDENTITY-}"
    write_env_line "APPLE_CERTIFICATE_P12_B64" "${APPLE_CERTIFICATE_P12_B64-}"
    write_env_line "APPLE_CERTIFICATE_PASSWORD" "${APPLE_CERTIFICATE_PASSWORD-}"
    write_env_line "KEYCHAIN_PASSWORD" "$KEYCHAIN_PASSWORD"
    write_env_line "ASC_KEY_ID" "$ASC_KEY_ID"
    write_env_line "ASC_ISSUER_ID" "$ASC_ISSUER_ID"
    write_env_line "ASC_PRIVATE_KEY_B64" "$ASC_PRIVATE_KEY_B64"
    write_env_line "APPLE_ID" "$APPLE_ID"
    write_env_line "APPLE_APP_SPECIFIC_PASSWORD" "$APPLE_APP_SPECIFIC_PASSWORD"
  } > "$tmp_env_file"
fi

if [[ "$dry_run" -eq 0 ]]; then
  # Only after we've successfully generated the file: backup+replace atomically.
  if [[ -e "$env_file" ]]; then
    backup_existing_file "$env_file"
  fi
  mv -f "$tmp_env_file" "$env_file"
  trap - EXIT
fi

if [[ "$dry_run" -eq 0 ]]; then
  chmod 600 "$env_file" 2>/dev/null || true
fi

if [[ "$dry_run" -eq 0 ]]; then
  maybe_offer_gh_upload || {
    print -r -- "warning: failed to upload secrets with gh" >&2
  }
else
  maybe_offer_gh_upload || true
fi

print -r -- "Auto-detected values:"
print -r -- "  Apple Team ID: ${APPLE_TEAM_ID}"
if [[ -n "${APPLE_CERTIFICATE_IDENTITY_NAME-}" ]]; then
  print -r -- "  Certificate identity: ${APPLE_CERTIFICATE_IDENTITY_NAME}"
fi
if [[ -n "${FPTN_CODESIGN_IDENTITY-}" ]]; then
  print -r -- "  Signing identity: ${FPTN_CODESIGN_IDENTITY}"
fi
print -r -- "  Keychain password: generated automatically"
if [[ -n "${APPLE_CERTIFICATE_PASSWORD-}" ]]; then
  print -r -- "  P12 export password: generated automatically"
fi
print -r --
if [[ "$dry_run" -eq 1 ]]; then
  print -r -- "[dry-run] Would create/update: ${env_file}"
else
  print -r -- "Created: ${env_file}"
fi
print -r --
print -r -- "Next steps:"
print -r -- "  1. source .env.local"
print -r -- "  2. run your build/release workflow"
