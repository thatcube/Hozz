#!/usr/bin/env python3

import argparse
import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schema/hozz/v1"
MAPPINGS_PATH = SCHEMA_ROOT / "health-connect-mappings.json"
PALETTE_PATH = ROOT / "Sources/HozzUI/HozzPalette.swift"
TOKENS_PATH = ROOT / "schema/design/hozz-colors.json"
KOTLIN_CONTRACT_PATH = (
    ROOT
    / "Android/app/src/main/java/com/thatcube/hozz/generated/GeneratedContract.kt"
)
KOTLIN_COLORS_PATH = (
    ROOT
    / "Android/app/src/main/java/com/thatcube/hozz/generated/GeneratedHozzColors.kt"
)
SWIFT_PATH = ROOT / "Sources/HozzCore/GeneratedArchiveContract.swift"
SWIFT_HEALTH_PATH = ROOT / "Sources/HozzHealth/GeneratedArchiveContract.swift"


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def kotlin_enum(value: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", value).upper()


def parse_palette() -> list[dict[str, str]]:
    text = PALETTE_PATH.read_text()
    pattern = re.compile(
        r"public static let ([A-Za-z0-9_]+) = "
        r"Color\(light: 0x([0-9A-F]{6}), dark: 0x([0-9A-F]{6})\)"
    )
    tokens = [
        {"name": name, "light": f"#{light}", "dark": f"#{dark}"}
        for name, light, dark in pattern.findall(text)
    ]
    if not tokens:
        raise ValueError(f"No flat colour tokens found in {PALETTE_PATH}")
    return tokens


def render_tokens(tokens: list[dict[str, str]]) -> str:
    return (
        json.dumps(
            {
                "schemaVersion": 1,
                "source": "Sources/HozzUI/HozzPalette.swift",
                "colors": tokens,
            },
            indent=2,
            ensure_ascii=True,
        )
        + "\n"
    )


def render_kotlin_contract(mapping: dict) -> str:
    records = []
    for entry in mapping["recordMappings"]:
        records.append(
            "        "
            + quoted(entry["sourceIdentifier"])
            + " to RecordMapping("
            + ", ".join(
                [
                    f"sourceIdentifier = {quoted(entry['sourceIdentifier'])}",
                    f"canonicalType = {quoted(entry['canonicalType'])}",
                    f"sourceKind = {quoted(entry['sourceKind'])}",
                    f"targetRecord = {quoted(entry['targetRecord'])}",
                    "canonicalUnit = "
                    + (
                        quoted(entry["canonicalUnit"])
                        if entry.get("canonicalUnit")
                        else "null"
                    ),
                    f"quality = MappingQuality.{kotlin_enum(entry['quality'])}",
                    "warningCode = "
                    + (
                        quoted(entry["warningCode"])
                        if entry.get("warningCode")
                        else "null"
                    ),
                ]
            )
            + "),"
        )

    sleep = []
    for entry in mapping["sleepStages"]:
        sleep.append(
            f"        {entry['sourceValue']} to SleepStageMapping("
            + ", ".join(
                [
                    f"sourceValue = {entry['sourceValue']}",
                    f"sourceName = {quoted(entry['sourceName'])}",
                    "targetStage = "
                    + (
                        quoted(entry["targetStage"])
                        if entry.get("targetStage")
                        else "null"
                    ),
                    f"disposition = MappingDisposition.{kotlin_enum(entry['disposition'])}",
                    "warningCode = "
                    + (
                        quoted(entry["warningCode"])
                        if entry.get("warningCode")
                        else "null"
                    ),
                ]
            )
            + "),"
        )

    workouts = []
    for entry in mapping["workoutActivities"]:
        workouts.append(
            f"        {entry['sourceValue']} to WorkoutMapping("
            + ", ".join(
                [
                    f"sourceValue = {entry['sourceValue']}",
                    f"sourceName = {quoted(entry['sourceName'])}",
                    f"targetExercise = {quoted(entry['targetExercise'])}",
                    f"disposition = MappingDisposition.{kotlin_enum(entry['disposition'])}",
                ]
            )
            + "),"
        )

    archive_only = ",\n".join(
        f"        {quoted(value)}" for value in mapping["archiveOnlyKinds"]
    )
    archive_only_types = ",\n".join(
        f"        {quoted(key)} to {quoted(value)}"
        for key, value in sorted(mapping["archiveOnlyCanonicalTypes"].items())
    )
    source_types = ",\n".join(
        f"        {quoted(key)} to {quoted(value)}"
        for key, value in sorted(mapping["sourceCanonicalTypes"].items())
    )
    source_prefixes = ",\n".join(
        f"        {quoted(key)} to {quoted(value)}"
        for key, value in sorted(mapping["sourceCanonicalTypePrefixes"].items())
    )
    warnings = ",\n".join(
        f"        {quoted(key)} to {quoted(value)}"
        for key, value in sorted(mapping["warningMessages"].items())
    )

    return f"""// Generated by tools/generate-shared-contracts.py. Do not edit.
package com.thatcube.hozz.generated

enum class MappingQuality {{ EXACT, CONDITIONAL, ARCHIVE_ONLY }}
enum class MappingDisposition {{ EXACT, LOSSY, ARCHIVE_ONLY }}

data class RecordMapping(
    val sourceIdentifier: String,
    val canonicalType: String,
    val sourceKind: String,
    val targetRecord: String,
    val canonicalUnit: String?,
    val quality: MappingQuality,
    val warningCode: String?,
)

data class SleepStageMapping(
    val sourceValue: Int,
    val sourceName: String,
    val targetStage: String?,
    val disposition: MappingDisposition,
    val warningCode: String?,
)

data class WorkoutMapping(
    val sourceValue: Int,
    val sourceName: String,
    val targetExercise: String,
    val disposition: MappingDisposition,
)

object GeneratedContract {{
    const val SCHEMA_VERSION = {mapping['schemaVersion']}
    const val SOURCE_STORE = {quoted(mapping['sourceStore'])}
    const val TARGET_STORE = {quoted(mapping['targetStore'])}
    const val TARGET_PACKAGE = {quoted(mapping['targetPackage'])}

    val recordMappings: Map<String, RecordMapping> = mapOf(
{chr(10).join(records)}
    )

    val sleepStages: Map<Int, SleepStageMapping> = mapOf(
{chr(10).join(sleep)}
    )

    val workoutActivities: Map<Int, WorkoutMapping> = mapOf(
{chr(10).join(workouts)}
    )

    val archiveOnlyKinds: Set<String> = setOf(
{archive_only}
    )

    val archiveOnlyCanonicalTypes: Map<String, String> = mapOf(
{archive_only_types}
    )

    val sourceCanonicalTypes: Map<String, String> = mapOf(
{source_types}
    )

    val sourceCanonicalTypePrefixes: Map<String, String> = mapOf(
{source_prefixes}
    )

    val warningMessages: Map<String, String> = mapOf(
{warnings}
    )
}}
"""


def render_kotlin_colors(tokens: list[dict[str, str]]) -> str:
    lines = [
        "// Generated by tools/generate-shared-contracts.py. Do not edit.",
        "package com.thatcube.hozz.generated",
        "",
        "import androidx.compose.ui.graphics.Color",
        "",
        "data class HozzColorToken(val light: Color, val dark: Color)",
        "",
        "object GeneratedHozzColors {",
    ]
    for token in tokens:
        light = token["light"].removeprefix("#")
        dark = token["dark"].removeprefix("#")
        lines.append(
            f"    val {token['name']} = HozzColorToken("
            f"light = Color(0xFF{light}), dark = Color(0xFF{dark}))"
        )
    lines.extend(["}", ""])
    return "\n".join(lines)


def swift_identifier(name: str) -> str:
    if name[0].isdigit():
        return f"_{name}"
    return name


def render_swift(mapping: dict) -> str:
    identifiers = "\n".join(
        f'        "{entry["sourceIdentifier"]}",'
        for entry in mapping["recordMappings"]
    )
    archive_only = "\n".join(
        f'        "{value}",' for value in mapping["archiveOnlyKinds"]
    )
    archive_only_types = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["archiveOnlyCanonicalTypes"].items())
    )
    source_types = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["sourceCanonicalTypes"].items())
    )
    source_prefixes = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["sourceCanonicalTypePrefixes"].items())
    )
    canonical_types = "\n".join(
        f'        "{entry["sourceIdentifier"]}": "{entry["canonicalType"]}",'
        for entry in mapping["recordMappings"]
    )
    return f"""// Generated by tools/generate-shared-contracts.py. Do not edit.

import Foundation

public enum HozzArchiveContract {{
    public static let schemaVersion = {mapping['schemaVersion']}
    public static let manifestEntry = "hozz-manifest.json"
    public static let format = "hozz-ndjson"
    public static let recordSchema = "hozz/v1/canonical-record"
    public static let healthConnectPackage = {quoted(mapping['targetPackage'])}

    public static let healthConnectMappedTypes: Set<String> = [
{identifiers}
    ]

    public static let canonicalTypesBySourceIdentifier: [String: String] = [
{canonical_types}
    ]

    public static let archiveOnlyKinds: Set<String> = [
{archive_only}
    ]

    public static let archiveOnlyCanonicalTypes: [String: String] = [
{archive_only_types}
    ]
    public static let sourceCanonicalTypes: [String: String] = [
{source_types}
    ]
    public static let sourceCanonicalTypePrefixes: [String: String] = [
{source_prefixes}
    ]
}}
"""


def render_swift_health(mapping: dict) -> str:
    canonical_types = "\n".join(
        f'        "{entry["sourceIdentifier"]}": "{entry["canonicalType"]}",'
        for entry in mapping["recordMappings"]
    )
    archive_only_types = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["archiveOnlyCanonicalTypes"].items())
    )
    source_types = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["sourceCanonicalTypes"].items())
    )
    source_prefixes = "\n".join(
        f'        "{key}": "{value}",'
        for key, value in sorted(mapping["sourceCanonicalTypePrefixes"].items())
    )
    return f"""// Generated by tools/generate-shared-contracts.py. Do not edit.

enum HozzHealthArchiveContract {{
    static let schemaVersion = {mapping['schemaVersion']}
    static let manifestEntry = "hozz-manifest.json"
    static let format = "hozz-ndjson"
    static let recordSchema = "hozz/v1/canonical-record"
    static let sourceStore = {quoted(mapping['sourceStore'])}
    static let canonicalTypesBySourceIdentifier: [String: String] = [
{canonical_types}
    ]
    static let archiveOnlyCanonicalTypes: [String: String] = [
{archive_only_types}
    ]
    static let sourceCanonicalTypes: [String: String] = [
{source_types}
    ]
    static let sourceCanonicalTypePrefixes: [String: String] = [
{source_prefixes}
    ]

    static func canonicalType(
        for sourceIdentifier: String,
        kind: String? = nil
    ) -> String {{
        kind.flatMap {{ archiveOnlyCanonicalTypes[$0] }}
            ?? canonicalTypesBySourceIdentifier[sourceIdentifier]
            ?? sourceCanonicalTypes[sourceIdentifier]
            ?? sourceCanonicalTypePrefixes.first(where: {{
                sourceIdentifier.hasPrefix($0.key)
            }})?.value
            ?? "archive.raw"
    }}

    static func canonicalID(for sourceID: String) -> String {{
        "\\(sourceStore):\\(sourceID)"
    }}
}}
"""


def write_or_check(path: pathlib.Path, content: str, check: bool) -> bool:
    if check:
        if not path.exists() or path.read_text() != content:
            print(f"Out of date: {path.relative_to(ROOT)}", file=sys.stderr)
            return False
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print(f"Generated {path.relative_to(ROOT)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    mapping = json.loads(MAPPINGS_PATH.read_text())
    tokens = parse_palette()
    outputs = [
        (TOKENS_PATH, render_tokens(tokens)),
        (KOTLIN_CONTRACT_PATH, render_kotlin_contract(mapping)),
        (KOTLIN_COLORS_PATH, render_kotlin_colors(tokens)),
        (SWIFT_PATH, render_swift(mapping)),
        (SWIFT_HEALTH_PATH, render_swift_health(mapping)),
    ]
    return 0 if all(
        write_or_check(path, content, arguments.check) for path, content in outputs
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
