package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ArchiveTransportTest {
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

    private class MemoryDestination(
        initial: ByteArray,
        override val supportsSafeReplacement: Boolean,
        private var failFirstWriteAfter: Int? = null,
    ) : ArchiveDestination {
        var bytes: ByteArray = initial.copyOf()
        var writeCount = 0

        override fun openInput(): InputStream = ByteArrayInputStream(bytes)

        override fun openTruncateOutput(): OutputStream {
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
