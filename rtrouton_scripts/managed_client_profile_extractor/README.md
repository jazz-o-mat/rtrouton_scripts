This script is designed to create macOS configuration profiles from the managed settings that the **System Information** app or the `system_profiler` tool reports on.

`managed_client_profile_extractor.sh` reads a **Managed Client** report (`SPManagedClientDataType`) file in JSON format, either from the Mac it runs on or from a existing report file created earlier, and writes the settings in it back out as `.mobileconfig` configuration profiles, one per preference domain. This script does not alter or change any of the settings - this is a read-only process.

## Background

System Information's Managed Client report lists the settings a Mac is currently managed with: 

* The preference domain
* The key
* The value (as text)
* Whether it applies to the computer or to a user
* How often it is enforced.

This is a read-only list and cannot be edited or reviewed in a profile editor. This script takes the information in that list and uses it to create configuration profile files.

**Important Note**:

The configuration profile files produced by this script are **reconstructions**. They are _**not**_ copies of the original profile(s) deployed to a Mac. There _**will**_  be differences between the reconstructed profiles and the actual deployed profiles. For example:

- The report doesn't include the original profile's identifier, UUID, display name or other payloads, so the script generates new ones.
- The report stores every value as text and doesn't record its type, so the script has to guess whether a value is a boolean, an integer, a decimal, a date or a string. See [How types are guessed](#how-types-are-guessed).

The reconstructed profiles are intended for **reference** use only. _**Do not**_ use the reconstructed profile files for any other purpose, including for deployment to other Macs. 

## Requirements

This script uses the following command line tools and checks for all of them as part of running the script. If any cannot be found, the script exits with a message describing which tools are missing.

| Tool | Usual location | Notes |
| --- | --- | --- |
| `plutil` | `/usr/bin/plutil` | |
| `uuidgen` | `/usr/bin/uuidgen` | |
| `system_profiler` | `/usr/sbin/system_profiler` | |
| `jq` | `/usr/bin/jq` | Included with macOS 15 (Sequoia) and later. On older releases, install it from <https://jqlang.org/>. |

## Usage

```
managed_client_profile_extractor.sh [-h] /path/to/data_export_file_goes_here
```

### Read the Managed Client settings from the Mac you are on

Use the command shown below:

```
/path/to/managed_client_profile_extractor.sh
```

### Read Managed Client settings from a report file

Create and save a Managed Client settings report as a JSON file, on this Mac or another one, and provide the path to the report file to the script . For example, if you wanted to create a report file named `managed_client_report.json` and store it on your Desktop, you would use the command shown below:

```
/usr/sbin/system_profiler SPManagedClientDataType -json > $HOME/Desktop/managed_client_report.json
```

You would then use the following command to run the script and reference the report file.

```
/path/to/managed_client_profile_extractor.sh $HOME/Desktop/managed_client_report.json
```

- The file can have any name and any extension. The script checks the contents of the file for the expected System Information report of type `SPManagedClientDataType`, in the JSON format that `system_profiler -json` writes.
- Reports in other formats are not accepted: an XML report (from `-xml`), a `.spx` file saved from System Information, and a binary property list are all refused with a message.
- If the file isn't that report, the script stops, says so, and gives the reason. See [Troubleshooting](#troubleshooting).

`-h` or `--help` prints a short usage message.

## Operation

When the script runs and creates the configuration profile files, the files are written to a new folder in `/tmp` named `spx_profiles_` followed by six random characters. The folder is created so that only your account can read it. The script reports this location as part of its run.

```
spx_profiles_E4arh9/
├── _recovery_report.txt
├── com.apple.SetupAssistant.managed.mobileconfig
├── com.apple.Terminal.mobileconfig
├── com.apple.finder.mobileconfig
└── ...
```

### Profile files

- There is one profile per preference domain and scope. The file name is the domain plus `.mobileconfig`. A leading dot is removed so the file isn't hidden (`.GlobalPreferences` becomes `GlobalPreferences.mobileconfig`).
- Settings the report doesn't mark as computer-level go into a separate profile named `<domain>-user.mobileconfig`, with the scope set to `User`. Computer-level settings have the scope `System`.
- Each profile holds a single payload whose `PayloadType` is the preference domain, and the settings are keys in that payload.
- The identifiers are `com.systeminformation.recovered.<domain>` (with `-user` added for user scope), and the payload's identifier adds `.settings`. The UUIDs are newly generated every time the script runs, so they are never the originals.

A trimmed example (the UUIDs are random, and `…` marks omitted lines):

```xml
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadDescription</key>
      <string>Settings recovered for com.apple.SetupAssistant.managed</string>
      <key>PayloadDisplayName</key>
      <string>Recovered settings: com.apple.SetupAssistant.managed</string>
      <key>PayloadIdentifier</key>
      <string>com.systeminformation.recovered.com.apple.SetupAssistant.managed.settings</string>
      <key>PayloadOrganization</key>
      <string>Recovered from System Information</string>
      <key>PayloadType</key>
      <string>com.apple.SetupAssistant.managed</string>
      <key>PayloadUUID</key>
      <string>XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>SkipAccessibility</key>
      <true/>
      <key>SkipSetupItems</key>
      <array>
        <string>Diagnostics</string>
        <string>FileVault</string>
        …
      </array>
      …
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Rebuilt from System Information Managed Client (SPManagedClientDataType) data</string>
  <key>PayloadDisplayName</key>
  <string>Recovered settings: com.apple.SetupAssistant.managed</string>
  <key>PayloadIdentifier</key>
  <string>com.systeminformation.recovered.com.apple.SetupAssistant.managed</string>
  <key>PayloadOrganization</key>
  <string>Recovered from System Information</string>
  <key>PayloadScope</key>
  <string>System</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
```

### `_recovery_report.txt`

Because the types are guessed, the script also writes a report of the guesses. For each profile it lists the settings it wrote as something other than a string, grouped by type. Names that sit inside a dictionary or array setting are listed too, and each name appears once per type, sorted by character code (so capital letters come before lowercase ones). The values themselves are deliberately left out of this file.

```
com.apple.SetupAssistant.managed.mobileconfig  (scope: System)
  bool:    SkipAccessibility, SkipAppearance, SkipCloudSetup, SkipPrivacySetup, …

com.apple.Terminal.mobileconfig  (scope: System)
  bool:    FontAntialias, Linewrap
```

Use it to check the guesses against what you know about the settings. Type lines can be `bool`, `integer`, `real` and `date`.

## Example run

Lines are trimmed (`…`) to keep this short.

```
Managed Client Report Configuration Profile Extractor
--------------------------------------

Reading management settings...

  Created: com.apple.SetupAssistant.managed.mobileconfig (12 setting(s))
  Created: com.apple.Terminal.mobileconfig (3 setting(s))
  Created: com.apple.finder.mobileconfig (8 setting(s))
  …

--------------------------------------
Profiles created: 17
Location:         /tmp/spx_profiles_E4arh9
--------------------------------------

Warnings:
  com.apple.Terminal: Window Settings: binary data could not be rebuilt (Documentation > Font); it was omitted

These keys were not marked "always" in the report. They are written
as normal enforced settings:
  com.apple.finder: ShowHardDrivesOnDesktop (often)
  com.apple.finder: ShowStatusBar (often)
  …

Notes:
  - The report stores every value as text, so booleans, integers and
    strings were inferred. See _recovery_report.txt in the output
    directory for the settings of each type, and review before use.
  - The profiles are unsigned reconstructions and may contain secrets
    such as API keys and enrollment tokens. Handle them accordingly.

The configuration profiles are in this folder:
  /tmp/spx_profiles_E4arh9
```

## How it works

1. **Check the tools and read the command line**: The script stops with a message if a required tool is missing.
2. **Get the report**: From the file you gave it, or by running `system_profiler SPManagedClientDataType -json`.
3. **Validate it**: `jq` checks that the report is valid JSON whose top level has a `SPManagedClientDataType` list, and the script refuses anything else.
4. **Read the settings**: `jq` lists each preference domain and, within it, each setting's name, value text, scope and state.
5. **Restore the types**: Each value is converted to JSON with its type guessed, as described [below](#how-types-are-guessed). A plain value is read directly. A value that is a dictionary or array is first read by `plutil`, which turns that text into JSON in which every value is a string, and `jq` then restores the types. Binary data is dropped here, with a warning.
6. **Group the settings**: By scope and preference domain.
7. **Build each profile**: `jq` assembles the profile as JSON and `plutil` writes it as an XML property list. Dates, which JSON can't hold, are carried through as marked strings and turned into `<date>` elements at the end.
8. **Report on the guesses**: For each profile, `jq` lists the settings that were written as booleans, integers, decimals or dates, and the script adds them to `_recovery_report.txt`.
9. **Summarise**: What was created, skipped and worth a warning, and where the profiles are.

The script uses a second folder in `/tmp` (`spx_work_` plus six random characters) for intermediate files. It is created the same way, and it is always deleted when the script ends, including on Ctrl-C.

## How types are guessed

The Managed Client report stores every value as text. The script decides each value's type from the text and from the name of the setting.

| Text in the report | Setting name | Written as |
| --- | --- | --- |
| `1` or `0` | Doesn't suggest a number, for example `SkipScreenTime` or `ShowStatusBar` | boolean |
| `1` or `0` | Suggests a number, for example `Level`, `Count`, `Delay`, or anything containing `days` | integer |
| `10`, `-5` (up to 15 digits) | Any | integer |
| `2.5` | Suggests a number, for example `Interval` | real |
| `2.5` | Any other, for example `Name` | string |
| `007`, or a number of 16 or more digits | Any | string |
| `2018-01-01 00:00:00 +0000` (a plain value, in UTC) | Any | date |
| Anything else | Any | string |

More detail:

- Names beginning with `Skip` and names ending in `Enabled` or `Disabled` are always treated as flags, so a `0` or `1` in them is a boolean even if the name also suggests a number, such as `SkipTime` or `KeepDaysEnabled`. These three patterns are matched exactly as written, capitals included.
- The lists of words that suggest a number are the `NOT_BOOL` and `NUM_HINT` patterns inside the embedded `jq` program (the `write_retyper` function). Edit them if your settings need different guesses.
- Inside a dictionary, each member follows the same rules. Elements of an array are never booleans, so `( 0, 1 )` becomes the integers `0` and `1`.
- A date is only recognised as a plain value written in UTC (`+0000`), which is how dates appear in the reports tested. Any other form stays a string.

## Limitations

- **JSON reports only**: Reports exported as XML, saved from System Information as `.spx` files, or stored as binary property lists are not read. Export again with `system_profiler SPManagedClientDataType -json`.
- **Types are guesses**: Read `_recovery_report.txt` to see which settings were written as which type.
- **How quoted numbers inside a dictionary or array are handled**: `plutil` doesn't say whether a value was quoted, so a quoted `"123"` inside one is treated as the integer `123`.
- **How dates and raw data inside a dictionary or array are handled**: A bare date or bare hex data inside one makes `plutil` reject the text. That setting is then kept as plain text, with a warning.
- **Binary data isn't rebuilt**: The report shows it as `{length = N, bytes = ...}` and usually includes only the start of it. A setting that is entirely binary data is left out, and binary data nested inside a dictionary or array is left out of it. Either way a warning says what was omitted and where.
- **Only the settings available in the report are used to create the reconstructed profile files**: The script writes a reconstructed profile for every preference domain the report lists that has at least one setting the script can use, using the information provided for that preference domain. If the actual profile includes other information which is not listed in the report for that preference domain, the resulting reconstructed profile will not include that information.
- **Duplicate keys**: If a key appears more than once in a domain, the first value is kept, with a warning.
- **Reserved keys**: Keys beginning with `Payload` are ignored, because they are profile keys and not settings.
- **Unusual domain names**: Domain names containing characters other than letters, digits, `.`, `_` and `-` are skipped, and listed under "Skipped" in the summary.
- **Enforcement frequency**: The report marks each setting `always`, `often` or `once`. All of them are written as ordinary settings, and any that weren't `always` are listed in the summary.

## Exit status

| Status | Meaning |
| --- | --- |
| `0` | At least one profile was created (also used by `-h`). |
| `1` | An error: a missing tool, an unknown option, a file that isn't found or isn't a Managed Client report, or `system_profiler` failing. |
| `2` | The report was read, but no profile could be created. The script says why. |
| `130`, `143` | Interrupted with Ctrl-C, or terminated. |

## Security and privacy

- **The profiles can contain secrets**: Settings recovered from a managed Mac can include API keys and enrollment tokens. Treat the output folder accordingly, and don't commit it or share it.
- **Nothing is sent anywhere**: The script makes no network connections.
- **The output stays on disk until you delete it**: When you're done with the configuration files, I recommend removing the directory which contains them from your Mac.

## Troubleshooting

| Message | What it means |
| --- | --- |
| `Error: required tool(s) not found: jq` | `jq` is included with macOS 15 and later. On older releases, install it from <https://jqlang.org/>. |
| `Error: … was not formatted as expected.` | The file isn't a System Information Managed Client report in JSON format. The message says what was wrong, for example `It is not valid JSON (…)` for an XML or `.spx` report, or that it is a report of another type. Make a new one with `system_profiler SPManagedClientDataType -json > file.json`. |
| `The managed client report contains no items.` | The report is valid but lists no managed settings. |
| `The report contains N domain(s), but none produced a valid profile.` | Settings were found, but none could be turned into a profile. The skipped items are listed. |
| `Warning: … could not be written and was skipped (…)` | One profile couldn't be built. The reason from `jq` or `plutil` is in the parentheses, and the other profiles are unaffected. |
