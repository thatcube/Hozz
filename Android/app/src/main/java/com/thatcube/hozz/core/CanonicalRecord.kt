package com.thatcube.hozz.core

import com.thatcube.hozz.generated.GeneratedContract
import java.security.MessageDigest
import java.time.Instant
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
    val resolutionCanonicalId: String? = null,
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
        "typeCoverage",
        "completion",
    )

    fun parse(line: String, strictV1: Boolean = false): CanonicalRecord? {
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
        if (strictV1) {
            validateStrict(jsonObject, kind)
        }
        if (kind in runKinds) {
            return null
        }

        val sourceRecord = jsonObject.objectValue("sourceRecord")
        val topLevelId = jsonObject.string("id")
        val sourceStore = sourceRecord?.string("store")
            ?: GeneratedContract.SOURCE_STORE
        if (!sourceStore.matches(sourceNamespacePattern)) {
            throw ArchiveFormatException(
                "Canonical record has an invalid source namespace.",
            )
        }
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
        if (kind in syntheticIdentityKinds && topLevelId == null) {
            throw ArchiveFormatException(
                "A synthetic canonical record has no top-level id.",
            )
        }
        val canonicalSourceId = when {
            kind == "sampleEncodingError" ->
                encodingFailureId(sourceId, type)
            else -> topLevelId ?: auxiliarySourceId(jsonObject, kind, line)
        }
        if (topLevelId != null) {
            validateSyntheticIdentity(
                jsonObject,
                kind,
                topLevelId,
                sourceId,
                type,
            )
        }
        val encodedCanonicalId = jsonObject.string("canonicalId")
        if (encodedCanonicalId != null) {
            val encodedId = topLevelId
                ?: throw ArchiveFormatException(
                    "A record with canonicalId has no top-level id.",
                )
            val expected =
                GeneratedContract.canonicalId(sourceStore, encodedId)
            if (encodedCanonicalId != expected) {
                throw ArchiveFormatException(
                    "Canonical record $encodedCanonicalId does not match $expected.",
                )
            }
        }
        val encodedParentCanonicalId =
            jsonObject.string("parentCanonicalId")
        val expectedParentCanonicalId =
            GeneratedContract.canonicalId(sourceStore, sourceId)
        if (
            kind !in syntheticIdentityKinds &&
            topLevelId != null &&
            topLevelId != sourceId
        ) {
            throw ArchiveFormatException(
                "Canonical source record id does not match its top-level id.",
            )
        }
        if (
            encodedParentCanonicalId != null &&
            kind in parentedKinds &&
            encodedParentCanonicalId != expectedParentCanonicalId
        ) {
            throw ArchiveFormatException(
                "Canonical record parent identity does not match its source record.",
            )
        }
        val sampleId = jsonObject.string("sample")
        if (
            kind in seriesRecordKinds &&
            sampleId != null &&
            sampleId != sourceId
        ) {
            throw ArchiveFormatException(
                "Canonical record sample does not match its source record.",
            )
        }
        if (kind in seriesRecordKinds && !seriesKindMatchesType(kind, type)) {
            throw ArchiveFormatException(
                "Canonical series kind does not match its source type.",
            )
        }
        val resolutionCanonicalId =
            jsonObject.string("resolutionCanonicalId")
        if (
            resolutionCanonicalId != null &&
            resolutionCanonicalId != GeneratedContract.canonicalId(
                sourceStore,
                seriesEndId(sourceId, type),
            )
        ) {
            throw ArchiveFormatException(
                "Canonical record resolution identity is not its series end marker.",
            )
        }
        val canonicalId = encodedCanonicalId
            ?: GeneratedContract.canonicalId(sourceStore, canonicalSourceId)
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
            parentCanonicalId = if (kind in parentedKinds) {
                expectedParentCanonicalId
            } else {
                encodedParentCanonicalId
            },
            recordVersion = recordVersion,
            kind = kind,
            canonicalType = canonicalType,
            type = type,
            startTime = jsonObject.instant("startDate")
                ?: jsonObject.instant("readAt"),
            endTime = jsonObject.instant("endDate")
                ?: jsonObject.instant("startDate")
                ?: jsonObject.instant("readAt"),
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
            resolutionCanonicalId = resolutionCanonicalId,
        )
    }

    internal fun kind(line: String): String =
        Json.parseToJsonElement(line).jsonObject.string("kind")
            ?: throw ArchiveFormatException("A record has no kind.")

    internal fun isRunKind(kind: String): Boolean = kind in runKinds

    internal fun runIdentifier(line: String): String? =
        Json.parseToJsonElement(line).jsonObject.string("run")

    internal fun normalizedRunLine(line: String): String {
        val raw = Json.parseToJsonElement(line).jsonObject
        if (raw.containsKey("schemaVersion")) {
            validateStrict(line)
            return line
        }
        val normalized = sorted(
            JsonObject(
                raw + (
                    "schemaVersion" to
                        JsonPrimitive(GeneratedContract.SCHEMA_VERSION)
                ),
            ),
        ).toString()
        validateStrict(normalized)
        return normalized
    }

    internal fun validateStrict(line: String) {
        val jsonObject = Json.parseToJsonElement(line).jsonObject
        val kind = jsonObject.string("kind")
            ?: throw ArchiveFormatException("A record has no kind.")
        val schemaVersion = strictLong(jsonObject, "schemaVersion")
        if (schemaVersion != GeneratedContract.SCHEMA_VERSION.toLong()) {
            throw ArchiveFormatException(
                "Record schema $schemaVersion is not supported.",
            )
        }
        validateStrict(jsonObject, kind)
    }

    private fun validateStrict(jsonObject: JsonObject, kind: String) {
        jsonObject.nonblank("kind")
        if (kind in runKinds) {
            validateRunRecord(jsonObject, kind)
            return
        }
        val canonicalId = jsonObject.nonblank("canonicalId")
        jsonObject.nonblank("canonicalType")
        strictLong(jsonObject, "recordVersion", minimum = 1)
        val type = jsonObject.nonblank("type")
        val topLevelId = jsonObject.nonblank("id")
        if (jsonObject.containsKey("parentCanonicalId")) {
            jsonObject.nonblank("parentCanonicalId")
        }
        if (jsonObject.containsKey("deleted")) {
            jsonObject.strictBoolean("deleted")
        }
        for (field in listOf("source", "device", "metadata")) {
            if (jsonObject.containsKey(field) && jsonObject[field] !is JsonObject) {
                throw ArchiveFormatException("Record field $field is not an object.")
            }
        }
        val sourceRecord = jsonObject["sourceRecord"] as? JsonObject
            ?: throw ArchiveFormatException(
                "Canonical record $canonicalId has no sourceRecord.",
            )
        val sourceStore = sourceRecord.nonblank("store")
        if (!sourceStore.matches(sourceNamespacePattern)) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId has an invalid source namespace.",
            )
        }
        val sourceId = sourceRecord.nonblank("id")
        val sourceType = sourceRecord.nonblank("type")
        validateSyntheticIdentity(
            jsonObject,
            kind,
            topLevelId,
            sourceId,
            type,
        )
        val expectedCanonicalId =
            GeneratedContract.canonicalId(sourceStore, topLevelId)
        if (canonicalId != expectedCanonicalId) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId does not match source namespace " +
                    "and top-level id $expectedCanonicalId.",
            )
        }
        if (sourceType != type) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId disagrees with its source type.",
            )
        }
        if (kind !in syntheticIdentityKinds && topLevelId != sourceId) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId id disagrees with its source record.",
            )
        }
        if (sourceRecord.containsKey("version")) {
            strictLong(sourceRecord, "version", minimum = 1)
        }
        val lineage = jsonObject["lineage"] as? JsonArray
            ?: throw ArchiveFormatException(
                "Canonical record $canonicalId has no lineage.",
            )
        if (lineage.isEmpty()) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId has empty lineage.",
            )
        }
        lineage.forEach { element ->
            val entry = element as? JsonObject
                ?: throw ArchiveFormatException(
                    "Canonical record $canonicalId has a non-object lineage entry.",
                )
            val lineageStore = entry.nonblank("store")
            if (!lineageStore.matches(sourceNamespacePattern)) {
                throw ArchiveFormatException(
                    "Canonical record $canonicalId has an invalid lineage namespace.",
                )
            }
            for (field in listOf("package", "recordId")) {
                if (entry.containsKey(field)) {
                    entry.nonblank(field)
                }
            }
        }
        val hasOrigin = lineage.any { element ->
            val entry = element as? JsonObject ?: return@any false
            entry.string("store") == sourceStore &&
                entry.string("recordId") == sourceId
        }
        if (!hasOrigin) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId lineage omits its source record.",
            )
        }
        if (kind in parentedKinds) {
            val expectedParent =
                GeneratedContract.canonicalId(sourceStore, sourceId)
            if (jsonObject.nonblank("parentCanonicalId") != expectedParent) {
                throw ArchiveFormatException(
                    "Canonical record $canonicalId has an invalid parent identity.",
                )
            }
        }
        if (
            kind in seriesRecordKinds &&
            jsonObject.containsKey("sample") &&
            jsonObject.nonblank("sample") != sourceId
        ) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId sample disagrees with its source record.",
            )
        }
        if (kind in seriesRecordKinds && !seriesKindMatchesType(kind, type)) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId series kind disagrees with its type.",
            )
        }
        if (jsonObject.containsKey("resolutionCanonicalId")) {
            val resolution = jsonObject.nonblank("resolutionCanonicalId")
            val expectedResolution = GeneratedContract.canonicalId(
                sourceStore,
                seriesEndId(sourceId, type),
            )
            if (resolution != expectedResolution) {
                throw ArchiveFormatException(
                    "Canonical record $canonicalId has an invalid series " +
                        "completion identity.",
                )
            }
        }
        val expected = GeneratedContract.archiveOnlyCanonicalTypes[kind]
            ?: GeneratedContract.recordMappings[type]?.canonicalType
            ?: GeneratedContract.sourceCanonicalTypes[type]
            ?: GeneratedContract.sourceCanonicalTypePrefixes.entries
                .firstOrNull { type.startsWith(it.key) }
                ?.value
        if (
            expected != null &&
            jsonObject.string("canonicalType") != expected
        ) {
            throw ArchiveFormatException(
                "Canonical record $canonicalId has canonicalType " +
                    "${jsonObject.string("canonicalType")}; expected $expected.",
            )
        }
        validateKindFields(jsonObject, kind)
    }

    private fun validateRunRecord(jsonObject: JsonObject, kind: String) {
        when (kind) {
            "manifest" -> {
                jsonObject.nonblank("run")
                jsonObject.strictInstant("createdAt")
            }
            "resume" -> {
                jsonObject.nonblank("run")
                jsonObject.strictInstant("resumedAt")
            }
            "typeSummary" -> {
                jsonObject.nonblank("type")
                jsonObject.nonblank("state")
            }
            "typeError" -> {
                jsonObject.nonblank("type")
                jsonObject.nonblank("message")
            }
            "typeCoverage" -> {
                jsonObject.nonblank("type")
                jsonObject.nonblank("state")
                jsonObject.strictBoolean("complete")
                jsonObject.strictInstant("observedAt")
                if (jsonObject.containsKey("deliveredCount")) {
                    strictLong(jsonObject, "deliveredCount", minimum = 0)
                }
                for (field in listOf("primedFrom", "primedThrough")) {
                    if (jsonObject.containsKey(field)) {
                        jsonObject.strictInstant(field)
                    }
                }
            }
            "completion" -> {
                jsonObject.nonblank("run")
                jsonObject.strictInstant("completedAt")
                strictLong(jsonObject, "records", minimum = 0)
            }
        }
    }

    private fun strictLong(
        jsonObject: JsonObject,
        name: String,
        minimum: Long = Long.MIN_VALUE,
    ): Long {
        val primitive = jsonObject[name] as? JsonPrimitive
            ?: throw ArchiveFormatException("Record field $name is not an integer.")
        if (primitive.isString) {
            throw ArchiveFormatException("Record field $name is not an integer.")
        }
        val value = primitive.longOrNull
            ?: throw ArchiveFormatException("Record field $name is not an integer.")
        if (value < minimum) {
            throw ArchiveFormatException(
                "Record field $name must be at least $minimum.",
            )
        }
        return value
    }

    private fun strictInt(jsonObject: JsonObject, name: String): Int {
        val value = strictLong(jsonObject, name)
        if (value !in Int.MIN_VALUE..Int.MAX_VALUE) {
            throw ArchiveFormatException(
                "Record field $name is outside the supported integer range.",
            )
        }
        return value.toInt()
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

    private fun validateKindFields(jsonObject: JsonObject, kind: String) {
        when (kind) {
            "quantity" -> {
                jsonObject.strictInstant("startDate")
                jsonObject.strictInstant("endDate")
                val quantity = jsonObject["quantity"] as? JsonObject
                if (quantity == null) {
                    throw ArchiveFormatException(
                        "A quantity record has no quantity object.",
                    )
                }
                quantity.nonblank("unit")
                quantity.strictDouble("value")
                if (quantity.containsKey("canonical")) {
                    val canonical = quantity["canonical"] as? JsonObject
                        ?: throw ArchiveFormatException(
                            "Record field quantity.canonical is not an object.",
                        )
                    canonical.nonblank("unit")
                    canonical.strictDouble("value")
                }
                if (quantity.containsKey("original")) {
                    val original = quantity["original"] as? JsonObject
                        ?: throw ArchiveFormatException(
                            "Record field quantity.original is not an object.",
                        )
                    if (original.containsKey("unit")) {
                        original.nonblank("unit")
                    }
                    if (original.containsKey("value")) {
                        original.strictDouble("value")
                    }
                }
            }
            "category" -> {
                jsonObject.strictInstant("startDate")
                jsonObject.strictInstant("endDate")
                strictInt(jsonObject, "value")
            }
            "workout" -> {
                jsonObject.strictInstant("startDate")
                jsonObject.strictInstant("endDate")
                strictInt(jsonObject, "activityType")
            }
            "characteristics" -> {
                jsonObject.strictInstant("readAt")
                if (jsonObject["characteristics"] !is JsonObject) {
                    throw ArchiveFormatException(
                        "A characteristics record has no characteristics object.",
                    )
                }
            }
            "sampleEncodingError" -> {
                jsonObject.nonblank("message")
                jsonObject.nonblank("parentCanonicalId")
            }
            "electrocardiogramEnd",
            "electrocardiogramVoltages",
            "quantitySeriesEnd",
            "quantitySeriesReadings",
            "workoutRouteEnd",
            "workoutRouteLocations" -> {
                jsonObject.nonblank("parentCanonicalId")
            jsonObject.strictInstant("startDate")
            jsonObject.strictInstant("endDate")
            }
            "audiogram",
            "clinicalRecord",
            "correlation",
            "electrocardiogram",
            "medicationDose",
            "sample",
            "stateOfMind",
            "workoutRoute" -> {
                jsonObject.strictInstant("startDate")
                jsonObject.strictInstant("endDate")
            }
            "deletion" -> Unit
            else -> {
                jsonObject.strictInstant("startDate")
                jsonObject.strictInstant("endDate")
            }
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

    internal fun seriesEndId(sourceId: String, type: String): String {
        return seriesRecordId(sourceId, type, "end")
    }

    internal fun seriesRecordId(
        sourceId: String,
        type: String,
        suffix: String,
    ): String {
        val sourceUUID = try {
            UUID.fromString(sourceId)
        } catch (_: IllegalArgumentException) {
            throw ArchiveFormatException(
                "A series completion identity requires a UUID source id.",
            )
        }

        val sourceBytes = ByteBuffer.allocate(16)
            .putLong(sourceUUID.mostSignificantBits)
            .putLong(sourceUUID.leastSignificantBits)
            .array()
        val digest = MessageDigest.getInstance("SHA-256").apply {
            update(type.toByteArray())
            update(sourceBytes)
            update(suffix.toByteArray())
        }.digest().copyOfRange(0, 16)
        digest[6] = ((digest[6].toInt() and 0x0F) or 0x50).toByte()
        digest[8] = ((digest[8].toInt() and 0x3F) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(digest)
        return UUID(buffer.long, buffer.long).toString().lowercase()
    }

    private fun validateSyntheticIdentity(
        jsonObject: JsonObject,
        kind: String,
        topLevelId: String,
        sourceId: String,
        type: String,
    ) {
        if (kind !in syntheticIdentityKinds) return
        val canonicalSourceId = try {
            UUID.fromString(sourceId).toString().lowercase()
        } catch (_: IllegalArgumentException) {
            throw ArchiveFormatException(
                "A synthetic identity requires a UUID source id.",
            )
        }
        if (sourceId != canonicalSourceId) {
            throw ArchiveFormatException(
                "A synthetic identity requires canonical lowercase UUID text.",
            )
        }
        val expected = when (kind) {
            "sampleEncodingError" -> encodingFailureId(sourceId, type)
            "electrocardiogramEnd",
            "quantitySeriesEnd",
            "workoutRouteEnd" -> seriesEndId(sourceId, type)
            "electrocardiogramVoltages" -> seriesRecordId(
                sourceId,
                type,
                "voltages-${strictLong(jsonObject, "sequence", minimum = 0)}",
            )
            "quantitySeriesReadings" -> seriesRecordId(
                sourceId,
                type,
                "readings-${strictLong(jsonObject, "sequence", minimum = 0)}",
            )
            "workoutRouteLocations" -> seriesRecordId(
                sourceId,
                type,
                "locations-${strictLong(jsonObject, "sequence", minimum = 0)}",
            )
            "clinicalRecord" -> clinicalRecordId(jsonObject, sourceId)
            else -> return
        }
        if (topLevelId != expected) {
            throw ArchiveFormatException(
                "Canonical synthetic record id does not match its derivation.",
            )
        }
    }

    private fun clinicalRecordId(
        jsonObject: JsonObject,
        sourceId: String,
    ): String {
        if (jsonObject.boolean("identityIsStable") != true) {
            return sourceId
        }
        val source = jsonObject["source"] as? JsonObject
            ?: throw ArchiveFormatException(
                "A stable clinical identity has no source.",
            )
        val fhir = jsonObject["fhir"] as? JsonObject
            ?: throw ArchiveFormatException(
                "A stable clinical identity has no FHIR facts.",
            )
        val sourceBundle = source.nonblank("bundleIdentifier")
        val resourceType = fhir.nonblank("resourceType")
        val identifier = fhir.nonblank("identifier")
        val digest = MessageDigest.getInstance("SHA-256").apply {
            update("HKClinicalRecord".toByteArray())
            update(sourceBundle.toByteArray())
            update(0.toByte())
            update(resourceType.toByteArray())
            update(0.toByte())
            update(identifier.toByteArray())
        }.digest().copyOfRange(0, 16)
        digest[6] = ((digest[6].toInt() and 0x0F) or 0x50).toByte()
        digest[8] = ((digest[8].toInt() and 0x3F) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(digest)
        return UUID(buffer.long, buffer.long).toString().lowercase()
    }

    internal fun seriesEndKind(type: String): String = when (type) {
        "HKWorkoutRouteTypeIdentifier" -> "workoutRouteEnd"
        "HKDataTypeIdentifierElectrocardiogram" -> "electrocardiogramEnd"
        else -> "quantitySeriesEnd"
    }

    private fun seriesKindMatchesType(kind: String, type: String): Boolean =
        when (type) {
            "HKWorkoutRouteTypeIdentifier" ->
                kind == "workoutRouteEnd" ||
                    kind == "workoutRouteLocations"
            "HKDataTypeIdentifierElectrocardiogram" ->
                kind == "electrocardiogramEnd" ||
                    kind == "electrocardiogramVoltages"
            else ->
                kind == "quantitySeriesEnd" ||
                    kind == "quantitySeriesReadings"
        }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }

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

    private val parentedKinds = setOf(
        "sampleEncodingError",
        "electrocardiogramEnd",
        "electrocardiogramVoltages",
        "quantitySeriesEnd",
        "quantitySeriesReadings",
        "workoutRouteEnd",
        "workoutRouteLocations",
    )
    private val seriesRecordKinds = parentedKinds - "sampleEncodingError"
    private val syntheticIdentityKinds = parentedKinds + "clinicalRecord"
    private val sourceNamespacePattern = Regex("^[A-Za-z0-9._-]+$")
}

open class ArchiveFormatException(message: String) : Exception(message)

private fun JsonObject.string(name: String): String? =
    this[name]?.jsonPrimitive?.contentOrNull

private fun JsonObject.nonblank(name: String): String {
    val primitive = this[name] as? JsonPrimitive
        ?: throw ArchiveFormatException("Record field $name is missing or blank.")
    if (!primitive.isString) {
        throw ArchiveFormatException("Record field $name is not a string.")
    }
    val value = primitive.contentOrNull
    if (value.isNullOrBlank()) {
        throw ArchiveFormatException("Record field $name is missing or blank.")
    }
    return value
}

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

private fun JsonObject.strictInstant(name: String): Instant =
    instant(name)
        ?: throw ArchiveFormatException("Record field $name is missing or blank.")

private fun JsonObject.strictDouble(name: String): Double {
    val primitive = this[name] as? JsonPrimitive
        ?: throw ArchiveFormatException("Record field $name is not a number.")
    if (primitive.isString) {
        throw ArchiveFormatException("Record field $name is not a number.")
    }
    val value = primitive.doubleOrNull
        ?: throw ArchiveFormatException("Record field $name is not a number.")
    if (!value.isFinite()) {
        throw ArchiveFormatException("Record field $name is not finite.")
    }
    return value
}

private fun JsonObject.strictBoolean(name: String): Boolean {
    val primitive = this[name] as? JsonPrimitive
        ?: throw ArchiveFormatException("Record field $name is not a boolean.")
    if (primitive.isString) {
        throw ArchiveFormatException("Record field $name is not a boolean.")
    }
    return primitive.booleanOrNull
        ?: throw ArchiveFormatException("Record field $name is not a boolean.")
}

private fun JsonObject.objectValue(name: String): JsonObject? =
    this[name] as? JsonObject

private fun JsonObject.array(name: String): JsonArray? =
    this[name] as? JsonArray
