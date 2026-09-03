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

interface CanonicalRecordStore {
    suspend fun upsert(records: List<CanonicalRecord>): MergeResult
    suspend fun beginImport(): CanonicalImportSession
    suspend fun timeline(limit: Int = 200): List<CanonicalRecord>
    suspend fun recordsPage(afterCanonicalId: String?, limit: Int): List<CanonicalRecord>
    suspend fun recordCount(): Int
    suspend fun allRecords(): List<CanonicalRecord>
}

interface CanonicalImportSession {
    suspend fun append(records: List<CanonicalRecord>)
    suspend fun commit(): MergeResult
    suspend fun discard()
}

class InMemoryCanonicalRecordStore : CanonicalRecordStore {
    private val records = linkedMapOf<String, CanonicalRecord>()

    override suspend fun upsert(records: List<CanonicalRecord>): MergeResult {
        return merge(records)
    }

    override suspend fun beginImport(): CanonicalImportSession =
        object : CanonicalImportSession {
            private val staged = linkedMapOf<String, CanonicalRecord>()
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

            override suspend fun commit(): MergeResult {
                check(!finished)
                finished = true
                return merge(staged.values.toList())
            }

            override suspend fun discard() {
                finished = true
                staged.clear()
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
            if (effective.tombstone) {
                this.records.replaceAll { _, child ->
                    if (child.parentCanonicalId == effective.canonicalId) {
                        child.copy(
                            recordVersion = maxOf(
                                child.recordVersion,
                                effective.recordVersion,
                            ),
                            tombstone = true,
                        )
                    } else {
                        child
                    }
                }
            }
        }
        return result
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
}
