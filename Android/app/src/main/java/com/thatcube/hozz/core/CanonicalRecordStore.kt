package com.thatcube.hozz.core

import java.time.Instant
import java.util.ArrayDeque

internal const val MAX_CANONICAL_PARENT_DEPTH = 64

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

enum class HealthConnectPendingAction {
    UPSERT,
    DELETE,
}

data class PendingHealthConnectOperation(
    val canonicalId: String,
    val targetRecord: String,
    val canonicalVersion: Long,
    val action: HealthConnectPendingAction,
)

data class TimelineCursor(
    val sortTime: Instant?,
    val canonicalId: String,
)

data class TimelinePage(
    val records: List<CanonicalRecord>,
    val nextCursor: TimelineCursor?,
)

interface CanonicalExportSnapshot {
    fun recordsPage(afterCanonicalId: String?, limit: Int): List<CanonicalRecord>
    fun runRecordsPage(afterSequence: Long?, limit: Int): List<ArchiveRunRecord>
}

interface CanonicalRecordStore {
    suspend fun upsert(records: List<CanonicalRecord>): MergeResult
    suspend fun beginImport(): CanonicalImportSession
    suspend fun timelinePage(
        after: TimelineCursor? = null,
        limit: Int = 200,
    ): TimelinePage
    suspend fun timeline(limit: Int = 200): List<CanonicalRecord> =
        timelinePage(limit = limit).records
    suspend fun recordsPage(afterCanonicalId: String?, limit: Int): List<CanonicalRecord>
    suspend fun recordCount(): Int
    suspend fun allRecords(): List<CanonicalRecord>
    suspend fun runRecordsPage(afterSequence: Long?, limit: Int): List<ArchiveRunRecord>
    suspend fun healthConnectProjections(
        canonicalIds: Set<String>,
    ): Map<String, HealthConnectProjection>
    suspend fun pendingHealthConnectOperations(
        canonicalIds: Set<String>,
    ): Map<String, PendingHealthConnectOperation>
    suspend fun stageHealthConnectOperations(
        operations: List<PendingHealthConnectOperation>,
    )
    suspend fun completeHealthConnectUpserts(
        projections: List<HealthConnectProjection>,
    )
    suspend fun completeHealthConnectDeletes(
        operations: List<PendingHealthConnectOperation>,
    )
    suspend fun saveHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    )
    suspend fun removeHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    )
    suspend fun <T> withExportSnapshot(
        block: (CanonicalExportSnapshot) -> T,
    ): T
}

interface CanonicalImportSession {
    suspend fun append(records: List<CanonicalRecord>)
    suspend fun appendRunRecords(records: List<ArchiveRunRecord>)
    suspend fun commit(): MergeResult
    suspend fun discard()
}

internal data class CanonicalParentWinner(
    val recordVersion: Long,
    val parentCanonicalId: String?,
)

internal fun validateCanonicalParentGraph(
    startCanonicalIds: Iterable<String>,
    winner: (String) -> CanonicalParentWinner?,
) {
    val depthById = mutableMapOf<String, Int>()
    for (start in startCanonicalIds) {
        if (start in depthById) continue
        val path = mutableListOf<String>()
        val visiting = hashSetOf<String>()
        var canonicalId = start
        var baseDepth: Int
        while (true) {
            val knownDepth = depthById[canonicalId]
            if (knownDepth != null) {
                baseDepth = knownDepth
                break
            }
            val current = winner(canonicalId)
            if (current == null) {
                baseDepth = 0
                break
            }
            if (!visiting.add(canonicalId)) {
                throw ArchiveFormatException(
                    "Canonical records contain a parent cycle.",
                )
            }
            path += canonicalId
            val parentCanonicalId = current.parentCanonicalId
            if (parentCanonicalId == null) {
                baseDepth = -1
                break
            }
            canonicalId = parentCanonicalId
        }
        var depth = baseDepth
        for (pathId in path.asReversed()) {
            depth += 1
            if (depth > MAX_CANONICAL_PARENT_DEPTH) {
                throw ArchiveFormatException(
                    "Canonical parent depth exceeds the " +
                        "$MAX_CANONICAL_PARENT_DEPTH level limit.",
                )
            }
            depthById[pathId] = depth
        }
    }
}

internal fun recordsInParentWinnerOrder(
    records: List<CanonicalRecord>,
    persistedWinner: (String) -> CanonicalParentWinner?,
): List<CanonicalRecord> {
    if (records.any { it.parentCanonicalId == it.canonicalId }) {
        throw ArchiveFormatException("Canonical records contain a parent cycle.")
    }
    if (records.isEmpty()) return records
    val recordsById = linkedMapOf<String, MutableList<CanonicalRecord>>()
    val winnerById = linkedMapOf<String, CanonicalRecord>()
    for (record in records) {
        recordsById.getOrPut(record.canonicalId, ::mutableListOf) += record
        val winner = winnerById[record.canonicalId]
        if (winner == null || record.recordVersion > winner.recordVersion) {
            winnerById[record.canonicalId] = record
        }
    }

    val persistedById = mutableMapOf<String, CanonicalParentWinner?>()
    fun persisted(canonicalId: String): CanonicalParentWinner? {
        if (!persistedById.containsKey(canonicalId)) {
            persistedById[canonicalId] = persistedWinner(canonicalId)
        }
        return persistedById[canonicalId]
    }

    fun finalWinner(canonicalId: String): CanonicalParentWinner? {
        val persisted = persisted(canonicalId)
        val incoming = winnerById[canonicalId]
        return if (
            incoming != null &&
            (persisted == null || incoming.recordVersion > persisted.recordVersion)
        ) {
            CanonicalParentWinner(
                recordVersion = incoming.recordVersion,
                parentCanonicalId = incoming.parentCanonicalId,
            )
        } else {
            persisted
        }
    }

    validateCanonicalParentGraph(recordsById.keys, ::finalWinner)

    val dependencyCount = recordsById.keys.associateWithTo(linkedMapOf()) { 0 }
    val childrenByParent = linkedMapOf<String, LinkedHashSet<String>>()
    for (canonicalId in recordsById.keys) {
        val parentId = finalWinner(canonicalId)?.parentCanonicalId ?: continue
        if (recordsById.containsKey(parentId)) {
            dependencyCount[canonicalId] = 1
            childrenByParent.getOrPut(parentId, ::linkedSetOf) += canonicalId
        }
    }

    val ready = ArrayDeque<String>()
    dependencyCount.filterValues { it == 0 }.keys.forEach(ready::addLast)
    val ordered = ArrayList<CanonicalRecord>(records.size)
    while (ready.isNotEmpty()) {
        val canonicalId = ready.removeFirst()
        ordered += recordsById.getValue(canonicalId)
        for (childId in childrenByParent[canonicalId].orEmpty()) {
            val remaining = dependencyCount.getValue(childId) - 1
            dependencyCount[childId] = remaining
            if (remaining == 0) {
                ready.addLast(childId)
            }
        }
    }
    if (ordered.size != records.size) {
        throw ArchiveFormatException("Canonical records contain a parent cycle.")
    }
    return ordered
}

internal fun CanonicalRecord.deferredByParentTombstone(
    parentVersion: Long,
): CanonicalRecord = copy(
    recordVersion = if (tombstone) {
        maxOf(recordVersion, parentVersion)
    } else {
        parentVersion
    },
    tombstone = true,
)

class InMemoryCanonicalRecordStore : CanonicalRecordStore {
    private val records = linkedMapOf<String, CanonicalRecord>()
    private val runRecords = linkedMapOf<String, ArchiveRunRecord>()
    private val healthConnectProjections =
        linkedMapOf<String, HealthConnectProjection>()
    private val pendingHealthConnectOperations =
        linkedMapOf<String, PendingHealthConnectOperation>()
    private val completedHealthConnectOperations =
        linkedMapOf<String, PendingHealthConnectOperation>()

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
        val previousRecords = LinkedHashMap(this.records)
        return try {
            mergeApplying(records)
        } catch (error: Throwable) {
            this.records.clear()
            this.records.putAll(previousRecords)
            throw error
        }
    }

    private fun mergeApplying(records: List<CanonicalRecord>): MergeResult {
        var result = MergeResult()
        val ordered = recordsInParentWinnerOrder(records) { canonicalId ->
            this.records[canonicalId]?.let {
                CanonicalParentWinner(
                    recordVersion = it.recordVersion,
                    parentCanonicalId = it.parentCanonicalId,
                )
            }
        }
        for (incoming in ordered) {
            val parent =
                incoming.parentCanonicalId?.let(this.records::get)
            if (
                parent?.tombstone == true &&
                !incoming.tombstone &&
                incoming.recordVersion > parent.recordVersion
            ) {
                result += MergeResult(ignored = 1)
                continue
            }
            val effective = if (parent?.tombstone == true) {
                incoming.deferredByParentTombstone(parent.recordVersion)
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
                cascadeTombstone(winningParent)
            } else if (
                winningParent != null &&
                winningParent.kind != "sampleEncodingError"
            ) {
                this.records.replaceAll { _, child ->
                    if (
                        child.parentCanonicalId == winningParent.canonicalId &&
                        child.kind == "sampleEncodingError" &&
                        child.resolutionCanonicalId == null &&
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
        validateCanonicalParentGraph(
            affectedCanonicalIds(
                ordered.map(CanonicalRecord::canonicalId),
            ),
        ) { canonicalId ->
            this.records[canonicalId]?.let {
                CanonicalParentWinner(
                    recordVersion = it.recordVersion,
                    parentCanonicalId = it.parentCanonicalId,
                )
            }
        }
        restoreUnresolvedContinuationErrors()
        reconcileEncodingFailures()
        return result
    }

    private fun affectedCanonicalIds(
        seedCanonicalIds: Iterable<String>,
    ): Set<String> {
        val childrenByParent = linkedMapOf<String, MutableList<String>>()
        for (record in records.values) {
            record.parentCanonicalId?.let { parentId ->
                childrenByParent.getOrPut(parentId, ::mutableListOf) +=
                    record.canonicalId
            }
        }
        val affected = linkedSetOf<String>()
        val pending = ArrayDeque<String>()
        seedCanonicalIds.forEach(pending::addLast)
        while (pending.isNotEmpty()) {
            val canonicalId = pending.removeFirst()
            if (!affected.add(canonicalId)) continue
            childrenByParent[canonicalId].orEmpty().forEach(pending::addLast)
        }
        return affected
    }

    private fun cascadeTombstone(parent: CanonicalRecord) {
        val pending = ArrayDeque<CanonicalRecord>()
        val visited = hashSetOf<String>()
        pending.addLast(parent)
        while (pending.isNotEmpty()) {
            val tombstone = pending.removeFirst()
            if (!visited.add(tombstone.canonicalId)) continue
            val childIds = records.values
                .filter { it.parentCanonicalId == tombstone.canonicalId }
                .map(CanonicalRecord::canonicalId)
            for (childId in childIds) {
                val child = records.getValue(childId)
                if (
                    !child.tombstone &&
                    child.kind != "sampleEncodingError" &&
                    child.recordVersion > tombstone.recordVersion
                ) {
                    continue
                }
                val inherited = if (child.kind == "sampleEncodingError") {
                    child.copy(
                        recordVersion = maxOf(
                            child.recordVersion,
                            tombstone.recordVersion,
                        ),
                        tombstone = true,
                    )
                } else {
                    child.deferredByParentTombstone(tombstone.recordVersion)
                }
                records[childId] = inherited
                pending.addLast(inherited)
            }
        }
    }

    private fun restoreUnresolvedContinuationErrors() {
        records.replaceAll { _, record ->
            val parent = record.parentCanonicalId?.let(records::get)
            val resolver = record.resolutionCanonicalId?.let(records::get)
            val hasValidEnd = resolver != null &&
                resolver.kind ==
                CanonicalRecordParser.seriesEndKind(record.type) &&
                resolver.type == record.type &&
                resolver.parentCanonicalId == record.parentCanonicalId &&
                !resolver.tombstone
            if (
                record.kind == "sampleEncodingError" &&
                record.resolutionCanonicalId != null &&
                record.tombstone &&
                parent?.tombstone != true &&
                !hasValidEnd
            ) {
                record.copy(
                    recordVersion = record.recordVersion + 1,
                    tombstone = false,
                )
            } else {
                record
            }
        }
    }

    private fun reconcileEncodingFailures() {
        records.replaceAll { _, record ->
            val parent = record.parentCanonicalId?.let(records::get)
            val resolution = record.resolutionCanonicalId?.let(records::get)
            val resolver = resolution ?: if (
                record.resolutionCanonicalId == null
            ) {
                parent
            } else {
                null
            }
            val validResolution = resolution != null &&
                resolution.kind ==
                CanonicalRecordParser.seriesEndKind(record.type) &&
                resolution.type == record.type &&
                resolution.parentCanonicalId == record.parentCanonicalId
            if (
                record.kind == "sampleEncodingError" &&
                !record.tombstone &&
                resolver != null &&
                resolver.kind != "sampleEncodingError" &&
                (
                    record.resolutionCanonicalId == null ||
                        validResolution
                ) &&
                !resolver.tombstone
            ) {
                record.copy(
                    recordVersion = maxOf(
                        record.recordVersion + 1,
                        resolver.recordVersion + 1,
                    ),
                    tombstone = true,
                )
            } else {
                record
            }
        }
    }

    override suspend fun timelinePage(
        after: TimelineCursor?,
        limit: Int,
    ): TimelinePage {
        val ordered = records.values
            .asSequence()
            .filterNot(CanonicalRecord::tombstone)
            .filter { record -> isAfter(record, after) }
            .sortedWith(::compareTimelineRecords)
            .take(limit)
            .toList()
        return TimelinePage(
            records = ordered,
            nextCursor = ordered.lastOrNull()?.let {
                TimelineCursor(it.endTime ?: it.startTime, it.canonicalId)
            },
        )
    }

    private fun isAfter(record: CanonicalRecord, cursor: TimelineCursor?): Boolean {
        if (cursor == null) return true
        val time = record.endTime ?: record.startTime
        val cursorTime = cursor.sortTime
        return when {
            cursorTime == null -> time == null && record.canonicalId > cursor.canonicalId
            time == null -> true
            time < cursorTime -> true
            time > cursorTime -> false
            else -> record.canonicalId > cursor.canonicalId
        }
    }

    private fun compareTimelineRecords(
        first: CanonicalRecord,
        second: CanonicalRecord,
    ): Int {
        val firstTime = first.endTime ?: first.startTime
        val secondTime = second.endTime ?: second.startTime
        return when {
            firstTime == null && secondTime == null ->
                first.canonicalId.compareTo(second.canonicalId)
            firstTime == null -> 1
            secondTime == null -> -1
            else -> secondTime.compareTo(firstTime).takeIf { it != 0 }
                ?: first.canonicalId.compareTo(second.canonicalId)
        }
    }

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

    override suspend fun <T> withExportSnapshot(
        block: (CanonicalExportSnapshot) -> T,
    ): T {
        val recordSnapshot = records.values
            .sortedBy(CanonicalRecord::canonicalId)
        val runSnapshot = runRecords.values
            .sortedBy(ArchiveRunRecord::ordinal)
        return block(
            object : CanonicalExportSnapshot {
                override fun recordsPage(
                    afterCanonicalId: String?,
                    limit: Int,
                ): List<CanonicalRecord> = recordSnapshot
                    .asSequence()
                    .filter {
                        afterCanonicalId == null ||
                            it.canonicalId > afterCanonicalId
                    }
                    .take(limit)
                    .toList()

                override fun runRecordsPage(
                    afterSequence: Long?,
                    limit: Int,
                ): List<ArchiveRunRecord> = runSnapshot
                    .asSequence()
                    .filter {
                        afterSequence == null || it.ordinal > afterSequence
                    }
                    .take(limit)
                    .toList()
            },
        )
    }

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

    override suspend fun pendingHealthConnectOperations(
        canonicalIds: Set<String>,
    ): Map<String, PendingHealthConnectOperation> =
        pendingHealthConnectOperations.filterKeys(canonicalIds::contains)

    override suspend fun stageHealthConnectOperations(
        operations: List<PendingHealthConnectOperation>,
    ) {
        for (operation in operations) {
            val completed = completedHealthConnectOperations[operation.canonicalId]
            if (completed == operation) {
                continue
            }
            val committed = healthConnectProjections[operation.canonicalId]
            check(
                committed == null ||
                    (
                        committed.targetRecord == operation.targetRecord &&
                            (
                                operation.canonicalVersion >
                                    committed.canonicalVersion ||
                                    (
                                        operation.action ==
                                            HealthConnectPendingAction.DELETE &&
                                            operation.canonicalVersion ==
                                            committed.canonicalVersion
                                        )
                                )
                        )
            ) {
                "A canonical record cannot change its Health Connect target."
            }
            check(
                completed == null ||
                    (
                        completed.targetRecord == operation.targetRecord &&
                            (
                                operation.canonicalVersion >
                                    completed.canonicalVersion ||
                                    (
                                        completed.action ==
                                            HealthConnectPendingAction.UPSERT &&
                                            operation.action ==
                                            HealthConnectPendingAction.DELETE &&
                                            operation.canonicalVersion ==
                                            completed.canonicalVersion
                                        )
                                )
                    )
            ) {
                "Stale Health Connect work cannot replace completed state."
            }
            val current = pendingHealthConnectOperations[operation.canonicalId]
            check(
                current == null ||
                    current.targetRecord == operation.targetRecord
            ) {
                "A pending Health Connect target cannot be replaced."
            }
            check(
                current == null ||
                    operation.canonicalVersion > current.canonicalVersion ||
                    (
                        operation.canonicalVersion == current.canonicalVersion &&
                            (
                                operation.action == current.action ||
                                    (
                                        current.action == HealthConnectPendingAction.UPSERT &&
                                            operation.action == HealthConnectPendingAction.DELETE
                                        )
                                )
                        )
            ) {
                "Stale Health Connect work cannot replace a pending operation."
            }
            if (
                current == null ||
                operation.canonicalVersion > current.canonicalVersion ||
                operation.action != current.action
            ) {
                pendingHealthConnectOperations[operation.canonicalId] = operation
            }
        }
    }

    override suspend fun completeHealthConnectUpserts(
        projections: List<HealthConnectProjection>,
    ) {
        for (projection in projections) {
            val pending = pendingHealthConnectOperations[projection.canonicalId]
            val currentCompleted =
                completedHealthConnectOperations[projection.canonicalId]
            if (
                pending?.action != HealthConnectPendingAction.UPSERT ||
                pending.canonicalVersion != projection.canonicalVersion ||
                pending.targetRecord != projection.targetRecord ||
                (
                    currentCompleted != null &&
                        currentCompleted.canonicalVersion >=
                        projection.canonicalVersion
                    )
            ) {
                continue
            }
            saveHealthConnectProjections(listOf(projection))
            val completed = PendingHealthConnectOperation(
                canonicalId = projection.canonicalId,
                targetRecord = projection.targetRecord,
                canonicalVersion = projection.canonicalVersion,
                action = HealthConnectPendingAction.UPSERT,
            )
            check(
                currentCompleted == null ||
                    currentCompleted.targetRecord == completed.targetRecord
            )
            completedHealthConnectOperations[projection.canonicalId] = completed
            if (
                pending.action == HealthConnectPendingAction.UPSERT &&
                pending.canonicalVersion == projection.canonicalVersion
            ) {
                pendingHealthConnectOperations.remove(projection.canonicalId)
            }
        }
    }

    override suspend fun completeHealthConnectDeletes(
        operations: List<PendingHealthConnectOperation>,
    ) {
        for (operation in operations) {
            val pending = pendingHealthConnectOperations[operation.canonicalId]
            val completed = completedHealthConnectOperations[operation.canonicalId]
            if (
                pending != operation ||
                (
                    completed != null &&
                        (
                            completed.canonicalVersion >
                                operation.canonicalVersion ||
                                (
                                    completed.canonicalVersion ==
                                        operation.canonicalVersion &&
                                        completed.action !=
                                        HealthConnectPendingAction.UPSERT
                                    )
                            )
                    )
            ) {
                continue
            }
            val projection = healthConnectProjections[operation.canonicalId]
            if (
                projection == null ||
                projection.canonicalVersion <= operation.canonicalVersion
            ) {
                healthConnectProjections.remove(operation.canonicalId)
            }
            completedHealthConnectOperations[operation.canonicalId] = operation
            if (
                pending.action == HealthConnectPendingAction.DELETE &&
                pending.canonicalVersion == operation.canonicalVersion
            ) {
                pendingHealthConnectOperations.remove(operation.canonicalId)
            }
        }
    }

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
