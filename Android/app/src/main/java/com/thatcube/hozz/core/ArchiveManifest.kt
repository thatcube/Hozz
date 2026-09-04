package com.thatcube.hozz.core

import com.thatcube.hozz.generated.GeneratedContract
import java.time.Instant
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.SerializationException

data class ArchiveManifest(
    val schemaVersion: Int,
    val archiveId: String,
    val format: String,
    val recordSchema: String,
    val recordsEntry: String,
    val createdAt: Instant,
    val recordCount: Long?,
) {
    companion object {
        const val ENTRY_NAME = "hozz-manifest.json"
        const val FORMAT = "hozz-ndjson"
        const val RECORD_SCHEMA = "hozz/v1/canonical-record"

        fun parse(json: String): ArchiveManifest {
            try {
                return decode(json)
            } catch (error: SerializationException) {
                throw ArchiveFormatException("The archive manifest is not valid JSON.")
            } catch (error: IllegalArgumentException) {
                throw ArchiveFormatException(
                    error.message ?: "The archive manifest is invalid.",
                )
            }
        }

        private fun decode(json: String): ArchiveManifest {
            val jsonObject = ArchiveJson.objectValue(
                json = json,
                subject = "Archive manifest",
                rootError = "The archive manifest must be a JSON object.",
            )
            val unknownKeys = jsonObject.keys - allowedKeys
            if (unknownKeys.isNotEmpty()) {
                throw ArchiveFormatException(
                    "The archive manifest contains unknown fields: " +
                        unknownKeys.sorted().joinToString(),
                )
            }
            val schemaVersion = jsonObject["schemaVersion"]?.jsonPrimitive?.intOrNull
                ?: throw ArchiveFormatException("The archive manifest has no schemaVersion.")
            if (schemaVersion != GeneratedContract.SCHEMA_VERSION) {
                throw ArchiveFormatException(
                    "Archive schema $schemaVersion is not supported.",
                )
            }
            val format = jsonObject["format"]?.jsonPrimitive?.contentOrNull
            if (format != FORMAT) {
                throw ArchiveFormatException("Archive format $format is not supported.")
            }
            val recordSchema = jsonObject["recordSchema"]?.jsonPrimitive?.contentOrNull
            if (recordSchema != RECORD_SCHEMA) {
                throw ArchiveFormatException(
                    "Record schema $recordSchema is not supported.",
                )
            }
            val archiveId = jsonObject["archiveId"]?.jsonPrimitive?.contentOrNull
                ?.takeIf(String::isNotBlank)
                ?: throw ArchiveFormatException("The archive manifest has no archiveId.")
            val recordsEntry = jsonObject["recordsEntry"]?.jsonPrimitive?.contentOrNull
                ?: throw ArchiveFormatException("The archive manifest has no recordsEntry.")
            if (
                recordsEntry.isBlank() ||
                !recordsEntry.endsWith(".ndjson") ||
                '/' in recordsEntry ||
                '\\' in recordsEntry ||
                recordsEntry == "." ||
                recordsEntry == ".."
            ) {
                throw ArchiveFormatException("The manifest recordsEntry is not NDJSON.")
            }
            val createdAtText = jsonObject["createdAt"]?.jsonPrimitive?.contentOrNull
                ?: throw ArchiveFormatException("The archive manifest has no createdAt.")
            val createdAt = try {
                Instant.parse(createdAtText)
            } catch (_: Exception) {
                throw ArchiveFormatException("The archive manifest createdAt is invalid.")
            }
            val recordCount = jsonObject["recordCount"]?.let { value ->
                val primitive = value as? JsonPrimitive
                    ?: throw ArchiveFormatException(
                        "The archive manifest recordCount is not an integer.",
                    )
                if (primitive.isString) {
                    throw ArchiveFormatException(
                        "The archive manifest recordCount is not an integer.",
                    )
                }
                val count = primitive.longOrNull
                    ?: throw ArchiveFormatException(
                        "The archive manifest recordCount is not an integer.",
                    )
                if (count < 0) {
                    throw ArchiveFormatException(
                        "The archive manifest recordCount cannot be negative.",
                    )
                }
                count
            }
            jsonObject["sourcePlatform"]?.let { value ->
                val platform = (value as? JsonPrimitive)
                    ?.takeIf(JsonPrimitive::isString)
                    ?.contentOrNull
                if (platform.isNullOrBlank()) {
                    throw ArchiveFormatException(
                        "The archive manifest sourcePlatform is invalid.",
                    )
                }
            }
            return ArchiveManifest(
                schemaVersion = schemaVersion,
                archiveId = archiveId,
                format = format,
                recordSchema = recordSchema,
                recordsEntry = recordsEntry,
                createdAt = createdAt,
                recordCount = recordCount,
            )
        }

        private val allowedKeys = setOf(
            "schemaVersion",
            "archiveId",
            "format",
            "recordSchema",
            "recordsEntry",
            "createdAt",
            "recordCount",
            "sourcePlatform",
        )
    }
}
