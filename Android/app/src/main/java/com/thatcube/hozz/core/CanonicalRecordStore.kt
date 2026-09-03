package com.thatcube.hozz.core

data class MergeResult(
    val inserted: Int = 0,
    val updated: Int = 0,
    val ignored: Int = 0,
    val tombstones: Int = 0,
) {
    operator fun plus(other: MergeResult): MergeResult = MergeResult(
        inserted = inserted + other.inserted,
        updated = updated + other.updated,
        ignored = ignored + other.ignored,
        tombstones = tombstones + other.tombstones,
    )
}

data class ArchiveRunRecord(
    val kind: String,
    val rawJson: String,
    val fingerprint: String,
    val occurrence: Int,
    val ordinal: Long,
)

data class HealthConnectProjection(
    val canonicalId: String,
    val targetRecord: String,
    val canonicalVersion: Long,
    val healthConnectRecordId: String,
)

interface CanonicalRecordStore {
    suspend fun upsert(records: List<CanonicalRecord>): MergeResult
    suspend fun beginImport(): CanonicalImportSession
    suspend fun timeline(limit: Int = 200): List<CanonicalRecord>
    suspend fun recordsPage(afterCanonicalId: String?, limit: Int): List<CanonicalRecord>
    suspend fun recordCount(): Int
    suspend fun allRecords(): List<CanonicalRecord>
    suspend fun runRecordsPage(afterSequence: Long?, limit: Int): List<ArchiveRunRecord>
    suspend fun healthConnectProjections(
        canonicalIds: Set<String>,
    ): Map<String, HealthConnectProjection>
    suspend fun saveHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    )
    suspend fun removeHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    )
}

interface CanonicalImportSession {
    suspend fun append(records: List<CanonicalRecord>)
    suspend fun appendRunRecords(records: List<ArchiveRunRecord>)
    suspend fun commit(): MergeResult
    suspend fun discard()
}

class InMemoryCanonicalRecordStore : CanonicalRecordStore {
    private val records = linkedMapOf<String, CanonicalRecord>()
    private val runRecords = linkedMapOf<String, ArchiveRunRecord>()
    private val healthConnectProjections =
        linkedMapOf<String, HealthConnectProjection>()

    override suspend fun upsert(records: List<CanonicalRecord>): MergeResult {
        return merge(records)
    }

    override suspend fun beginImport(): CanonicalImportSession =
        object : CanonicalImportSession {
            private val staged = linkedMapOf<String, CanonicalRecord>()
            private val stagedRunRecords = linkedMapOf<String, ArchiveRunRecord>()
            private var finished = false

            override suspend fun append(records: List<CanonicalRecord>) {
                check(!finished)
                for (record in records) {
                    val current = staged[record.canonicalId]
                    if (current == null || record.recordVersion > current.recordVersion) {
                        staged[record.canonicalId] = record
                    }
                }
            }

            override suspend fun appendRunRecords(records: List<ArchiveRunRecord>) {
                check(!finished)
                for (record in records) {
                    stagedRunRecords[runKey(record)] = record
                }
            }

            override suspend fun commit(): MergeResult {
                check(!finished)
                finished = true
                val result = merge(staged.values.toList())
                for (record in stagedRunRecords.values.sortedBy(ArchiveRunRecord::ordinal)) {
                    runRecords.putIfAbsent(
                        runKey(record),
                        record.copy(
                            ordinal = (runRecords.values.maxOfOrNull {
                                it.ordinal
                            } ?: -1) + 1,
                        ),
                    )
                }
                return result
            }

            override suspend fun discard() {
                finished = true
                staged.clear()
                stagedRunRecords.clear()
            }
        }

    private fun merge(records: List<CanonicalRecord>): MergeResult {
        var result = MergeResult()
        for (incoming in records) {
            val parent = incoming.parentCanonicalId?.let(this.records::get)
            val effective = if (parent?.tombstone == true) {
                incoming.copy(
                    recordVersion = maxOf(
                        incoming.recordVersion,
                        parent.recordVersion,
                    ),
                    tombstone = true,
                )
            } else {
                incoming
            }
            val existing = this.records[effective.canonicalId]
            when {
                existing == null -> {
                    this.records[effective.canonicalId] = effective
                    result += MergeResult(
                        inserted = 1,
                        tombstones = if (effective.tombstone) 1 else 0,
                    )
                }
                effective.recordVersion > existing.recordVersion -> {
                    this.records[effective.canonicalId] = effective
                    result += MergeResult(
                        updated = 1,
                        tombstones = if (effective.tombstone) 1 else 0,
                    )
                }
                else -> result += MergeResult(ignored = 1)
            }
            val winningParent = this.records[effective.canonicalId]
            if (winningParent?.tombstone == true) {
                this.records.replaceAll { _, child ->
                    if (child.parentCanonicalId == winningParent.canonicalId) {
                        child.copy(
                            recordVersion = maxOf(
                                child.recordVersion,
                                winningParent.recordVersion,
                            ),
                            tombstone = true,
                        )
                    } else {
                        child
                    }
                }
            } else if (
                winningParent != null &&
                winningParent.kind != "sampleEncodingError"
            ) {
                this.records.replaceAll { _, child ->
                    if (
                        child.parentCanonicalId == winningParent.canonicalId &&
                        child.kind == "sampleEncodingError" &&
                        !child.tombstone
                    ) {
                        child.copy(
                            recordVersion = maxOf(
                                child.recordVersion + 1,
                                winningParent.recordVersion + 1,
                            ),
                            tombstone = true,
                        )
                    } else {
                        child
                    }
                }
            }
        }
        reconcileEncodingFailures()
        return result
    }

    private fun reconcileEncodingFailures() {
        records.replaceAll { _, record ->
            val parent = record.parentCanonicalId?.let(records::get)
            if (
                record.kind == "sampleEncodingError" &&
                !record.tombstone &&
                parent != null &&
                parent.kind != "sampleEncodingError" &&
                !parent.tombstone
            ) {
                record.copy(
                    recordVersion = maxOf(
                        record.recordVersion + 1,
                        parent.recordVersion + 1,
                    ),
                    tombstone = true,
                )
            } else {
                record
            }
        }
    }

    override suspend fun timeline(limit: Int): List<CanonicalRecord> =
        records.values
            .asSequence()
            .filterNot(CanonicalRecord::tombstone)
            .sortedByDescending { it.endTime ?: it.startTime }
            .take(limit)
            .toList()

    override suspend fun recordsPage(
        afterCanonicalId: String?,
        limit: Int,
    ): List<CanonicalRecord> = records.values
        .asSequence()
        .filter { afterCanonicalId == null || it.canonicalId > afterCanonicalId }
        .sortedBy(CanonicalRecord::canonicalId)
        .take(limit)
        .toList()

    override suspend fun recordCount(): Int = records.size

    override suspend fun allRecords(): List<CanonicalRecord> =
        records.values.toList()

    override suspend fun runRecordsPage(
        afterSequence: Long?,
        limit: Int,
    ): List<ArchiveRunRecord> = runRecords.values
        .asSequence()
        .filter { afterSequence == null || it.ordinal > afterSequence }
        .sortedBy(ArchiveRunRecord::ordinal)
        .take(limit)
        .toList()

    override suspend fun healthConnectProjections(
        canonicalIds: Set<String>,
    ): Map<String, HealthConnectProjection> =
        healthConnectProjections.filterKeys(canonicalIds::contains)

    override suspend fun saveHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        for (projection in projections) {
            val current = healthConnectProjections[projection.canonicalId]
            if (
                current == null ||
                projection.canonicalVersion >= current.canonicalVersion
            ) {
                healthConnectProjections[projection.canonicalId] = projection
            }
        }
    }

    override suspend fun removeHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        for (projection in projections) {
            if (
                healthConnectProjections[projection.canonicalId]
                    ?.healthConnectRecordId == projection.healthConnectRecordId
            ) {
                healthConnectProjections.remove(projection.canonicalId)
            }
        }
    }

    private fun runKey(record: ArchiveRunRecord): String =
        "${record.fingerprint}:${record.occurrence}"
}
