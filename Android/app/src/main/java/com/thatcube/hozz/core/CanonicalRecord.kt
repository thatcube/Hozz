package com.thatcube.hozz.core

import com.thatcube.hozz.generated.GeneratedContract
import java.security.MessageDigest
import java.time.Instant
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

data class SourceLineage(
    val store: String,
    val packageName: String? = null,
    val recordId: String? = null,
)

data class CanonicalValue(
    val value: Double,
    val unit: String?,
    val description: String? = null,
)

data class CanonicalRecord(
    val canonicalId: String,
    val parentCanonicalId: String?,
    val recordVersion: Long,
    val kind: String,
    val canonicalType: String,
    val type: String,
    val startTime: Instant?,
    val endTime: Instant?,
    val canonicalValue: CanonicalValue?,
    val originalValue: CanonicalValue?,
    val categoryValue: Int?,
    val activityType: Int?,
    val quantityCount: Int?,
    val sourceRecordId: String,
    val sourceRecordVersion: Long?,
    val sourceStore: String,
    val sourceBundleIdentifier: String?,
    val sourceName: String?,
    val deviceJson: String?,
    val metadataJson: String?,
    val lineage: List<SourceLineage>,
    val tombstone: Boolean,
    val rawJson: String,
) {
    val displayType: String
        get() = type
            .removePrefix("HKQuantityTypeIdentifier")
            .removePrefix("HKCategoryTypeIdentifier")
            .removePrefix("HKDataTypeIdentifier")
            .removePrefix("HKWorkoutTypeIdentifier")
            .replace(Regex("([a-z0-9])([A-Z])"), "$1 $2")
            .ifBlank { kind.replaceFirstChar(Char::uppercase) }

    fun hasVisitedHealthConnectTarget(): Boolean =
        lineage.any {
            it.store == GeneratedContract.TARGET_STORE &&
                it.packageName == GeneratedContract.TARGET_PACKAGE
        }
}

object CanonicalRecordParser {
    private val runKinds = setOf(
        "manifest",
        "resume",
        "typeSummary",
        "typeError",
        "completion",
    )

    fun parse(line: String): CanonicalRecord? {
        val jsonObject = Json.parseToJsonElement(line).jsonObject
        val kind = jsonObject.string("kind")
            ?: throw ArchiveFormatException("A record has no kind.")
        val schemaVersion = jsonObject.int("schemaVersion")
            ?: throw ArchiveFormatException("A $kind record has no schemaVersion.")
        if (schemaVersion != GeneratedContract.SCHEMA_VERSION) {
            throw ArchiveFormatException(
                "Record schema $schemaVersion is not supported.",
            )
        }
        if (kind in runKinds) {
            return null
        }

        val sourceRecord = jsonObject.objectValue("sourceRecord")
        val topLevelId = jsonObject.string("id")
        val sourceStore = sourceRecord?.string("store")
            ?: GeneratedContract.SOURCE_STORE
        val type = sourceRecord?.string("type")
            ?: jsonObject.string("type")
            ?: "HozzRecordType:$kind"
        val sourceId = sourceRecord?.string("id")
            ?: when (kind) {
                "clinicalRecord" -> jsonObject.string("healthKitUUID")
                "electrocardiogramEnd",
                "electrocardiogramVoltages",
                "quantitySeriesEnd",
                "quantitySeriesReadings",
                "workoutRouteEnd",
                "workoutRouteLocations" -> jsonObject.string("sample")
                else -> null
            }
            ?: topLevelId
            ?: auxiliarySourceId(jsonObject, kind, line)
        val canonicalSourceId = when {
            kind == "sampleEncodingError" ->
                encodingFailureId(sourceId, type)
            else -> topLevelId ?: auxiliarySourceId(jsonObject, kind, line)
        }
        val canonicalId = jsonObject.string("canonicalId")
            ?: "$sourceStore:$canonicalSourceId"
        val encodedCanonicalType = jsonObject.string("canonicalType")
        val canonicalType = GeneratedContract.archiveOnlyCanonicalTypes[kind]
            ?: GeneratedContract.recordMappings[type]?.canonicalType
            ?: GeneratedContract.sourceCanonicalTypes[type]
            ?: GeneratedContract.sourceCanonicalTypePrefixes.entries
                .firstOrNull { type.startsWith(it.key) }
                ?.value
            ?: encodedCanonicalType
            ?: "archive.raw"
        val tombstone = kind == "deletion" ||
            jsonObject.boolean("deleted") == true
        val recordVersion = jsonObject.long("recordVersion")
            ?: when {
                tombstone -> 2L
                kind == "characteristics" ->
                    jsonObject.instant("readAt")?.toEpochMilli() ?: 1L
                else -> 1L
            }

        val quantity = jsonObject.objectValue("quantity")
        val canonicalQuantity = quantity?.objectValue("canonical")
        val originalQuantity = quantity?.objectValue("original")
        val canonicalValue = value(
            canonicalQuantity ?: quantity,
            fallbackDescription = quantity?.string("description"),
        ) ?: when (kind) {
            "workout" -> jsonObject.double("duration")?.let {
                CanonicalValue(it, "sec")
            }
            else -> jsonObject.double("value")?.let {
                CanonicalValue(it, jsonObject.string("unit"))
            }
        }
        val originalValue = originalQuantity?.let {
            value(
                it,
                fallbackDescription = quantity.string("description"),
            )
        }

        val source = jsonObject.objectValue("source")
        val lineage = jsonObject.array("lineage")
            ?.mapNotNull { item ->
                val entry = item as? JsonObject ?: return@mapNotNull null
                entry.string("store")?.let {
                    SourceLineage(
                        store = it,
                        packageName = entry.string("package"),
                        recordId = entry.string("recordId"),
                    )
                }
            }
            ?.ifEmpty { null }
            ?: listOf(SourceLineage(store = sourceStore, recordId = sourceId))

        return CanonicalRecord(
            canonicalId = canonicalId,
            parentCanonicalId = jsonObject.string("parentCanonicalId")
                ?: if (kind == "sampleEncodingError") {
                    "$sourceStore:$sourceId"
                } else {
                    null
                }
                ?: jsonObject.string("sample")?.let {
                    "${GeneratedContract.SOURCE_STORE}:$it"
                },
            recordVersion = recordVersion,
            kind = kind,
            canonicalType = canonicalType,
            type = type,
            startTime = jsonObject.instant("startDate"),
            endTime = jsonObject.instant("endDate") ?: jsonObject.instant("startDate"),
            canonicalValue = canonicalValue,
            originalValue = originalValue,
            categoryValue = if (kind == "category") jsonObject.int("value") else null,
            activityType = jsonObject.int("activityType"),
            quantityCount = quantity?.int("count"),
            sourceRecordId = sourceId,
            sourceRecordVersion = sourceRecord?.long("version"),
            sourceStore = sourceStore,
            sourceBundleIdentifier = source?.string("bundleIdentifier"),
            sourceName = source?.string("name"),
            deviceJson = jsonObject["device"]?.toString(),
            metadataJson = jsonObject["metadata"]?.toString(),
            lineage = lineage,
            tombstone = tombstone,
            rawJson = jsonObject.toString(),
        )
    }

    fun lineageJson(lineage: List<SourceLineage>): String = JsonArray(
        lineage.map { value ->
            buildJsonObject {
                put("store", value.store)
                value.packageName?.let { put("package", it) }
                value.recordId?.let { put("recordId", it) }
            }
        },
    ).toString()

    fun lineage(json: String): List<SourceLineage> =
        Json.parseToJsonElement(json).jsonArray.mapNotNull { item ->
            val jsonObject = item as? JsonObject ?: return@mapNotNull null
            jsonObject.string("store")?.let {
                SourceLineage(
                    store = it,
                    packageName = jsonObject.string("package"),
                    recordId = jsonObject.string("recordId"),
                )
            }
        }

    private fun value(
        jsonObject: JsonObject?,
        fallbackDescription: String?,
    ): CanonicalValue? {
        val number = jsonObject?.double("value") ?: return null
        return CanonicalValue(
            value = number,
            unit = jsonObject.string("unit"),
            description = jsonObject.string("description") ?: fallbackDescription,
        )
    }

    private fun auxiliarySourceId(
        jsonObject: JsonObject,
        kind: String,
        rawLine: String,
    ): String {
        jsonObject.string("sample")?.let { sample ->
            val sequence = jsonObject.int("sequence")
                ?: jsonObject.int("offset")
                ?: 0
            return "$sample:$kind:$sequence"
        }
        if (kind == "characteristics") {
            return "characteristics"
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(rawLine.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return "raw:$digest"
    }

    internal fun encodingFailureId(sourceId: String, type: String): String {
        val sourceUUID = try {
            UUID.fromString(sourceId)
        } catch (_: IllegalArgumentException) {
            return "encoding-error:${hash("$type\u0000$sourceId")}"
        }
        val sourceBytes = ByteBuffer.allocate(16)
            .putLong(sourceUUID.mostSignificantBits)
            .putLong(sourceUUID.leastSignificantBits)
            .array()
        val digest = MessageDigest.getInstance("SHA-256").apply {
            update("HozzEncodingFailure".toByteArray())
            update(0.toByte())
            update(type.toByteArray())
            update(sourceBytes)
        }.digest().copyOfRange(0, 16)
        digest[6] = ((digest[6].toInt() and 0x0F) or 0x50).toByte()
        digest[8] = ((digest[8].toInt() and 0x3F) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(digest)
        return UUID(buffer.long, buffer.long).toString().lowercase()
    }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }
}

class ArchiveFormatException(message: String) : Exception(message)

private fun JsonObject.string(name: String): String? =
    this[name]?.jsonPrimitive?.contentOrNull

private fun JsonObject.int(name: String): Int? =
    this[name]?.jsonPrimitive?.intOrNull

private fun JsonObject.long(name: String): Long? =
    this[name]?.jsonPrimitive?.longOrNull

private fun JsonObject.double(name: String): Double? =
    this[name]?.jsonPrimitive?.doubleOrNull

private fun JsonObject.boolean(name: String): Boolean? =
    this[name]?.jsonPrimitive?.booleanOrNull

private fun JsonObject.instant(name: String): Instant? =
    string(name)?.let {
        try {
            Instant.parse(it)
        } catch (_: Exception) {
            throw ArchiveFormatException("Record date $name is not ISO 8601.")
        }
    }

private fun JsonObject.objectValue(name: String): JsonObject? =
    this[name] as? JsonObject

private fun JsonObject.array(name: String): JsonArray? =
    this[name] as? JsonArray
