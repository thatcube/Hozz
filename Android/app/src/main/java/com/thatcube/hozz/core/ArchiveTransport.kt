package com.thatcube.hozz.core

import android.content.ContentResolver
import android.net.Uri
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

fun interface ArchiveTransport {
    fun open(): InputStream
}

class SafArchiveTransport(
    private val contentResolver: ContentResolver,
    private val uri: Uri,
) : ArchiveTransport {
    override fun open(): InputStream =
        contentResolver.openInputStream(uri)
            ?: throw ArchiveFormatException("Android could not open the selected archive.")
}

interface ArchiveSink {
    suspend fun write(
        export: suspend (OutputStream) -> ArchiveExportResult,
    ): ArchiveExportResult
}

class SafArchiveSink(
    private val contentResolver: ContentResolver,
    private val uri: Uri,
    cacheDirectory: File,
) : ArchiveSink by TransactionalArchiveSink(
    destination = object : ArchiveDestination {
        override val supportsSafeReplacement: Boolean = false

        override fun openInput(): InputStream =
            contentResolver.openInputStream(uri)
                ?: throw UnsupportedArchiveProviderException(
                    "The selected document provider cannot verify archive contents.",
                )

        override fun openTruncateOutput(): OutputStream =
            contentResolver.openOutputStream(uri, "rwt")
                ?: throw UnsupportedArchiveProviderException(
                    "The selected document provider cannot truncate archives.",
                )
    },
    cacheDirectory = cacheDirectory,
)

internal interface ArchiveDestination {
    val supportsSafeReplacement: Boolean
    fun openInput(): InputStream
    fun openTruncateOutput(): OutputStream
}

internal class TransactionalArchiveSink(
    private val destination: ArchiveDestination,
    private val cacheDirectory: File,
) : ArchiveSink {
    override suspend fun write(
        export: suspend (OutputStream) -> ArchiveExportResult,
    ): ArchiveExportResult {
        val staged = File.createTempFile("hozz-export-", ".zip", cacheDirectory)
        val backup = File.createTempFile("hozz-backup-", ".zip", cacheDirectory)
        try {
            val result = FileOutputStream(staged).use { output ->
                val exported = export(output)
                output.flush()
                output.fd.sync()
                exported
            }
            FileOutputStream(backup).use { output ->
                destination.openInput().use { input -> input.copyTo(output) }
                output.flush()
                output.fd.sync()
            }
            if (backup.length() > 0 && !destination.supportsSafeReplacement) {
                throw UnsupportedArchiveProviderException(
                    "This document provider cannot safely replace an existing archive. " +
                        "Choose a new file name.",
                )
            }
            return withContext(NonCancellable) {
                try {
                    destination.openTruncateOutput().use { output ->
                        FileInputStream(staged).use { it.copyTo(output) }
                        output.flush()
                    }
                    verify(destination, staged)
                    result
                } catch (error: Throwable) {
                    try {
                        destination.openTruncateOutput().use { output ->
                            FileInputStream(backup).use { it.copyTo(output) }
                            output.flush()
                        }
                        verify(destination, backup)
                    } catch (recovery: Throwable) {
                        throw ArchiveRecoveryException(
                            "The selected document may be damaged because its prior " +
                                "contents could not be restored.",
                            recovery,
                        )
                    }
                    throw error
                }
            }
        } finally {
            staged.delete()
            backup.delete()
        }
    }

    private fun verify(destination: ArchiveDestination, expected: File) {
        val expectedDigest = FileInputStream(expected).use(::digest)
        val actual = destination.openInput().use { input ->
            val bytes = CountingInputStream(input)
            val digest = digest(bytes)
            bytes.count to digest
        }
        if (
            actual.first != expected.length() ||
            !actual.second.contentEquals(expectedDigest)
        ) {
            throw ArchiveFormatException(
                "The document provider did not preserve the complete archive.",
            )
        }
    }

    private fun digest(input: InputStream): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1_024)
        while (true) {
            val count = input.read(buffer)
            if (count == -1) break
            digest.update(buffer, 0, count)
        }
        return digest.digest()
    }
}

class UnsupportedArchiveProviderException(message: String) :
    ArchiveFormatException(message)

class ArchiveRecoveryException(message: String, cause: Throwable) :
    java.io.IOException(message, cause)

private class CountingInputStream(input: InputStream) :
    java.io.FilterInputStream(input) {
    var count: Long = 0
        private set

    override fun read(): Int = super.read().also {
        if (it != -1) count += 1
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        super.read(buffer, offset, length).also {
            if (it > 0) count += it
        }
}
