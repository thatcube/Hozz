package com.thatcube.hozz.core

import com.thatcube.hozz.generated.GeneratedContract
import java.io.OutputStream
import java.security.MessageDigest
import java.time.Instant
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

data class ArchiveExportResult(
    val archiveId: String,
    val recordCount: Int,
)

class CanonicalArchiveExporter(
    private val store: CanonicalRecordStore,
) {
    suspend fun export(output: OutputStream): ArchiveExportResult {
        val digest = MessageDigest.getInstance("SHA-256")
        var recordCount = 0
        var createdAt = Instant.EPOCH
        forEachRecord { record ->
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

        ZipOutputStream(output.buffered()).use { archive ->
            archive.putNextEntry(entry(ArchiveManifest.ENTRY_NAME))
            archive.write(manifest.toByteArray())
            archive.closeEntry()

            archive.putNextEntry(entry(recordsEntry))
            forEachRecord { record ->
                archive.write(canonicalJson(record).toByteArray())
                archive.write('\n'.code)
            }
            archive.closeEntry()
        }
        return ArchiveExportResult(archiveId, recordCount)
    }

    internal fun canonicalJson(record: CanonicalRecord): String {
        val raw = Json.parseToJsonElement(record.rawJson).jsonObject
        val normalized = buildJsonObject {
            raw.forEach { (key, value) -> put(key, value) }
            put("schemaVersion", GeneratedContract.SCHEMA_VERSION)
            put("canonicalId", record.canonicalId)
            put("canonicalType", record.canonicalType)
            put("recordVersion", record.recordVersion)
            put("kind", record.kind)
            if (!raw.containsKey("id")) {
                put("id", record.canonicalId)
            }
            put("type", record.type)
            record.parentCanonicalId?.let { put("parentCanonicalId", it) }
            if (record.tombstone) {
                put("deleted", true)
            }
            put(
                "sourceRecord",
                buildJsonObject {
                    (raw["sourceRecord"] as? JsonObject)?.forEach { (key, value) ->
                        put(key, value)
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
                    val existing = raw["lineage"] as? JsonArray
                    existing?.forEach(::add)
                    val existingKeys = existing
                        ?.mapNotNull { it as? JsonObject }
                        ?.map {
                            Triple(
                                it["store"]?.toString(),
                                it["package"]?.toString(),
                                it["recordId"]?.toString(),
                            )
                        }
                        ?.toSet()
                        ?: emptySet()
                    record.lineage.forEach { lineage ->
                        val key = Triple(
                            "\"${lineage.store}\"",
                            lineage.packageName?.let { "\"$it\"" },
                            lineage.recordId?.let { "\"$it\"" },
                        )
                        if (key in existingKeys) {
                            return@forEach
                        }
                        add(
                            buildJsonObject {
                                put("store", lineage.store)
                                lineage.packageName?.let { put("package", it) }
                                lineage.recordId?.let { put("recordId", it) }
                            },
                        )
                    }
                },
            )
            record.canonicalValue?.let { canonical ->
                val existing = raw["quantity"] as? JsonObject
                put(
                    "quantity",
                    buildJsonObject {
                        existing?.forEach { (key, value) -> put(key, value) }
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
                        if (original != null) {
                            put(
                                "original",
                                valueJson(original, existingOriginal),
                            )
                        } else if (existingOriginal != null) {
                            put("original", existingOriginal)
                        }
                    },
                )
            }
        }
        return sorted(normalized).toString()
    }

    private fun valueJson(
        value: CanonicalValue,
        existing: JsonObject?,
    ): JsonElement =
        buildJsonObject {
            existing?.forEach { (key, nestedValue) -> put(key, nestedValue) }
            put("value", value.value)
            put("unit", value.unit ?: "")
            value.description?.let { put("description", it) }
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

    private fun entry(name: String): ZipEntry = ZipEntry(name).apply {
        time = 0
    }

    private suspend fun forEachRecord(
        consume: (CanonicalRecord) -> Unit,
    ) {
        var after: String? = null
        while (true) {
            val page = store.recordsPage(after, PAGE_SIZE)
            if (page.isEmpty()) {
                return
            }
            page.forEach(consume)
            after = page.last().canonicalId
            if (page.size < PAGE_SIZE) {
                return
            }
        }
    }

    private companion object {
        const val PAGE_SIZE = 500
    }
}
