package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ArchiveTransportTest {
    @Test
    fun proxyTreeIsRejectedBeforeAnyProviderOperation() = runBlocking {
        var providerCalls = 0
        var exportCalled = false
        val proxyDirectory = object : ArchiveDocumentDirectory {
            override val supportsLocalAtomicPublish = false

            override fun contains(displayName: String): Boolean {
                providerCalls += 1
                return false
            }

            override fun create(
                displayName: String,
                mimeType: String,
            ): ArchiveDocument {
                providerCalls += 1
                error("proxy provider must not create a document")
            }
        }
        val cache = Files.createTempDirectory("hozz-tree-sink").toFile()
        try {
            assertThrows(UnsupportedArchiveProviderException::class.java) {
                runBlocking {
                    NewDocumentTreeArchiveSink(
                        directory = proxyDirectory,
                        cacheDirectory = cache,
                        nameToken = { "fixed-token" },
                    ).write {
                        exportCalled = true
                        it.write("new archive".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }

            assertEquals(0, providerCalls)
            assertFalse(exportCalled)
            assertTrue(
                isSupportedArchiveTreeAuthority(
                    "com.android.externalstorage.documents",
                ),
            )
            assertFalse(
                isSupportedArchiveTreeAuthority("com.example.cloud.documents"),
            )
            assertFalse(isSupportedArchiveTreeAuthority(null))
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun treePublishCommitsAndVerifiesTempBeforeUniqueRename() = runBlocking {
        val old = "existing archive".toByteArray()
        val replacement = "new archive".toByteArray()
        val directory = FakeArchiveDocumentDirectory(
            initial = mapOf("existing.zip" to old),
        )
        val cache = Files.createTempDirectory("hozz-tree-sink").toFile()
        try {
            NewDocumentTreeArchiveSink(
                directory = directory,
                cacheDirectory = cache,
                nameToken = { "fixed-token" },
            ).write {
                it.write(replacement)
                ArchiveExportResult("fixture", 1)
            }

            val temporaryName = "hozz-fixed-token.partial.zip"
            val finalName = "hozz-canonical-fixture-fixed-token.zip"
            assertArrayEquals(old, directory.bytes("existing.zip"))
            assertArrayEquals(replacement, directory.bytes(finalName))
            assertFalse(directory.containsFile(temporaryName))
            assertTrue(
                directory.eventIndex("write-close:$temporaryName") <
                    directory.eventIndex("read:$temporaryName"),
            )
            assertTrue(
                directory.eventIndex("read:$temporaryName") <
                    directory.eventIndex("rename:$finalName"),
            )
            assertTrue(
                directory.eventIndex("rename:$finalName") <
                    directory.eventIndex("read:$finalName"),
            )
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun stockLikeZipFilenameCoercionPublishesTemporaryArchive() = runBlocking {
        val replacement = "new archive".toByteArray()
        val directory = FakeArchiveDocumentDirectory(
            appendZipForZipMime = true,
        )
        val cache = Files.createTempDirectory("hozz-tree-sink").toFile()
        try {
            NewDocumentTreeArchiveSink(
                directory = directory,
                cacheDirectory = cache,
                nameToken = { "fixed-token" },
            ).write {
                it.write(replacement)
                ArchiveExportResult("fixture", 1)
            }

            assertArrayEquals(
                replacement,
                directory.bytes("hozz-canonical-fixture-fixed-token.zip"),
            )
            assertTrue(
                "create:hozz-fixed-token.partial.zip" in directory.events,
            )
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun treePublishVerificationMismatchDeletesOnlyNewTemp() = runBlocking {
        val old = "existing archive".toByteArray()
        val directory = FakeArchiveDocumentDirectory(
            initial = mapOf("existing.zip" to old),
            corruptTemporaryRead = true,
        )
        val cache = Files.createTempDirectory("hozz-tree-sink").toFile()
        try {
            assertThrows(ArchiveFormatException::class.java) {
                runBlocking {
                    NewDocumentTreeArchiveSink(
                        directory = directory,
                        cacheDirectory = cache,
                        nameToken = { "fixed-token" },
                    ).write {
                        it.write("new archive".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }

            assertArrayEquals(old, directory.bytes("existing.zip"))
            assertFalse(directory.containsFile("hozz-fixed-token.partial.zip"))
            assertFalse(
                directory.containsFile("hozz-canonical-fixture-fixed-token.zip"),
            )
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun treePublishConcurrentFinalCollisionNeverRenamesOverIt() = runBlocking {
        val collision = "concurrent final".toByteArray()
        val directory = FakeArchiveDocumentDirectory(
            collideOnFinalRecheck = collision,
        )
        val cache = Files.createTempDirectory("hozz-tree-sink").toFile()
        try {
            assertThrows(UnsupportedArchiveProviderException::class.java) {
                runBlocking {
                    NewDocumentTreeArchiveSink(
                        directory = directory,
                        cacheDirectory = cache,
                        nameToken = { "fixed-token" },
                    ).write {
                        it.write("new archive".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }

            assertArrayEquals(
                collision,
                directory.bytes("hozz-canonical-fixture-fixed-token.zip"),
            )
            assertFalse(directory.containsFile("hozz-fixed-token.partial.zip"))
            assertFalse(directory.events.any { it.startsWith("rename:") })
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun exporterFailureLeavesExistingArchiveUntouched() = runBlocking {
        val old = "old archive".toByteArray()
        val destination = MemoryDestination(old, supportsSafeReplacement = true)
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(IOException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write("partial stage".toByteArray())
                        throw IOException("export failed")
                    }
                }
            }
            assertArrayEquals(old, destination.bytes)
            assertEquals(0, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun guardedEmptyDocumentExportSucceedsWithExplicitTruncation() = runBlocking {
        val replacement = "new archive".toByteArray()
        val destination = MemoryDestination(
            initial = ByteArray(0),
            supportsSafeReplacement = true,
        )
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            val result = TransactionalArchiveSink(destination, directory).write {
                it.write(replacement)
                ArchiveExportResult("fixture", 1)
            }

            assertEquals(ArchiveExportResult("fixture", 1), result)
            assertArrayEquals(replacement, destination.bytes)
            assertEquals(1, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedNewDocumentWriteNeverRestoresEmptyBackupOverConcurrentBytes() = runBlocking {
        val concurrent = "noncooperating provider bytes".toByteArray()
        val destination = ConcurrentGuardedNewDocumentDestination(concurrent)
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(ArchiveRecoveryException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write("new archive".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertArrayEquals(concurrent, destination.bytes)
            assertEquals(1, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun verificationReadsOnlyProviderCommittedBytes() = runBlocking {
        val replacement = "new archive".toByteArray()
        val destination = CommitRequiredDestination()
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            TransactionalArchiveSink(destination, directory).write {
                it.write(replacement)
                ArchiveExportResult("fixture", 1)
            }

            assertTrue(destination.committed)
            assertArrayEquals(replacement, destination.committedBytes)
            assertEquals(2, destination.inputOpenCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun unsupportedProviderNeverOverwritesExistingArchive() = runBlocking {
        val old = "old archive".toByteArray()
        val destination = MemoryDestination(old, supportsSafeReplacement = false)
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(UnsupportedArchiveProviderException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write("new".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertArrayEquals(old, destination.bytes)
            assertEquals(0, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun unsupportedProviderCannotRaceAnEmptyProbeWithAConcurrentWrite() = runBlocking {
        val concurrent = "provider wrote concurrently".toByteArray()
        val destination = ConcurrentWriteDestination(concurrent)
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(UnsupportedArchiveProviderException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write("new".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertArrayEquals(concurrent, destination.bytes)
            assertEquals(0, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun unsupportedProviderReadsOnlyOneByteBeforeRejectingHugeDocument() = runBlocking {
        val destination = HugeUnsupportedDestination()
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(UnsupportedArchiveProviderException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write("new".toByteArray())
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertEquals(1, destination.readCount)
            assertEquals(0, destination.writeCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun verificationReadsAtMostExpectedLengthPlusOne() = runBlocking {
        val old = "old archive".toByteArray()
        val replacement = "new".toByteArray()
        val destination = OversizedVerificationDestination(old, replacement)
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(ArchiveFormatException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write(replacement)
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertArrayEquals(old, destination.bytes)
            assertEquals(replacement.size + 1, destination.verificationReadCount)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedReplacementRestoresPriorBytesAndSuccessTruncates() = runBlocking {
        val old = "old archive with a long tail".toByteArray()
        val replacement = "new".toByteArray()
        val destination = MemoryDestination(
            old,
            supportsSafeReplacement = true,
            failFirstWriteAfter = 2,
        )
        val directory = Files.createTempDirectory("hozz-sink").toFile()
        try {
            assertThrows(IOException::class.java) {
                runBlocking {
                    TransactionalArchiveSink(destination, directory).write {
                        it.write(replacement)
                        ArchiveExportResult("fixture", 1)
                    }
                }
            }
            assertArrayEquals(old, destination.bytes)

            TransactionalArchiveSink(destination, directory).write {
                it.write(replacement)
                ArchiveExportResult("fixture", 1)
            }
            assertArrayEquals(replacement, destination.bytes)
        } finally {
            directory.deleteRecursively()
        }
    }

    private class FakeArchiveDocumentDirectory(
        initial: Map<String, ByteArray> = emptyMap(),
        private val corruptTemporaryRead: Boolean = false,
        private val collideOnFinalRecheck: ByteArray? = null,
        private val appendZipForZipMime: Boolean = false,
    ) : ArchiveDocumentDirectory {
        override val supportsLocalAtomicPublish = true
        private val files = initial
            .mapValuesTo(mutableMapOf()) { it.value.copyOf() }
        val events = mutableListOf<String>()
        private var finalNameChecks = 0

        override fun contains(displayName: String): Boolean {
            events += "contains:$displayName"
            if (displayName.endsWith(".zip") && collideOnFinalRecheck != null) {
                finalNameChecks += 1
                if (finalNameChecks == 2) {
                    files[displayName] = collideOnFinalRecheck.copyOf()
                }
            }
            return displayName in files
        }

        override fun create(displayName: String, mimeType: String): ArchiveDocument {
            check(mimeType == "application/zip")
            val actualName = if (
                appendZipForZipMime && !displayName.endsWith(".zip")
            ) {
                "$displayName.zip"
            } else {
                displayName
            }
            check(actualName !in files)
            events += "create:$actualName"
            files[actualName] = ByteArray(0)
            return object : ArchiveDocument {
                override var displayName = actualName
                    private set
                override val supportsWrite = true
                override val supportsRename = true
                override val supportsDelete = true

                override fun openWrite(): OutputStream {
                    val nameAtOpen = this.displayName
                    events += "write-open:$nameAtOpen"
                    return object : ByteArrayOutputStream() {
                        override fun close() {
                            super.close()
                            files[nameAtOpen] = toByteArray()
                            events += "write-close:$nameAtOpen"
                        }
                    }
                }

                override fun openRead(): InputStream {
                    events += "read:${this.displayName}"
                    val stored = files.getValue(this.displayName)
                    val bytes = if (
                        corruptTemporaryRead &&
                        this.displayName.endsWith(".partial.zip")
                    ) {
                        stored + "concurrent provider bytes".toByteArray()
                    } else {
                        stored
                    }
                    return ByteArrayInputStream(bytes)
                }

                override fun rename(displayName: String) {
                    check(displayName !in files) {
                        "rename attempted to overwrite an existing document"
                    }
                    events += "rename:$displayName"
                    val bytes = files.remove(this.displayName)
                        ?: error("temporary document disappeared")
                    files[displayName] = bytes
                    this.displayName = displayName
                }

                override fun delete(): Boolean {
                    events += "delete:${this.displayName}"
                    return files.remove(this.displayName) != null
                }
            }
        }

        fun bytes(displayName: String): ByteArray =
            files.getValue(displayName).copyOf()

        fun containsFile(displayName: String): Boolean = displayName in files

        fun eventIndex(event: String): Int =
            events.indexOf(event).also { check(it >= 0) { "Missing event $event" } }
    }

    private class ConcurrentWriteDestination(
        private val concurrent: ByteArray,
    ) : ArchiveDestination {
        var bytes = ByteArray(0)
        var writeCount = 0
        private var readCount = 0

        override fun openProbeInput(): InputStream {
            readCount += 1
            val snapshot = bytes.copyOf()
            return object : ByteArrayInputStream(snapshot) {
                override fun close() {
                    super.close()
                    if (readCount == 1) {
                        bytes = concurrent.copyOf()
                    }
                }
            }
        }

        override fun beginGuardedReplacement(): GuardedArchiveReplacement? = null
    }

    private class ConcurrentGuardedNewDocumentDestination(
        private val concurrent: ByteArray,
    ) : ArchiveDestination {
        var bytes = ByteArray(0)
        var writeCount = 0

        override fun openProbeInput(): InputStream = ByteArrayInputStream(bytes)

        override fun beginGuardedReplacement(): GuardedArchiveReplacement =
            object : GuardedArchiveReplacement {
                override val originalLength = 0L
                override val supportsSafeRollback = false

                override fun openInput(): InputStream = ByteArrayInputStream(bytes)

                override fun openTruncateOutput(): OutputStream {
                    writeCount += 1
                    bytes = ByteArray(0)
                    return object : OutputStream() {
                        override fun write(value: Int) {
                            bytes = concurrent.copyOf()
                            throw IOException("provider write failed after concurrent mutation")
                        }
                    }
                }

                override fun close() = Unit
            }
    }

    private class CommitRequiredDestination : ArchiveDestination {
        var committed = false
        var committedBytes = ByteArray(0)
        var inputOpenCount = 0
        private var pendingBytes = ByteArray(0)

        override fun openProbeInput(): InputStream = ByteArrayInputStream(committedBytes)

        override fun beginGuardedReplacement(): GuardedArchiveReplacement =
            object : GuardedArchiveReplacement {
                override val originalLength = 0L

                override fun openInput(): InputStream {
                    inputOpenCount += 1
                    check(inputOpenCount == 1 || committed) {
                        "verification opened before the provider committed its write"
                    }
                    return ByteArrayInputStream(committedBytes)
                }

                override fun openTruncateOutput(): OutputStream {
                    pendingBytes = ByteArray(0)
                    return object : OutputStream() {
                        override fun write(value: Int) {
                            pendingBytes += value.toByte()
                        }
                    }
                }

                override fun commitWrite() {
                    committedBytes = pendingBytes.copyOf()
                    committed = true
                }

                override fun close() = Unit
            }
    }

    private class HugeUnsupportedDestination : ArchiveDestination {
        var readCount = 0
        var writeCount = 0

        override fun openProbeInput(): InputStream = object : InputStream() {
            override fun read(): Int {
                readCount += 1
                if (readCount > 1) {
                    throw IOException("read beyond the one-byte rejection probe")
                }
                return 'x'.code
            }
        }

        override fun beginGuardedReplacement(): GuardedArchiveReplacement? = null
    }

    private class OversizedVerificationDestination(
        initial: ByteArray,
        private val replacement: ByteArray,
    ) : ArchiveDestination {
        var bytes = initial.copyOf()
        var verificationReadCount = 0
        private var writeCount = 0

        override fun openProbeInput(): InputStream = ByteArrayInputStream(bytes)

        override fun beginGuardedReplacement(): GuardedArchiveReplacement =
            object : GuardedArchiveReplacement {
                override val originalLength = bytes.size.toLong()

                override fun openInput(): InputStream {
                    if (writeCount != 1) {
                        return ByteArrayInputStream(bytes)
                    }
                    var index = 0
                    return object : InputStream() {
                        override fun read(): Int {
                            verificationReadCount += 1
                            if (verificationReadCount > replacement.size + 1) {
                                throw AssertionError(
                                    "verification read beyond expected length + 1",
                                )
                            }
                            val value = if (index < replacement.size) {
                                replacement[index].toInt() and 0xFF
                            } else {
                                'x'.code
                            }
                            index += 1
                            return value
                        }
                    }
                }

                override fun openTruncateOutput(): OutputStream {
                    writeCount += 1
                    bytes = ByteArray(0)
                    return object : OutputStream() {
                        override fun write(value: Int) {
                            bytes += value.toByte()
                        }
                    }
                }

                override fun close() = Unit
            }
    }

    private class MemoryDestination(
        initial: ByteArray,
        private val supportsSafeReplacement: Boolean,
        private var failFirstWriteAfter: Int? = null,
    ) : ArchiveDestination {
        var bytes: ByteArray = initial.copyOf()
        var writeCount = 0

        override fun openProbeInput(): InputStream = ByteArrayInputStream(bytes)

        override fun beginGuardedReplacement(): GuardedArchiveReplacement? {
            if (!supportsSafeReplacement) return null
            return object : GuardedArchiveReplacement {
                override val originalLength = bytes.size.toLong()

                override fun openInput(): InputStream = ByteArrayInputStream(bytes)

                override fun openTruncateOutput(): OutputStream =
                    this@MemoryDestination.openTruncateOutput()

                override fun close() = Unit
            }
        }

        private fun openTruncateOutput(): OutputStream {
            writeCount += 1
            bytes = ByteArray(0)
            val failurePoint = failFirstWriteAfter.also {
                failFirstWriteAfter = null
            }
            return object : OutputStream() {
                override fun write(value: Int) {
                    if (failurePoint != null && bytes.size >= failurePoint) {
                        throw IOException("provider write failed")
                    }
                    bytes += value.toByte()
                }

                override fun write(buffer: ByteArray, offset: Int, length: Int) {
                    for (index in offset until offset + length) {
                        write(buffer[index].toInt())
                    }
                }
            }
        }
    }
}
