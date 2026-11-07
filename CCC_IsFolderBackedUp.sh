# CCC_IsFolderBackedUp — Version 3.5

#!/bin/bash

# ==============================================================================
# CARBON COPY CLONER — SEARCH FOR FOLDERS IN CCC BACKUPS
# Version 3.5
#
# Exact, case-insensitive folder-name matching.
# No partial-name matching.
#
# Final recaps of status':
#   'INCLUDED BY DEFAULT'
#   'EXPLICITLY INCLUDED'
#
# Folder input is collected by Bash directly from /dev/tty.
# ==============================================================================

set -u

VERSION="3.5"

clear

echo
echo "============================================================================="
echo "                 CARBON COPY CLONER — FOLDER SEARCH"
echo "                              Version $VERSION"
echo "============================================================================="
echo

# ------------------------------------------------------------------------------
# Select CCC export
# ------------------------------------------------------------------------------

EXPORT_PATH=$(
    osascript <<'APPLESCRIPT'
try
    set selectedFile to choose file with prompt "Select your Carbon Copy Cloner exported task file:" of type {"ccctask"}
    return POSIX path of selectedFile
on error
    return ""
end try
APPLESCRIPT
)

if [[ -z "$EXPORT_PATH" ]]; then
    echo "No CCC export file selected."
    exit 1
fi

if [[ ! -f "$EXPORT_PATH" ]]; then
    echo "ERROR: The selected CCC export file does not exist."
    exit 1
fi

echo "CCC EXPORT:"
echo "$EXPORT_PATH"
echo

# ------------------------------------------------------------------------------
# Collect folder name directly through Bash
# ------------------------------------------------------------------------------

echo "Enter the exact folder name to search for."
echo "Matching is case-insensitive; partial matches are NOT used."
echo

if ! IFS= read -r -p "Folder name: " FOLDER_NAME </dev/tty; then
    echo
    echo "ERROR: Unable to read folder name from Terminal."
    exit 1
fi

FOLDER_NAME="${FOLDER_NAME#"${FOLDER_NAME%%[![:space:]]*}"}"
FOLDER_NAME="${FOLDER_NAME%"${FOLDER_NAME##*[![:space:]]}"}"

if [[ -z "$FOLDER_NAME" ]]; then
    echo
    echo "ERROR: No folder name was entered."
    exit 1
fi

echo
echo "Searching for exact folder name: $FOLDER_NAME"
echo

# ------------------------------------------------------------------------------
# Analyze CCC export
# ------------------------------------------------------------------------------

python3 - "$EXPORT_PATH" "$FOLDER_NAME" <<'PYTHON'
import plistlib
import sys

EXPORT_PATH = sys.argv[1]
FOLDER_NAME = sys.argv[2]
SEARCH_NAME = FOLDER_NAME.casefold()


def value_string(value):
    if value is None:
        return "Not specified"
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def get_nested(dictionary, *keys):
    current = dictionary
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def disk_description(disk):
    if not isinstance(disk, dict):
        return "Not specified", "Not specified", "Not specified"

    volume = (
        disk.get("name")
        or disk.get("volumeName")
        or disk.get("volume")
        or disk.get("bsdName")
        or "Not specified"
    )

    mount = (
        disk.get("mnt")
        or get_nested(disk, "underlyingDevice", "mnt")
        or disk.get("mountPoint")
        or "Not specified"
    )

    path = (
        disk.get("path")
        or disk.get("relativePath")
        or disk.get("folderPath")
        or ""
    )

    path = value_string(path)

    if path in ("", "None"):
        path = "Not specified"

    return value_string(volume), value_string(mount), path


def get_task_source(task):
    return disk_description(task.get("sourceDisk", {}))


def get_task_destination(task):
    return disk_description(task.get("targetDisk", {}))


def get_task_name(task):
    return value_string(
        task.get("cccTaskName")
        or task.get("name")
        or "Unnamed task"
    )


def get_group_name(group):
    return value_string(group.get("name") or "(unnamed)")


def flatten_rules(rules, depth=0, results=None):
    if results is None:
        results = []

    if not isinstance(rules, list):
        return results

    for rule in rules:
        if not isinstance(rule, dict):
            continue

        name = (
            rule.get("name")
            or rule.get("path")
            or rule.get("filter")
            or ""
        )

        flags = rule.get("ruleFlags")

        if name:
            results.append({
                "name": value_string(name),
                "flags": flags,
                "depth": depth
            })

        children = rule.get("children", [])

        if isinstance(children, list) and children:
            flatten_rules(children, depth + 1, results)

    return results


def rule_type(flags):
    try:
        value = int(flags) & 0x0F
    except Exception:
        return "UNKNOWN"

    if value == 3:
        return "EXCLUDE"

    if value == 12:
        return "INCLUDE"

    if value == 0:
        return "STRUCTURAL"

    return "UNKNOWN"


def determine_filter_mode(filter_data):
    try:
        flags = int(filter_data.get("filterFlags"))
    except Exception:
        flags = None

    if flags == 1056 and filter_data.get("hasExclusions") is True:
        return "EXCLUSION"

    return "UNKNOWN"


def exact_name_matches(rules):
    matches = []

    for rule in rules:
        rule_name = rule["name"].strip().rstrip("/")
        basename = rule_name.split("/")[-1]

        if basename.casefold() == SEARCH_NAME:
            matches.append(rule)

    return matches


def print_task_details(group_name, task, status, explanation):
    source_volume, source_mount, source_path = get_task_source(task)
    dest_volume, dest_mount, dest_path = get_task_destination(task)

    print()
    print("-------------------------------------------------------------------------------")
    print("TASK:", get_task_name(task))
    print("GROUP:", group_name)
    print("SOURCE VOLUME:      ", source_volume)
    print("SOURCE MOUNT:       ", source_mount)
    print("SOURCE PATH:        ", source_path)
    print("DESTINATION VOLUME: ", dest_volume)
    print("DESTINATION MOUNT:  ", dest_mount)
    print("DESTINATION PATH:   ", dest_path)
    print("RESULT:", status)
    print("DETAIL:", explanation)


# ------------------------------------------------------------------------------
# Load CCC export
# ------------------------------------------------------------------------------

try:
    with open(EXPORT_PATH, "rb") as file:
        export_data = plistlib.load(file)
except Exception as error:
    print("ERROR: Unable to read the CCC export.")
    print(str(error))
    sys.exit(1)

if not isinstance(export_data, dict):
    print("ERROR: Unexpected CCC export format.")
    sys.exit(1)

groups = export_data.get("infos", [])

if not isinstance(groups, list):
    print("ERROR: The CCC export does not contain a valid task list.")
    sys.exit(1)


# ------------------------------------------------------------------------------
# Initialize counters and recap lists
# ------------------------------------------------------------------------------

counts = {
    "EXPLICITLY INCLUDED": 0,
    "EXPLICITLY EXCLUDED": 0,
    "INCLUDED BY DEFAULT": 0,
    "REVIEW REQUIRED": 0,
    "NO MATCHING RULE": 0
}

included_by_default = []
explicitly_included = []

total_tasks = 0

print()
print("===============================================================================")
print("SEARCHING CCC TASKS")
print("===============================================================================")
print("EXACT FOLDER NAME:", FOLDER_NAME)
print()


# ------------------------------------------------------------------------------
# Process every CCC task
# ------------------------------------------------------------------------------

for group in groups:

    if not isinstance(group, dict):
        continue

    group_name = get_group_name(group)
    tasks = group.get("tasks", [])

    if not isinstance(tasks, list):
        continue

    for task in tasks:

        if not isinstance(task, dict):
            continue

        total_tasks += 1

        filter_data = task.get("rsync_filter", {})

        if not isinstance(filter_data, dict):
            filter_data = {}

        conventional_rules = filter_data.get("conventionalRules", [])
        custom_rules = filter_data.get("customFilterRules", [])

        if not isinstance(conventional_rules, list):
            conventional_rules = []

        if not isinstance(custom_rules, list):
            custom_rules = []

        flattened = flatten_rules(conventional_rules)
        matches = exact_name_matches(flattened)

        filter_mode = determine_filter_mode(filter_data)

        status = "REVIEW REQUIRED"
        explanation = "The filter configuration could not be classified confidently."

        if custom_rules:
            status = "REVIEW REQUIRED"
            explanation = (
                f"This task contains {len(custom_rules)} custom filter rule(s). "
                "Custom rules require manual review."
            )

        elif matches:

            if any(match["depth"] > 0 for match in matches):
                status = "REVIEW REQUIRED"
                explanation = (
                    "An exact name match exists inside a nested rule. "
                    "The parent-folder context must be checked."
                )

            elif len(matches) > 1:
                status = "REVIEW REQUIRED"
                explanation = (
                    "Multiple exact-name rules were found. "
                    "Their combined effect requires manual review."
                )

            else:
                matched_type = rule_type(matches[0]["flags"])

                if matched_type == "INCLUDE":
                    status = "EXPLICITLY INCLUDED"
                    explanation = (
                        "A direct conventional inclusion rule matches "
                        "the requested folder name."
                    )

                elif matched_type == "EXCLUDE":
                    status = "EXPLICITLY EXCLUDED"
                    explanation = (
                        "A direct conventional exclusion rule matches "
                        "the requested folder name."
                    )

                else:
                    status = "REVIEW REQUIRED"
                    explanation = (
                        "A matching rule exists, but its rule type is "
                        "not recognized."
                    )

        else:
            if filter_mode == "EXCLUSION":
                status = "INCLUDED BY DEFAULT"
                explanation = (
                    "The task uses the recognized exclusion-based filter "
                    "configuration and no exact matching exclusion was found."
                )
            else:
                status = "NO MATCHING RULE"
                explanation = (
                    "No exact matching conventional rule was found, and "
                    "the filter mode is not recognized confidently."
                )

        counts[status] += 1

        print_task_details(
            group_name,
            task,
            status,
            explanation
        )

        if status in ("INCLUDED BY DEFAULT", "EXPLICITLY INCLUDED"):

            source_volume, source_mount, source_path = get_task_source(task)
            dest_volume, dest_mount, dest_path = get_task_destination(task)

            recap_item = {
                "group": group_name,
                "task": get_task_name(task),
                "source_volume": source_volume,
                "source_mount": source_mount,
                "source_path": source_path,
                "destination_volume": dest_volume,
                "destination_mount": dest_mount,
                "destination_path": dest_path
            }

            if status == "INCLUDED BY DEFAULT":
                included_by_default.append(recap_item)
            else:
                explicitly_included.append(recap_item)


# ------------------------------------------------------------------------------
# Audit summary
# ------------------------------------------------------------------------------

configured_include_total = (
    counts["INCLUDED BY DEFAULT"]
    + counts["EXPLICITLY INCLUDED"]
)

print()
print()
print("===============================================================================")
print("                            AUDIT SUMMARY")
print("===============================================================================")

print("Folder searched:                 ", FOLDER_NAME)
print("CCC groups examined:             ", len(groups))
print("CCC tasks examined:              ", total_tasks)
print()
print("EXPLICITLY INCLUDED:             ", counts["EXPLICITLY INCLUDED"])
print("EXPLICITLY EXCLUDED:             ", counts["EXPLICITLY EXCLUDED"])
print("INCLUDED BY DEFAULT:             ", counts["INCLUDED BY DEFAULT"])
print("REVIEW REQUIRED:                 ", counts["REVIEW REQUIRED"])
print("NO MATCHING RULE:                ", counts["NO MATCHING RULE"])
print()
print("TOTAL CLASSIFIED AS INCLUDED:    ", configured_include_total)


# ------------------------------------------------------------------------------
# Print recap sections
# ------------------------------------------------------------------------------

def print_recap_section(title, items):

    print()
    print()
    print("===============================================================================")
    print(title)
    print("===============================================================================")

    if not items:
        print()
        print("NO TASKS FOUND")
        print("TOTAL: 0")
        return

    for index, item in enumerate(items, start=1):

        print()
        print(f"{index}. GROUP: {item['group']}")
        print(f"   TASK: {item['task']}")
        print(f"   SOURCE VOLUME:      {item['source_volume']}")
        print(f"   SOURCE MOUNT:       {item['source_mount']}")
        print(f"   SOURCE PATH:        {item['source_path']}")
        print(f"   DESTINATION VOLUME: {item['destination_volume']}")
        print(f"   DESTINATION MOUNT:  {item['destination_mount']}")
        print(f"   DESTINATION PATH:   {item['destination_path']}")

    print()
    print("TOTAL:", len(items))


print_recap_section(
    "INCLUDED BY DEFAULT - FINAL RECAP",
    included_by_default
)

print_recap_section(
    "EXPLICITLY INCLUDED - FINAL RECAP",
    explicitly_included
)


# ------------------------------------------------------------------------------
# Combined total
# ------------------------------------------------------------------------------

print()
print()
print("===============================================================================")
print("                   COMBINED INCLUDED TASKS - FINAL RECAP")
print("===============================================================================")

print("Folder searched:       ", FOLDER_NAME)
print()
print("INCLUDED BY DEFAULT:   ", len(included_by_default))
print("EXPLICITLY INCLUDED:  ", len(explicitly_included))
print("COMBINED TOTAL:        ", configured_include_total)


# ------------------------------------------------------------------------------
# Important notes
# ------------------------------------------------------------------------------

print()
print()
print("===============================================================================")
print("                              IMPORTANT NOTES")
print("===============================================================================")
print()
print("1. Folder matching is exact and case-insensitive.")
print("   Partial folder-name matches are not used.")
print()
print("2. INCLUDED BY DEFAULT is based on the recognized exclusion-based")
print("   filter configuration observed in this CCC export.")
print()
print("3. EXPLICITLY INCLUDED means a direct conventional inclusion rule")
print("   matched the requested folder name.")
print()
print("4. Nested rules and custom filter rules may require manual review.")
print()
print("5. This report analyzes CCC task configuration. It does not verify")
print("   that the task's source scope contains the requested folder,")
print("   that the task is enabled, or that a backup completed successfully.")
print()
print("6. Verify each task's source scope before treating it as actual")
print("   backup coverage for the requested folder.")
print()
print("===============================================================================")
print("                              SEARCH COMPLETE")
print("===============================================================================")
print()

PYTHON

echo
echo "Press Return to close this window."
IFS= read -r </dev/tty