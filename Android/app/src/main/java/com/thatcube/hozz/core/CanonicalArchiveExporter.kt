package com.thatcube.hozz.core

import com.thatcube.hozz.generated.GeneratedContract
import java.io.OutputStream
import java.io.FilterOutputStream
import java.security.MessageDigest
import java.time.Instant
import java.util.ArrayDeque
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.contentOrNull

data class ArchiveExportResult(
    val archiveId: String,
    val recordCount: Int,
)

class CanonicalArchiveExporter(
    private val store: CanonicalRecordStore,
) {
    suspend fun export(output: OutputStream): ArchiveExportResult =
        store.withExportSnapshot { snapshot ->
            val digest = MessageDigest.getInstance("SHA-256")
            var recordCount = 0
            var createdAt = Instant.EPOCH
            forEachRunRecord(snapshot) { record ->
                digest.update(runJson(record).toByteArray())
                digest.update('\n'.code.toByte())
            }
            forEachRecord(snapshot) { record ->
                val line = canonicalJson(record)
                digest.update(line.toByteArray())
                digest.update('\n'.code.toByte())
                recordCount += 1
                val recordTime = record.endTime ?: record.startTime
                if (recordTime != null && recordTime > createdAt) {
                    createdAt = recordTime
                }
            }
            val archiveId = digest.digest().joinToString("") { "%02x".format(it) }
            val recordsEntry = "hozz-archive-$archiveId.ndjson"
            val manifest = buildJsonObject {
                put("schemaVersion", GeneratedContract.SCHEMA_VERSION)
                put("archiveId", archiveId)
                put("format", ArchiveManifest.FORMAT)
                put("recordSchema", ArchiveManifest.RECORD_SCHEMA)
                put("recordsEntry", recordsEntry)
                put("createdAt", createdAt.toString())
                put("recordCount", recordCount)
                put("sourcePlatform", "Android")
            }.toString()

            ZipOutputStream(
                CloseShieldOutputStream(output).buffered(),
            ).use { archive ->
                archive.putNextEntry(entry(ArchiveManifest.ENTRY_NAME))
                archive.write(manifest.toByteArray())
                archive.closeEntry()

                archive.putNextEntry(entry(recordsEntry))
                forEachRunRecord(snapshot) { record ->
                    archive.write(runJson(record).toByteArray())
                    archive.write('\n'.code)
                }
                forEachRecord(snapshot) { record ->
                    archive.write(canonicalJson(record).toByteArray())
                    archive.write('\n'.code)
                }
                archive.closeEntry()
            }
            ArchiveExportResult(archiveId, recordCount)
        }

    private fun runJson(record: ArchiveRunRecord): String {
        val raw = Json.parseToJsonElement(record.rawJson).jsonObject
        val kind = raw.stringValue("kind")
            ?: throw ArchiveFormatException("A run record has no kind.")
        val allowed = GeneratedContract.runPropertyNamesByKind[kind]
            ?: throw ArchiveFormatException("Run record kind $kind is not supported.")
        val hasOnlyKindFields = raw.keys
            .filter { it in GeneratedContract.recordPropertyNames }
            .all { it in allowed }
        val line = if (raw.containsKey("schemaVersion") && hasOnlyKindFields) {
            CanonicalRecordParser.validateStrict(record.rawJson)
            record.rawJson
        } else {
            val normalized = buildJsonObject {
                raw.forEach { (key, value) ->
                    if (key !in GeneratedContract.recordPropertyNames) put(key, value)
                }
                put("kind", kind)
                put("schemaVersion", GeneratedContract.SCHEMA_VERSION)
                allowed.forEach { key ->
                    if (key != "kind" && key != "schemaVersion") {
                        raw[key]?.let { put(key, it) }
                    }
                }
            }
            sorted(normalized).toString()
        }
        if (line.toByteArray().size > MAX_CANONICAL_RECORD_BYTES) {
            throw ArchiveFormatException(
                "A normalized run record exceeds the 512 KiB limit.",
            )
        }
        CanonicalRecordParser.validateStrict(line)
        return line
    }

    internal fun canonicalJson(record: CanonicalRecord): String {
        val raw = Json.parseToJsonElement(record.rawJson).jsonObject
        val allowedFields =
            GeneratedContract.canonicalPropertyNamesByKind[record.kind]
        val preserveUnknownKindFields = allowedFields == null
        fun allows(field: String): Boolean =
            allowedFields == null || field in allowedFields
        val normalized = buildJsonObject {
            raw.forEach { (key, value) ->
                if (
                    preserveUnknownKindFields ||
                    key !in GeneratedContract.recordPropertyNames
                ) {
                    put(key, value)
                }
            }
            put("schemaVersion", GeneratedContract.SCHEMA_VERSION)
            put("canonicalId", record.canonicalId)
            put("canonicalType", record.canonicalType)
            put("recordVersion", record.recordVersion)
            put("kind", record.kind)
            val prefix = "${record.sourceStore}:"
            check(record.canonicalId.startsWith(prefix)) {
                "Canonical ID is outside its source namespace."
            }
            put("id", record.canonicalId.removePrefix(prefix))
            put("type", record.type)
            record.parentCanonicalId?.takeIf { allows("parentCanonicalId") }?.let {
                put("parentCanonicalId", it)
            }
            record.resolutionCanonicalId?.takeIf {
                allows("resolutionCanonicalId")
            }?.let {
                put("resolutionCanonicalId", it)
            }
            record.startTime?.takeIf { allows("startDate") }?.let {
                put("startDate", it.toString())
            }
            record.endTime?.takeIf { allows("endDate") }?.let {
                put("endDate", it.toString())
            }
            if (record.tombstone) {
                put("deleted", true)
            }
            put(
                "sourceRecord",
                buildJsonObject {
                    (raw["sourceRecord"] as? JsonObject)?.forEach { (key, value) ->
                        if (key !in GeneratedContract.sourceRecordPropertyNames) {
                            put(key, value)
                        }
                    }
                    put("store", record.sourceStore)
                    put("id", record.sourceRecordId)
                    put("type", record.type)
                    record.sourceRecordVersion?.let { put("version", it) }
                },
            )
            put(
                "lineage",
                buildJsonArray {
                    val existing = (raw["lineage"] as? JsonArray)
                        ?.mapNotNull { it as? JsonObject }
                        .orEmpty()
                    val remaining = existing
                        .groupBy {
                            Triple(
                                it.legacyStringValue("store"),
                                it.legacyStringValue("package"),
                                it.legacyStringValue("recordId"),
                            )
                        }
                                .mapValuesTo(mutableMapOf()) { (_, values) ->
                                    ArrayDeque(values)
                                }
                            var hasOrigin = false
                            record.lineage.forEach { original ->
                                val prior = remaining[
                                    Triple(
                                        original.store,
                                        original.packageName,
                                        original.recordId,
                                    )
                                ]
                                    ?.takeIf { it.isNotEmpty() }
                                    ?.removeFirst()
                                if (!original.store.matches(sourceNamespacePattern)) {
                                    return@forEach
                                }
                                val lineage = original.copy(
                                    packageName =
                                        original.packageName?.takeIf(String::isNotBlank),
                                    recordId =
                                        original.recordId?.takeIf(String::isNotBlank),
                                )
                                hasOrigin = hasOrigin || (
                                    lineage.store == record.sourceStore &&
                                        lineage.recordId == record.sourceRecordId
                                    )
                                add(
                            buildJsonObject {
                                prior?.forEach { (key, value) ->
                                    if (key !in GeneratedContract.lineagePropertyNames) {
                                        put(key, value)
                                    }
                                }
                                put("store", lineage.store)
                                lineage.packageName?.let { put("package", it) }
                                lineage.recordId?.let { put("recordId", it) }
                            },
                        )
                    }
                    if (!hasOrigin) {
                        add(
                            buildJsonObject {
                                put("store", record.sourceStore)
                                put("recordId", record.sourceRecordId)
                            },
                        )
                    }
                },
            )
            put(
                "source",
                buildJsonObject {
                    (raw["source"] as? JsonObject)?.forEach { (key, value) ->
                        if (key !in GeneratedContract.sourcePropertyNames) {
                            put(key, value)
                        }
                    }
                    record.sourceBundleIdentifier?.let {
                        put("bundleIdentifier", it)
                    }
                    record.sourceName?.let { put("name", it) }
                },
            )
            objectValue(record.deviceJson)?.let { put("device", it) }
            objectValue(record.metadataJson)?.let { put("metadata", it) }
            record.canonicalValue?.takeIf { allows("quantity") }?.let { canonical ->
                val existing = raw["quantity"] as? JsonObject
                put(
                    "quantity",
                    buildJsonObject {
                        existing?.forEach { (key, value) ->
                            if (key !in GeneratedContract.quantityPropertyNames) {
                                put(key, value)
                            }
                        }
                        put("unit", canonical.unit ?: "")
                        put("value", canonical.value)
                        put(
                            "canonical",
                            valueJson(
                                canonical,
                                existing?.get("canonical") as? JsonObject,
                            ),
                        )
                        val original = record.originalValue
                        val existingOriginal =
                            existing?.get("original") as? JsonObject
                        originalJson(original, existingOriginal)?.let {
                            put("original", it)
                        }
                    },
                )
            }
            record.categoryValue?.takeIf { allows("value") }?.let {
                put("value", it)
            }
            record.activityType?.takeIf { allows("activityType") }?.let {
                put("activityType", it)
            }
            if (record.kind == "characteristics") {
                record.startTime?.let { put("readAt", it.toString()) }
                put(
                    "characteristics",
                    raw["characteristics"] as? JsonObject ?: JsonObject(emptyMap()),
                )
            }
            if (record.kind == "sampleEncodingError") {
                put(
                    "message",
                    raw.stringValue("message")
                        ?.takeIf(String::isNotBlank)
                        ?: "The source record could not be encoded.",
                )
            }
            (raw["sequence"] as? kotlinx.serialization.json.JsonPrimitive)
                ?.longOrNull
                ?.takeIf { allows("sequence") }
                ?.let { put("sequence", it) }
        }
        val line = sorted(normalized).toString()
        if (line.toByteArray().size > MAX_CANONICAL_RECORD_BYTES) {
            throw ArchiveFormatException(
                "A normalized canonical record exceeds the 512 KiB limit.",
            )
        }
        CanonicalRecordParser.validateStrict(line)
        return line
    }

    private fun valueJson(
        value: CanonicalValue,
        existing: JsonObject?,
    ): JsonElement =
        buildJsonObject {
            existing?.forEach { (key, nestedValue) ->
                if (key !in GeneratedContract.valuePropertyNames) {
                    put(key, nestedValue)
                }
            }
            put("value", value.value)
            put("unit", value.unit ?: "")
            value.description?.let { put("description", it) }
        }

    private fun originalJson(
        value: CanonicalValue?,
        existing: JsonObject?,
    ): JsonObject? {
        val normalized = buildJsonObject {
            existing?.forEach { (key, nestedValue) ->
                if (key !in GeneratedContract.valuePropertyNames) {
                    put(key, nestedValue)
                }
            }
            if (value != null) {
                put("value", value.value)
                value.unit?.let { put("unit", it) }
                value.description?.let { put("description", it) }
            } else {
                existing?.stringValue("unit")
                    ?.let { put("unit", it) }
                existing?.stringValue("description")
                    ?.let { put("description", it) }
            }
        }
        return normalized.takeIf { it.isNotEmpty() }
    }

    private fun sorted(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(
            element.entries
                .sortedBy(Map.Entry<String, JsonElement>::key)
                .associateTo(linkedMapOf()) { (key, value) ->
                    key to sorted(value)
                },
        )
        is JsonArray -> JsonArray(element.map(::sorted))
        else -> element
    }

    private fun objectValue(json: String?): JsonObject? =
        json?.let {
            try {
                Json.parseToJsonElement(it) as? JsonObject
            } catch (_: Exception) {
                null
            }
        }

    private fun JsonObject.stringValue(name: String): String? =
        (this[name] as? kotlinx.serialization.json.JsonPrimitive)
            ?.takeIf { it.isString }
            ?.content

    private fun JsonObject.legacyStringValue(name: String): String? =
        (this[name] as? JsonPrimitive)?.contentOrNull

    private fun entry(name: String): ZipEntry = ZipEntry(name).apply {
        time = 0
    }

    private fun forEachRecord(
        snapshot: CanonicalExportSnapshot,
        consume: (CanonicalRecord) -> Unit,
    ) {
        var after: String? = null
        while (true) {
            val page = snapshot.recordsPage(after, PAGE_SIZE)
            if (page.isEmpty()) {
                return
            }

            page.forEach(consume)
            after = page.last().canonicalId
        }
    }

    private fun forEachRunRecord(
        snapshot: CanonicalExportSnapshot,
        consume: (ArchiveRunRecord) -> Unit,
    ) {
        var after: Long? = null
        while (true) {
            val page = snapshot.runRecordsPage(after, PAGE_SIZE)
            if (page.isEmpty()) {
                return
            }
            page.forEach(consume)
            after = page.last().ordinal
        }
    }

    private companion object {
        const val PAGE_SIZE = 500
        const val MAX_CANONICAL_RECORD_BYTES = 512 * 1_024
        val sourceNamespacePattern = Regex("^[A-Za-z0-9._-]+$")
    }

    private class CloseShieldOutputStream(
        output: OutputStream,
    ) : FilterOutputStream(output) {
        override fun close() {
            flush()
        }
    }
}
