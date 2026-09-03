package com.thatcube.hozz.core

import java.io.ByteArrayOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.io.PushbackInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

data class ArchiveImportResult(
    val manifest: ArchiveManifest?,
    val legacyArchive: Boolean,
    val recordsRead: Int,
    val runRecordsPreserved: Int,
    val merge: MergeResult,
)

data class ArchiveImportLimits(
    val maxZipEntries: Long = 1_024,
    val maxInflatedBytes: Long = 64L * 1_024 * 1_024 * 1_024,
    val maxRecordLines: Long = 50_000_000,
    val maxRecordBytes: Int = 16 * 1_024 * 1_024,
    val maxManifestBytes: Int = 256 * 1_024,
    val maxEntryCompressionRatio: Long = 200,
    val maxGlobalCompressionRatio: Long = 100,
    val entryRatioSlackBytes: Long = 8L * 1_024 * 1_024,
    val globalRatioSlackBytes: Long = 32L * 1_024 * 1_024,
)

class ArchiveImporter(
    private val store: CanonicalRecordStore,
    private val batchSize: Int = 500,
    private val limits: ArchiveImportLimits = ArchiveImportLimits(),
) {
    suspend fun import(input: InputStream): ArchiveImportResult {
        val session = store.beginImport()
        try {
            val stream = PushbackInputStream(input.buffered(), 4)
            val header = ByteArray(4)
            var count = 0
            while (count < 2) {
                val read = stream.read(header, count, header.size - count)
                if (read == -1) {
                    break
                }
                count += read
            }
            if (count > 0) {
                stream.unread(header, 0, count)
            }
            val parsed = if (
                count >= 2 &&
                header[0] == 0x50.toByte() &&
                header[1] == 0x4B.toByte()
            ) {
                importZip(stream, session)
            } else {
                val bounded = BoundedInputStream(stream, limits.maxInflatedBytes)
                val stats = importRecords(
                    bounded,
                    session,
                    strictV1 = false,
                    collectStrictFailure = false,
                )
                ParsedArchive(
                    manifest = null,
                    legacyArchive = true,
                    recordsRead = stats.recordsRead,
                    runRecordsPreserved = stats.runRecordsPreserved,
                )
            }
            if (
                parsed.manifest?.recordCount != null &&
                parsed.manifest.recordCount != parsed.recordsRead.toLong()
            ) {
                throw ArchiveFormatException(
                    "The archive declares ${parsed.manifest.recordCount} records " +
                        "but contains ${parsed.recordsRead}.",
                )
            }
            return ArchiveImportResult(
                manifest = parsed.manifest,
                legacyArchive = parsed.legacyArchive,
                recordsRead = parsed.recordsRead,
                runRecordsPreserved = parsed.runRecordsPreserved,
                merge = session.commit(),
            )
        } catch (error: Throwable) {
            session.discard()
            throw error
        }
    }

    private suspend fun importZip(
        input: InputStream,
        session: CanonicalImportSession,
    ): ParsedArchive {
        val zip = GuardedZipInputStream(input, limits)
        var manifest: ArchiveManifest? = null
        var recordsEntryName: String? = null
        var recordStats: RecordImportStats? = null
        var entryCount = 0L

        while (true) {
            val entry = zip.nextGuardedEntry() ?: break
            entryCount += 1
            if (entryCount > limits.maxZipEntries) {
                throw ArchiveFormatException(
                    "The archive contains more than ${limits.maxZipEntries} entries.",
                )
            }
            when {
                entry.isDirectory -> zip.drainEntry()
                entry.name == ArchiveManifest.ENTRY_NAME -> {
                    if (manifest != null) {
                        throw ArchiveFormatException(
                            "The archive contains more than one manifest.",
                        )
                    }
                    manifest = ArchiveManifest.parse(
                        decodeUtf8(
                            readEntry(zip, limits.maxManifestBytes),
                            "archive manifest",
                        ),
                    )
                }
                entry.name.endsWith(".ndjson") -> {
                    if (recordsEntryName != null) {
                        throw ArchiveFormatException(
                            "The archive contains more than one NDJSON record stream.",
                        )
                    }
                    if (manifest != null && manifest.recordsEntry != entry.name) {
                        throw ArchiveFormatException(
                            "The archive contains an undeclared NDJSON record stream.",
                        )
                    }
                    recordsEntryName = entry.name
                    recordStats = importRecords(
                        zip,
                        session,
                        strictV1 = manifest != null,
                        collectStrictFailure = manifest == null,
                    )
                }
                else -> zip.drainEntry()
            }
            zip.finishEntry()
        }

        if (manifest != null && recordsEntryName != manifest.recordsEntry) {
            throw ArchiveFormatException(
                "The archive is missing ${manifest.recordsEntry}.",
            )
        }
        val stats = recordStats
            ?: throw ArchiveFormatException("The archive contains no NDJSON records.")
        if (manifest != null) {
            stats.strictFailure?.let { throw it }
        }
        return ParsedArchive(
            manifest = manifest,
            legacyArchive = manifest == null,
            recordsRead = stats.recordsRead,
            runRecordsPreserved = stats.runRecordsPreserved,
        )
    }

    private suspend fun importRecords(
        input: InputStream,
        session: CanonicalImportSession,
        strictV1: Boolean,
        collectStrictFailure: Boolean,
    ): RecordImportStats {
        var recordsRead = 0
        var runRecordsPreserved = 0
        var nonblankLines = 0L
        var firstStrictFailure: ArchiveFormatException? = null
        var currentRun: String? = null
        val occurrences = mutableMapOf<String, Int>()
        val batch = mutableListOf<CanonicalRecord>()
        val runBatch = mutableListOf<ArchiveRunRecord>()

        readLines(input) { line ->
            if (line.isBlank()) {
                return@readLines
            }
            val rawLine = line.removeSuffix("\r")
            nonblankLines += 1
            if (nonblankLines > limits.maxRecordLines) {
                throw ArchiveFormatException(
                    "The archive contains more than ${limits.maxRecordLines} records.",
                )
            }
            if (collectStrictFailure && firstStrictFailure == null) {
                try {
                    CanonicalRecordParser.validateStrict(rawLine)
                } catch (error: ArchiveFormatException) {
                    firstStrictFailure = error
                }
            }
            val kind = try {
                CanonicalRecordParser.kind(rawLine)
            } catch (error: Exception) {
                throw ArchiveFormatException(
                    "Record line $nonblankLines is invalid: " +
                        (error.message ?: error::class.simpleName),
                )
            }
            if (CanonicalRecordParser.isRunKind(kind)) {
                val storedLine = if (strictV1) {
                    CanonicalRecordParser.validateStrict(rawLine)
                    rawLine
                } else {
                    CanonicalRecordParser.normalizedRunLine(rawLine)
                }
                CanonicalRecordParser.runIdentifier(storedLine)?.let {
                    currentRun = it
                }
                val fingerprint = hash(
                    "${currentRun ?: "unscoped"}\u0000$storedLine",
                )
                val occurrence = occurrences[fingerprint] ?: 0
                occurrences[fingerprint] = occurrence + 1
                runBatch += ArchiveRunRecord(
                    kind = kind,
                    rawJson = storedLine,
                    fingerprint = fingerprint,
                    occurrence = occurrence,
                    ordinal = nonblankLines,
                )
                runRecordsPreserved += 1
                if (runBatch.size >= batchSize) {
                    session.appendRunRecords(runBatch)
                    runBatch.clear()
                }
                return@readLines
            }
            val record = try {
                CanonicalRecordParser.parse(rawLine, strictV1 = strictV1)
            } catch (error: Exception) {
                throw ArchiveFormatException(
                    "Record line $nonblankLines is invalid: " +
                        (error.message ?: error::class.simpleName),
                )
            }
            checkNotNull(record)
            recordsRead += 1
            batch += record
            if (batch.size >= batchSize) {
                session.append(batch)
                batch.clear()
            }
        }
        if (batch.isNotEmpty()) {
            session.append(batch)
        }
        if (runBatch.isNotEmpty()) {
            session.appendRunRecords(runBatch)
        }
        return RecordImportStats(
            recordsRead = recordsRead,
            runRecordsPreserved = runRecordsPreserved,
            strictFailure = firstStrictFailure,
        )
    }

    private suspend fun readLines(
        input: InputStream,
        consume: suspend (String) -> Unit,
    ) {
        val line = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1_024)
        while (true) {
            val count = input.read(buffer)
            if (count == -1) {
                if (line.size() > 0) {
                    consume(decodeUtf8(line.toByteArray(), "record line"))
                }
                return
            }
            for (index in 0 until count) {
                val byte = buffer[index]
                if (byte == '\n'.code.toByte()) {
                    consume(decodeUtf8(line.toByteArray(), "record line"))
                    line.reset()
                } else {
                    line.write(byte.toInt())
                    if (line.size() > limits.maxRecordBytes) {
                        throw ArchiveFormatException(
                            "A record exceeds the " +
                                "${limits.maxRecordBytes / (1_024 * 1_024)} MiB limit.",
                        )
                    }
                }
            }
        }
    }

    private fun readEntry(input: InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1_024)
        while (true) {
            val count = input.read(buffer)
            if (count == -1) {
                break
            }
            if (output.size() + count > limit) {
                throw ArchiveFormatException("The archive manifest is too large.")
            }
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray())
            .joinToString("") { "%02x".format(it) }

    private fun decodeUtf8(bytes: ByteArray, field: String): String =
        try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (error: Exception) {
            throw ArchiveFormatException("$field is not valid UTF-8.")
        }

    private data class RecordImportStats(
        val recordsRead: Int,
        val runRecordsPreserved: Int,
        val strictFailure: ArchiveFormatException?,
    )

    private data class ParsedArchive(
        val manifest: ArchiveManifest?,
        val legacyArchive: Boolean,
        val recordsRead: Int,
        val runRecordsPreserved: Int,
    )

    private class BoundedInputStream(
        input: InputStream,
        private val maximum: Long,
    ) : FilterInputStream(input) {
        private var total = 0L

        override fun read(): Int {
            val value = super.read()
            if (value != -1) {
                add(1)
            }
            return value
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val count = super.read(buffer, offset, length)
            if (count > 0) {
                add(count)
            }
            return count
        }

        private fun add(count: Int) {
            total += count
            if (total > maximum) {
                throw ArchiveFormatException(
                    "The archive expands beyond the $maximum byte limit.",
                )
            }
        }
    }

    private class GuardedZipInputStream(
        input: InputStream,
        private val limits: ArchiveImportLimits,
    ) : ZipInputStream(input) {
        private var currentEntry: ZipEntry? = null
        private var entryInflated = 0L
        private var completedInflated = 0L
        private var completedCompressed = 0L

        fun nextGuardedEntry(): ZipEntry? {
            currentEntry = nextEntry
            entryInflated = 0
            return currentEntry
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            val count = super.read(buffer, offset, length)
            if (count > 0) {
                entryInflated += count
                enforce()
            }
            return count
        }

        override fun read(): Int {
            val value = super.read()
            if (value != -1) {
                entryInflated += 1
                enforce()
            }
            return value
        }

        fun drainEntry() {
            val buffer = ByteArray(64 * 1_024)
            while (read(buffer) != -1) {
                // Every ignored byte is still metered.
            }
        }

        fun finishEntry() {
            val compressed = currentCompressedBytes()
            enforce()
            completedInflated += entryInflated
            completedCompressed += compressed
            closeEntry()
            currentEntry = null
            entryInflated = 0
            enforce()
        }

        private fun currentCompressedBytes(): Long =
            if (currentEntry == null) {
                0
            } else if (currentEntry?.method == ZipEntry.STORED) {
                entryInflated
            } else {
                inf.bytesRead
            }

        private fun enforce() {
            val entryCompressed = currentCompressedBytes()
            if (
                entryInflated >
                limits.entryRatioSlackBytes +
                entryCompressed * limits.maxEntryCompressionRatio
            ) {
                throw ArchiveFormatException(
                    "A ZIP entry exceeds the compression-ratio limit.",
                )
            }
            val globalInflated = completedInflated + entryInflated
            if (globalInflated > limits.maxInflatedBytes) {
                throw ArchiveFormatException(
                    "The archive expands beyond the " +
                        "${limits.maxInflatedBytes} byte limit.",
                )
            }
            val globalCompressed = completedCompressed + entryCompressed
            if (
                globalInflated >
                limits.globalRatioSlackBytes +
                globalCompressed * limits.maxGlobalCompressionRatio
            ) {
                throw ArchiveFormatException(
                    "The archive exceeds the global compression-ratio limit.",
                )
            }
        }
    }
}
