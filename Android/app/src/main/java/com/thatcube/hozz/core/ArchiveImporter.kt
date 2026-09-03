package com.thatcube.hozz.core

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.PushbackInputStream
import java.util.zip.ZipInputStream

data class ArchiveImportResult(
    val manifest: ArchiveManifest?,
    val legacyArchive: Boolean,
    val recordsRead: Int,
    val runRecordsSkipped: Int,
    val merge: MergeResult,
)

class ArchiveImporter(
    private val store: CanonicalRecordStore,
    private val batchSize: Int = 500,
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
                val stats = importRecords(stream, session)
                ParsedArchive(
                    manifest = null,
                    legacyArchive = true,
                    recordsRead = stats.recordsRead,
                    runRecordsSkipped = stats.runRecordsSkipped,
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
                runRecordsSkipped = parsed.runRecordsSkipped,
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
        val zip = ZipInputStream(input)
        var manifest: ArchiveManifest? = null
        var recordsEntryName: String? = null
        var recordStats: RecordImportStats? = null

        while (true) {
            val entry = zip.nextEntry ?: break
            if (entry.isDirectory) {
                zip.closeEntry()
                continue
            }
            when {
                entry.name == ArchiveManifest.ENTRY_NAME -> {
                    if (manifest != null) {
                        throw ArchiveFormatException(
                            "The archive contains more than one manifest.",
                        )
                    }
                    manifest = ArchiveManifest.parse(
                        readEntry(zip, 256 * 1_024).toString(Charsets.UTF_8),
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
                    recordStats = importRecords(zip, session)
                }
            }
            zip.closeEntry()
        }

        if (manifest != null && recordsEntryName != manifest.recordsEntry) {
            throw ArchiveFormatException(
                "The archive is missing ${manifest.recordsEntry}.",
            )
        }
        val stats = recordStats
            ?: throw ArchiveFormatException("The archive contains no NDJSON records.")
        return ParsedArchive(
            manifest = manifest,
            legacyArchive = manifest == null,
            recordsRead = stats.recordsRead,
            runRecordsSkipped = stats.runRecordsSkipped,
        )
    }

    private suspend fun importRecords(
        input: InputStream,
        session: CanonicalImportSession,
    ): RecordImportStats {
        var recordsRead = 0
        var runRecordsSkipped = 0
        val batch = mutableListOf<CanonicalRecord>()

        readLines(input) { line ->
            if (line.isBlank()) {
                return@readLines
            }
            val record = try {
                CanonicalRecordParser.parse(line)
            } catch (error: Exception) {
                throw ArchiveFormatException(
                    "Record line ${recordsRead + runRecordsSkipped + 1} is invalid: " +
                        (error.message ?: error::class.simpleName),
                )
            }
            if (record == null) {
                runRecordsSkipped += 1
            } else {
                recordsRead += 1
                batch += record
                if (batch.size >= batchSize) {
                    session.append(batch)
                    batch.clear()
                }
            }
        }
        if (batch.isNotEmpty()) {
            session.append(batch)
        }
        return RecordImportStats(recordsRead, runRecordsSkipped)
    }

    private suspend fun readLines(
        input: InputStream,
        consume: suspend (String) -> Unit,
    ) {
        val line = ByteArrayOutputStream()
        while (true) {
            val byte = input.read()
            if (byte == -1) {
                if (line.size() > 0) {
                    consume(line.toString(Charsets.UTF_8.name()))
                }
                return
            }
            if (byte == '\n'.code) {
                consume(line.toString(Charsets.UTF_8.name()))
                line.reset()
                continue
            }
            line.write(byte)
            if (line.size() > MAX_RECORD_BYTES) {
                throw ArchiveFormatException(
                    "A record exceeds the ${MAX_RECORD_BYTES / (1_024 * 1_024)} MiB limit.",
                )
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

    private data class RecordImportStats(
        val recordsRead: Int,
        val runRecordsSkipped: Int,
    )

    private data class ParsedArchive(
        val manifest: ArchiveManifest?,
        val legacyArchive: Boolean,
        val recordsRead: Int,
        val runRecordsSkipped: Int,
    )

    private companion object {
        const val MAX_RECORD_BYTES = 16 * 1_024 * 1_024
    }
}
