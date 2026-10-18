#!/bin/bash

# Rebuilds configuration profiles from the management settings recorded in an
# export of SPManagedClientDataType data from the system_profiler command line
# tool.
#
# Note: the data must be exported in JSON format. This can be accomplished by
# running the following command:
#
# /usr/sbin/system_profiler SPManagedClientDataType -json > /path/to/data_export_file_goes_here
#
# Usage: managed_client_profile_extractor.sh [-h] [/path/to/data_export_file_goes_here]
#
# The script reads the management settings in the report and writes one
# .mobileconfig file per preference domain into a new temporary directory.
#
# With no file given, the script builds the report from the computer it is
# running on by running the following command:
#
#   /usr/sbin/system_profiler SPManagedClientDataType -json
#
# A report file can have any name and any extension. The script checks the
# contents instead: it must be a System Information Managed Client report
# (SPManagedClientDataType) in JSON format, as system_profiler -json writes it.
# Reports in XML, .spx or binary property list format are not accepted. If a
# file is not formatted as expected, the script stops with an error that says so
# and gives the reason.
#
# HOW IT WORKS
#
#   plutil    reads the text of each dictionary or array setting (old-style plist
#             format) and writes it as JSON, and turns each profile's JSON into
#             the finished .mobileconfig. plutil returns every value in that
#             text as a string.
#   jq        reads the report, restores the value types plutil loses (booleans,
#             integers, decimals, dates), puts each profile together as JSON,
#             and lists the settings of each profile whose type was guessed.
#
# The report stores every value as text and does not record its type, so types
# are guessed from the text and the key name.
#
# LIMITS
#
#   A plain value (a number, a word, a date) is read directly. A dictionary or
#   array is read by plutil, which does not say whether a value was quoted, so:
#   a quoted "123" inside one is treated as the integer 123; a decimal is only
#   treated as a real if its key name suggests a number; and a bare date or
#   bare hex data inside one makes plutil reject the setting, which is then
#   kept as plain text with a warning. Binary data, which the report shows as
#   {length = N, bytes = ...} (usually only the start of it), is not rebuilt and
#   is left out with a warning.
#
# Uses the following command line tools which are included with macOS 15 and later:
#
# /usr/bin/plutil
# /usr/bin/uuidgen
# /usr/sbin/system_profiler
# /usr/bin/jq

# Global variables

INPUT_PATH=""
FROM_HOST=0           # 1 when the report is collected from this computer
WORK_DIR=""           # small intermediate files; always deleted on exit
PROFILE_DIR=""        # the output; kept when at least one profile is created
KEEP_PROFILES=0

created_count=0       # profiles written
item_count=0          # preference domains found in the report
warnings=()
skipped_items=()
nondefault_states=()

# Output and error helpers

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h]
       [/path/to/data_export_file_goes_here]

Rebuilds configuration profiles (.mobileconfig files) from a System Information
Managed Client report (SPManagedClientDataType), one per preference domain. It
only reads: it does not install anything or change any settings.

  /path/to/data_export_file_goes_here
      A Managed Client report saved as JSON, as written by system_profiler
      SPManagedClientDataType -json. The file can have any name and any
      extension.
  -h, --help
      Show this message.

With no file, the report is built from this computer by running:
  /usr/sbin/system_profiler SPManagedClientDataType -json

The profiles are written to a new folder in /tmp named spx_profiles_ followed by
six random characters, together with _recovery_report.txt, which lists the
settings that were written as something other than a string, by type.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Cleanup
#
# The work directory is always removed on exit. The profile directory is the
# deliverable, so it is removed only if the script ends without creating any
# profiles.

cleanup() {
  if [[ -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
  if [[ $KEEP_PROFILES -eq 0 && -d "$PROFILE_DIR" ]]; then rm -rf "$PROFILE_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT     # exiting runs the EXIT trap, so cleanup happens once
trap 'exit 143' TERM

#  Checking for required command line tools
find_tool() {
  # $1 = tool name, $2 = preferred absolute path
  if [[ -x "$2" ]]; then
    echo "$2"
  else
    command -v "$1" 2>/dev/null
  fi
}

require_tools() {
  PLUTIL=$(find_tool plutil /usr/bin/plutil)
  JQ=$(find_tool jq /usr/bin/jq)
  UUIDGEN=$(find_tool uuidgen /usr/bin/uuidgen)
  SYSTEM_PROFILER=$(find_tool system_profiler /usr/sbin/system_profiler)

  local missing=""
  [[ -z "$PLUTIL" ]]  && missing="${missing} plutil"
  [[ -z "$JQ" ]]      && missing="${missing} jq"
  [[ -z "$UUIDGEN" ]] && missing="${missing} uuidgen"
  [[ -z "$SYSTEM_PROFILER" ]] && missing="${missing} system_profiler"

  if [[ -n "$missing" ]]; then
    echo "Error: required tool(s) not found:${missing}" >&2
    echo "plutil, uuidgen and system_profiler ship with macOS. jq is included with macOS 15" >&2
    echo "(Sequoia) and later; on older releases, install it from https://jqlang.org/." >&2
    exit 1
  fi
}

# ── Get the path of the report ────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)  usage; exit 0 ;;
      -*)         usage >&2; die "Unknown option: $1" ;;
      *)          INPUT_PATH="$1" ;;
    esac
    shift
  done
}

get_input_path() {
  if [[ -z "$INPUT_PATH" ]]; then
    FROM_HOST=1
    cat <<EOF
No System Information exported data file was provided, so this script will
create configuration profiles from the management settings installed
on this computer.

To read a System Information report file instead, please provide the path to
the exported data file when you run this script:

/path/to/managed_client_profile_extractor.sh /path/to/data_export_file_goes_here

EOF
    return 0
  fi

  # Strip surrounding quotes the user may have pasted from Finder

  INPUT_PATH="${INPUT_PATH//\'/}"
  INPUT_PATH="${INPUT_PATH//\"/}"

  # Un-escape backslash-escaped spaces from a Terminal drag-and-drop

  INPUT_PATH="${INPUT_PATH//\\ / }"

  # Strip trailing whitespace/newline

  INPUT_PATH="${INPUT_PATH%"${INPUT_PATH##*[![:space:]]}"}"

  # Expand a leading ~

  if [[ "$INPUT_PATH" == "~/"* ]]; then
    INPUT_PATH="${HOME}/${INPUT_PATH#\~/}"
  fi

  [[ ! -d "$INPUT_PATH" ]] || die "${INPUT_PATH} is a folder. Give the path of the report file."
  [[ -f "$INPUT_PATH" ]] || die "File not found: ${INPUT_PATH}"
}

# Builds the report from this computer and saves it in the work directory, where
# the rest of the script reads it as if it were a file that had been given.

collect_host_report() {
  local err="${WORK_DIR}/system_profiler.err"

  INPUT_PATH="${WORK_DIR}/host_report.json"
  "$SYSTEM_PROFILER" SPManagedClientDataType -json > "$INPUT_PATH" 2> "$err" \
    || die "system_profiler could not build the report: $(head -1 "$err" | cut -c1-150)"
  [[ -s "$INPUT_PATH" ]] || die "system_profiler built an empty report."
}

# Stops the script because the input file is not the report it expects.

not_expected() {
  local label="$INPUT_PATH"
  [[ $FROM_HOST -eq 1 ]] && label="The report from system_profiler"
  echo "Error: ${label} was not formatted as expected." >&2
  echo "  ${1}" >&2
  echo "This script reads a System Information \"Managed Client\" report (SPManagedClientDataType)." >&2
  if [[ $FROM_HOST -eq 1 ]]; then
    echo "system_profiler did not return that report for this computer." >&2
  else
    echo "The file can have any name, but its contents must be that report as JSON." >&2
  fi
  exit 1
}

# Confirms the file is a Managed Client report as system_profiler -json writes it:
# an object whose one key, SPManagedClientDataType, holds the list of domains.
# An empty object is accepted as a report with no items.

prepare_report() {
  local kind
  kind=$("$JQ" -r 'if type != "object" then ""
                   elif length == 0 or (.SPManagedClientDataType | type) == "array" then "ok"
                   elif length == 1 and keys[0] != "SPManagedClientDataType" then keys[0]
                   else "" end' "$INPUT_PATH" 2>&1) \
    || not_expected "It is not valid JSON (${kind%%$'\n'*})."
  case "$kind" in
    ok) ;;
    "") not_expected "Its top level is not the object that system_profiler -json writes." ;;
    *)  not_expected "It is a \"${kind:0:60}\" report, not a SPManagedClientDataType report." ;;
  esac
}

# The report stores every setting's value as text, and plutil returns every value
# it reads as a string, so the original types (boolean, integer, decimal, date)
# are lost along the way. This step writes the jq program that guesses them again
# from the value's text and the name of its setting. For example, a 0 or 1 is a
# boolean unless the name suggests a number, such as a level or a count. The
# program also removes the placeholders that stand in for binary data and
# reports them as a warning.
#
# convert_value runs the program once for each setting. It is written to
# a file in the work directory, which is deleted when the script ends.

write_retyper() {
  RETYPER="${WORK_DIR}/retype_value.jq"
  cat > "$RETYPER" <<'JQ_EOF'
# Restores the value types that plutil loses.
#
# Input: one setting's value. It is either a plain string (a value that was read
# directly, with jq -R -s) or what plutil wrote for a dictionary or array as
# JSON, in which every value is a string. This program guesses which strings
# were really booleans, integers, decimals or dates, and removes the values that
# stand in for binary data.
# Argument: $key, the name of the setting, which is used to guess types.
# Output lines:
#   1) a warning, or an empty line
#   2) the setting as a one-line JSON object, {"<key>": <value>}
#
# A date is passed on as the string "@@date:" followed by the date in UTC,
# because JSON has no date type. The script turns it into a <date> after
# plutil has written the profile.

# A 0 or 1 is a boolean unless the key name suggests a number (a level, delay,
# count, type, or "days" anywhere in the name). Names that are clearly flags
# win: every Skip* key in
# Apple's Setup Assistant payload is a Boolean (SkipScreenTime ends in "time",
# which would otherwise look numeric), as are names ending in Enabled/Disabled.
# A decimal is only treated as a real if the key name suggests a number.

def NOT_BOOL: "days|(delay|time|timeout|interval|count|seconds|minutes|hours|size|port|level|limit|max|min|duration|threshold|length|age|retries|mode|type|version|id|number|index|style|position|order|priority|width|height)$";
def NUM_HINT: "(interval|delay|time|timeout|duration|count|days|seconds|minutes|hours|size|port|level|threshold|limit|ratio|scale|opacity|rate)$";
def looksbool:
  test("^Skip|(Enabled|Disabled)$") or (test(NOT_BOOL; "i") | not);

# Guess the type of every string in a value. $name is the setting or dictionary
# key the value belongs to (an array's elements use the array's key); $member is
# true for a dictionary member and false for an array element, which is never a
# boolean.

def retype($name; $member):
  if type == "object" then with_entries(.key as $k | .value |= retype($k; true))
  elif type == "array" then map(retype($name; false))
  elif test("^-?(0|[1-9][0-9]{0,14})$") then
    if $member and (. == "0" or . == "1") and ($name | looksbool) then . == "1"
    else tonumber + 0 end
  elif test("^-?[0-9]+\\.[0-9]+$") and ($name | test(NUM_HINT; "i")) then tonumber
  else . end;

# "2018-01-01 00:00:00 +0000" -> "2018-01-01T00:00:00Z". A date in the report is
# always in UTC (+0000), so only that form is recognised.

def DATE_RE: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \\+0000$";
def utcdate: sub(" "; "T") | sub(" \\+0000$"; "Z");

# Binary data is shown as "<N bytes of data>" (the script rewrites the report's
# {length = N, bytes = ...} to that form). It is not rebuilt, so those values
# are removed and named in a warning instead of being written as junk.

def PLACEHOLDER: "^<[0-9]+ bytes of data>$";

# Main program

[paths(type == "string" and test(PLACEHOLDER))] as $missing
| (if ($missing | length) > 0
   then "binary data could not be rebuilt (" + ($missing | map(map(tostring) | join(" > ")) | join(", ")) + "); it was omitted"
   else "" end),
  (delpaths($missing)
   | if type == "string" and test(DATE_RE) then "@@date:" + utcdate
     else retype($key; true) end
   | {($key): .} | tojson)
JQ_EOF
}

# The report layout is:
#   SPManagedClientDataType (array)     one entry per preference domain
#     _name                             the domain, e.g. com.apple.dock
#     _items (array)                    one entry per managed key
#       _name                           the key
#       data_keyValue                   the value, as TEXT
#       data_source                     "<domain> (Computer)" or similar
#       data_state                      always / often / once
#
# data_keyValue is the Objective-C "description" of the value: a plain value is
# bare text, and a dictionary or array uses the old-style plist text format,
# e.g. "{ Hide = 1; Path = \"/Applications/Foo.app\"; }".
#
# convert_value KEY VALUE
# Turns a setting's text into a JSON object {"<key>": <value>} with its types
# restored. A dictionary or array is read by plutil (which returns every value
# as a string); a plain value is already a string. Then jq restores the types.
# On success (return 0) the object is in $VALUE_JSON and CONV_MESSAGE holds a
# warning or an empty string. On failure (return 1) CONV_MESSAGE says why and
# the setting is left out.

convert_value() {
  local key="$1" value="$2"
  local infile="${WORK_DIR}/value.txt" jsonfile="${WORK_DIR}/value.plutil.json"
  local out="${WORK_DIR}/jq.out" err="${WORK_DIR}/convert.err"
  local trimmed="${value#"${value%%[![:space:]]*}"}"
  local data_re='^\{[[:space:]]*length[[:space:]]*=[[:space:]]*([0-9]+),[[:space:]]*bytes[^}]*\}[[:space:]]*$'
  local flags="-Rrs" source="$infile" note=""      # a plain value: jq reads the file as one string
  CONV_MESSAGE=""
  printf '%s' "$value" > "$infile"

  # The whole value is binary data: there is nothing to keep.
  if [[ "$trimmed" =~ $data_re ]]; then
    CONV_MESSAGE="binary data (${BASH_REMATCH[1]} bytes) could not be rebuilt; setting omitted"
    return 1
  fi

  # Step 1: a dictionary or array is read by plutil, which writes it as JSON.
  # Binary data inside one is rewritten to the "<N bytes of data>" placeholder
  # first. If plutil cannot read the text, the value is kept as plain text.

  case "$trimmed" in
    "{"*|"("*)
      sed -E 's/\{[[:space:]]*length[[:space:]]*=[[:space:]]*([0-9]+),[[:space:]]*bytes[^}]*\}/"<\1 bytes of data>"/g' "$infile" > "${infile}.sed"
      if "$PLUTIL" -convert json -o "$jsonfile" -- "${infile}.sed" 2> "$err"; then
        flags="-r"
        source="$jsonfile"
      else
        note="could not read the text as a dictionary or array ($(head -1 "$err" | sed "s#${infile}.sed: ##" | cut -c1-120)); kept as plain text"
      fi ;;
  esac

  # Step 2: jq restores the types.

  if ! "$JQ" "$flags" --arg key "$key" -f "$RETYPER" "$source" > "$out" 2> "$err"; then
    CONV_MESSAGE="could not be converted ($(head -1 "$err" | sed 's/^jq: error (at [^)]*): //' | cut -c1-120)); setting omitted"
    return 1
  fi

  # jq's first line is a warning (or empty); the rest is the JSON. A value that
  # was kept as plain text has nothing nested for jq to warn about, so the note
  # from step 1 never has a warning to share the message with.

  { IFS= read -r CONV_MESSAGE; cat > "$VALUE_JSON"; } < "$out"
  CONV_MESSAGE="${note:-$CONV_MESSAGE}"
  return 0
}

# Reads every setting in the report and adds it to its profile's group file.
# Settings are grouped by scope and domain: GROUP_DIR/<scope>/g_<domain>.jsonl
# holds one line of JSON per setting, and g_<domain>.keys lists the names used.
# jq lists the usable settings, each as five NUL-ended fields: scope, state,
# domain, key and value. A domain whose name is empty or unsafe is skipped, and
# so is a setting with no name or value, an empty name, or a name that begins
# with "Payload" (a reserved profile key). Entries of any other shape, such as
# a domain that is not an object, are ignored.

process_report() {
  local scope state domain key value group entry
  item_count=$("$JQ" '[(.SPManagedClientDataType // [])[] | objects] | length' "$INPUT_PATH")
  while IFS= read -r entry; do skipped_items+=("$entry"); done < <("$JQ" -r '
    (.SPManagedClientDataType // [])[] | objects | ((._name | strings) // "") as $n
    | select($n | test("^[A-Za-z0-9._-]+$") | not) | if $n == "" then "(unnamed)" else $n end' "$INPUT_PATH")

  while IFS= read -r -d '' scope && IFS= read -r -d '' state && IFS= read -r -d '' domain \
        && IFS= read -r -d '' key && IFS= read -r -d '' value; do
    group="${GROUP_DIR}/${scope}/g_${domain}"
    if grep -qxF -- "$key" "${group}.keys" 2>/dev/null; then
      warnings+=("${domain}: ${key}: appears more than once; the first value was kept")
      continue
    fi
    if ! convert_value "$key" "$value"; then
      warnings+=("${domain}: ${key}: ${CONV_MESSAGE}")
      continue
    fi
    [[ -n "$CONV_MESSAGE" ]] && warnings+=("${domain}: ${key}: ${CONV_MESSAGE}")

    cat "$VALUE_JSON" >> "${group}.jsonl"
    printf '%s\n' "$key" >> "${group}.keys"
    [[ "$state" != "always" ]] && nondefault_states+=("${domain}: ${key} (${state})")
  done < <("$JQ" -j '
    (.SPManagedClientDataType // [])[] | objects
    | select((._name | strings | test("^[A-Za-z0-9._-]+$")) // false)
    | ._name as $domain
    | (._items | arrays[] | objects)
    | select((._name | strings | length > 0 and (startswith("Payload") | not)) // false)
    | select(.data_keyValue | type == "string")
    | (if ((.data_source | strings) // "" | contains("(Computer)")) then "System" else "User" end),
      ((.data_state | strings | select(. != "")) // "always"),
      $domain, ._name, .data_keyValue
    | ., "\u0000"' "$INPUT_PATH")
}

# write_profile SCOPE GROUP_FILE
# Puts one profile together as JSON from the settings in GROUP_FILE, then lets
# plutil write it as a plist, and adds the profile's guessed types to the report. The profile and the payload inside it share a
# display name, organization and version ($common below).

write_profile() {
  local scope="$1" jsonl="$2"
  local domain suffix clean profile_id profile_name profile_path uuid_outer uuid_inner
  local xmlfile="${WORK_DIR}/profile.plutil.xml" err="${WORK_DIR}/convert.err" detail

  domain="${jsonl##*/g_}"
  domain="${domain%.jsonl}"
  [[ "$scope" == "User" ]] && suffix="-user"
  clean="${domain#"${domain%%[!.]*}"}"          # a leading dot would hide the file
  profile_id="com.systeminformation.recovered.${clean}${suffix}"
  profile_name="${clean}${suffix}.mobileconfig"
  profile_path="${PROFILE_DIR}/${profile_name}"

  uuid_outer=$("$UUIDGEN")
  uuid_inner=$("$UUIDGEN")

  if "$JQ" -s -c --arg domain "$domain" --arg id "$profile_id" --arg scope "$scope" \
          --arg outer "$uuid_outer" --arg inner "$uuid_inner" \
          '(add) as $settings
           | {PayloadDisplayName: ("Recovered settings: " + $domain),
              PayloadOrganization: "Recovered from System Information", PayloadVersion: 1} as $common
           | {PayloadContent: [$settings + $common + {PayloadDescription: ("Settings recovered for " + $domain),
                                                      PayloadIdentifier: ($id + ".settings"),
                                                      PayloadType: $domain, PayloadUUID: $inner}],
              PayloadDescription: "Rebuilt from System Information Managed Client (SPManagedClientDataType) data",
              PayloadIdentifier: $id, PayloadScope: $scope,
              PayloadType: "Configuration", PayloadUUID: $outer} + $common' \
          "$jsonl" > "$PROFILE_JSON" 2> "$err" && \
     "$PLUTIL" -convert xml1 -o "$xmlfile" -- "$PROFILE_JSON" 2> "$err" && \
     sed 's#<string>@@date:\([^<]*\)</string>#<date>\1</date>#' "$xmlfile" > "$profile_path"; then
    created_count=$((created_count + 1))
    echo "  Created: ${profile_name} ($(grep -c '' "$jsonl") setting(s))"
    {
      echo "${profile_name}  (scope: ${scope})"
      # One line per type, naming the settings whose type was guessed from text:
      # every key that is not a profile key, at any depth, whose value (or whose
      # array's elements) is a boolean, integer, decimal or date. The kind is read
      # from the JSON that plutil is given: a number with a decimal point is a real.
      "$JQ" -r '
        def kind:
          if type == "boolean" then "bool"
          elif type == "number" then (if tojson | test("[.eE]") then "real" else "integer" end)
          elif type == "string" and startswith("@@date:") then "date"
          else empty end;
        [.. | objects | to_entries[]
         | select(.key != "" and (.key | startswith("Payload") | not))
         | .key as $name | .value | (kind, (arrays[] | kind)) | [., $name]] as $typed
        | {bool: "bool:    ", integer: "integer: ", real: "real:    ", date: "date:    "} as $heading
        | ("bool", "integer", "real", "date") as $t
        | [$typed[] | select(.[0] == $t) | .[1]] | unique
        | select(length > 0) | "  " + $heading[$t] + join(", ")' "$PROFILE_JSON"
      echo ""
    } >> "$REPORT_FILE"
  else
    detail=$(head -1 "$err" | cut -c1-120)
    echo "Warning: ${profile_name} could not be written and was skipped${detail:+ ($detail)}." >&2
    rm -f "$profile_path"
    skipped_items+=("${domain} (the profile could not be written)")
  fi
}

write_profiles() {
  local scope group
  for scope in System User; do
    for group in "${GROUP_DIR}/${scope}"/g_*.jsonl; do
      [[ -e "$group" ]] && write_profile "$scope" "$group"
    done
  done
}

# Tells the user what happened, once every profile has been written.
# What it prints comes from variables filled in along the way: created_count,
# item_count, skipped_items, warnings and nondefault_states.
#
# print_results runs when at least one profile was created. It shows how many
# were created and where they are, then lists anything that was skipped, any
# warnings, and any settings that were not marked "always" in the report. It
# ends with notes on reviewing the result before using it.
#
# print_nothing_created runs when no profile was created, and explains why: the
# report had no items, or it had items but none could be turned into a profile.
# The script then exits with status 2.

print_nothing_created() {
  echo "No configuration profiles could be created."
  echo ""
  if [[ "$item_count" -eq 0 ]]; then
    echo "The managed client report contains no items."
    if [[ $FROM_HOST -eq 1 ]]; then
      echo "This computer does not appear to have any managed settings."
    else
      echo "The Mac may not have had any managed settings when the report was collected."
    fi
  else
    echo "The report contains ${item_count} domain(s), but none produced a valid profile."
    for entry in "${skipped_items[@]}"; do
      echo "  Skipped item: ${entry}"
    done
  fi
  echo ""
}

# print_list TITLE ITEM... : prints a titled list, or nothing if there are no items.
print_list() {
  local title="$1"
  shift
  [[ $# -gt 0 ]] || return 0
  echo "$title"
  for item in "$@"; do
    echo "  ${item}"
  done
  echo ""
}

print_results() {
  echo ""
  echo "--------------------------------------"
  echo "Profiles created: ${created_count}"
  [[ ${#skipped_items[@]} -gt 0 ]] && echo "Items skipped:    ${#skipped_items[@]}"
  [[ $FROM_HOST -eq 1 ]] && echo "Source:           this computer (system_profiler)"
  echo "Location:         ${PROFILE_DIR}"
  echo "--------------------------------------"
  echo ""

  print_list "Skipped:" "${skipped_items[@]}"
  print_list "Warnings:" "${warnings[@]}"
  print_list "These keys were not marked \"always\" in the report. They are written
as normal enforced settings:" "${nondefault_states[@]}"

  cat <<EOF
Notes:
  - The report stores every value as text, so booleans, integers and
    strings were inferred. See _recovery_report.txt in the output
    directory for the settings of each type, and review before use.
  - The profiles are unsigned reconstructions and may contain secrets
    such as API keys and enrollment tokens. Handle them accordingly.

EOF
}

# The summary shows the folder too, but its lists can scroll it out of view,
# so the script ends by saying where the profiles are. It asks nothing, so
# the script never waits for input.

print_location() {
  echo "The configuration profiles are in this folder:"
  echo "  ${PROFILE_DIR}"
  echo ""
}

# Runs the whole script, in this order:
#   1. Read the options and check that the tools the script needs are installed.
#      Then get the path of the report (get_input_path). With no path, the
#      report is built from this computer instead.
#   2. Create a private work folder for intermediate files and a folder for the
#      profiles. If the report is built from this computer, collect it now.
#   3. Write the jq program that restores value types (write_retyper), then
#      check that the report is JSON of the right kind (prepare_report).
#   4. Read each setting in the report (process_report) and write one profile for
#      each preference domain and scope (write_profiles).
#   5. Show the results (print_results), then show where the profile folder is
#      (print_location).
#
# A step that cannot continue (a missing tool, an unreadable file, a file that is
# not formatted as expected) stops the script with an error and exit status 1.
# If no profile could be created, the script says why and exits with status 2.
#
# However the script ends, including Ctrl-C, the EXIT trap near the top deletes
# the work folder, and deletes the profile folder too unless KEEP_PROFILES is 1.
# That is set only once at least one profile has been created.

main() {
  parse_args "$@"
  require_tools

  echo ""
  echo "Managed Client Report Configuration Profile Extractor"
  echo "--------------------------------------"
  echo ""

  get_input_path

  # Working files and directory variables
  #
  # Note: mktemp -d creates directories readable only by this user. This
  # matters because profiles can contain API keys and enrollment tokens.

  WORK_DIR=$(mktemp -d /tmp/spx_work_XXXXXX)
  PROFILE_DIR=$(mktemp -d /tmp/spx_profiles_XXXXXX)
  GROUP_DIR="${WORK_DIR}/groups"
  mkdir -p "${GROUP_DIR}/System" "${GROUP_DIR}/User"
  VALUE_JSON="${WORK_DIR}/value.json"
  PROFILE_JSON="${WORK_DIR}/profile.json"
  REPORT_FILE="${PROFILE_DIR}/_recovery_report.txt"

  [[ $FROM_HOST -eq 1 ]] && collect_host_report
  write_retyper
  prepare_report

  echo "Reading management settings..."
  echo ""

  cat > "$REPORT_FILE" <<EOF
Recovered configuration profile report

Types for the settings below were inferred from text and may need correcting.
Only settings whose value is not a plain string are listed, by type. Values
themselves are intentionally omitted from this report.

EOF

  process_report
  write_profiles

  if [[ $created_count -eq 0 ]]; then
    print_nothing_created
    exit 2
  fi

  KEEP_PROFILES=1
  print_results
  print_location
}

main "$@"