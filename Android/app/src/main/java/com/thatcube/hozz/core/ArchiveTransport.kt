package com.thatcube.hozz.core

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
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
    private val treeUri: Uri,
    cacheDirectory: File,
) : ArchiveSink by NewDocumentTreeArchiveSink(
    directory = SafArchiveDocumentDirectory(contentResolver, treeUri),
    cacheDirectory = cacheDirectory,
)

internal interface ArchiveDocumentDirectory {
    val supportsLocalAtomicPublish: Boolean
    fun contains(displayName: String): Boolean
    fun create(displayName: String, mimeType: String): ArchiveDocument
}

internal interface ArchiveDocument {
    val displayName: String
    val supportsWrite: Boolean
    val supportsRename: Boolean
    val supportsDelete: Boolean

    fun openWrite(): OutputStream
    fun openRead(): InputStream
    fun rename(displayName: String)
    fun delete(): Boolean
}

internal class NewDocumentTreeArchiveSink(
    private val directory: ArchiveDocumentDirectory,
    private val cacheDirectory: File,
    private val nameToken: () -> String = { UUID.randomUUID().toString() },
) : ArchiveSink {
    override suspend fun write(
        export: suspend (OutputStream) -> ArchiveExportResult,
    ): ArchiveExportResult {
        requireLocalProvider()
        val staged = File.createTempFile("hozz-export-", ".zip", cacheDirectory)
        try {
            val result = FileOutputStream(staged).use { output ->
                val exported = export(output)
                output.flush()
                output.fd.sync()
                exported
            }
            return withContext(NonCancellable) {
                publish(staged, result)
            }
        } finally {
            staged.delete()
        }
    }

    private fun publish(
        staged: File,
        result: ArchiveExportResult,
    ): ArchiveExportResult {
        requireLocalProvider()
        val token = nameToken()
        if (!token.matches(Regex("^[A-Za-z0-9-]{1,64}$"))) {
            throw IllegalArgumentException("The archive name token is invalid.")
        }
        val temporaryName = "hozz-$token.partial.zip"
        val finalName = buildString {
            append("hozz-canonical-")
            append(result.archiveId.take(12))
            append("-")
            append(token)
            append(".zip")
        }
        if (directory.contains(temporaryName) || directory.contains(finalName)) {
            throw UnsupportedArchiveProviderException(
                "The selected folder already contains this generated archive name.",
            )
        }

        val document = directory.create(temporaryName, ARCHIVE_MIME_TYPE)
        var published = false
        try {
            if (
                document.displayName != temporaryName ||
                !document.supportsWrite ||
                !document.supportsRename ||
                !document.supportsDelete
            ) {
                throw UnsupportedArchiveProviderException(
                    "This document provider cannot safely publish a new archive.",
                )
            }
            document.openWrite().use { output ->
                FileInputStream(staged).use { it.copyTo(output) }
                output.flush()
            }
            verify(document, staged)

            if (directory.contains(finalName)) {
                throw UnsupportedArchiveProviderException(
                    "The selected folder already contains the final archive name.",
                )
            }
            document.rename(finalName)
            if (document.displayName != finalName) {
                throw UnsupportedArchiveProviderException(
                    "The document provider did not preserve the unique archive name.",
                )
            }
            verify(document, staged)
            published = true
            return result
        } catch (error: Throwable) {
            if (!published) {
                try {
                    if (!document.delete()) {
                        throw IOException(
                            "The document provider refused to delete the temporary archive.",
                        )
                    }
                } catch (cleanup: Throwable) {
                    cleanup.addSuppressed(error)
                    throw ArchiveRecoveryException(
                        "A newly created archive could not be cleaned up; no existing " +
                            "document was replaced.",
                        cleanup,
                    )
                }
            }
            throw error
        }
    }

    private fun verify(document: ArchiveDocument, expected: File) {
        val expectedDigest = FileInputStream(expected).use(::digest)
        val actual = document.openRead().use { input ->
            readBounded(input, expected.length())
        }
        if (
            actual.length != expected.length() ||
            !actual.digest.contentEquals(expectedDigest)
        ) {
            throw ArchiveFormatException(
                "The document provider did not preserve the complete archive.",
            )
        }
    }

    private fun readBounded(
        input: InputStream,
        expectedLength: Long,
    ): BoundedRead {
        if (expectedLength < 0 || expectedLength == Long.MAX_VALUE) {
            throw ArchiveFormatException("The expected archive length is invalid.")
        }
        val limit = expectedLength + 1
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1_024)
        var length = 0L
        while (length < limit) {
            val requested = minOf(buffer.size.toLong(), limit - length).toInt()
            val count = input.read(buffer, 0, requested)
            if (count == -1) break
            if (count == 0) {
                throw IOException("The document provider made no read progress.")
            }
            digest.update(buffer, 0, count)
            length += count
        }
        return BoundedRead(length, digest.digest())
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

    private fun requireLocalProvider() {
        if (!directory.supportsLocalAtomicPublish) {
            throw UnsupportedArchiveProviderException(
                "Archive export requires an On this device or SD card folder.",
            )
        }
    }

    private data class BoundedRead(
        val length: Long,
        val digest: ByteArray,
    )

    private companion object {
        const val ARCHIVE_MIME_TYPE = "application/zip"
    }
}

private class SafArchiveDocumentDirectory(
    private val contentResolver: ContentResolver,
    treeUri: Uri,
) : ArchiveDocumentDirectory {
    override val supportsLocalAtomicPublish =
        isSupportedArchiveTreeAuthority(treeUri.authority)
    private val parentUri = DocumentsContract.buildDocumentUriUsingTree(
        treeUri,
        DocumentsContract.getTreeDocumentId(treeUri),
    )
    private val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
        treeUri,
        DocumentsContract.getTreeDocumentId(treeUri),
    )

    override fun contains(displayName: String): Boolean {
        val cursor = contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        ) ?: throw UnsupportedArchiveProviderException(
            "The selected document provider cannot list the destination folder.",
        )
        cursor.use {
            val nameColumn = it.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            while (it.moveToNext()) {
                if (it.getString(nameColumn) == displayName) return true
            }
        }
        return false
    }

    override fun create(displayName: String, mimeType: String): ArchiveDocument {
        val parent = readMetadata(contentResolver, parentUri)
        if (
            parent.flags and
            DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0
        ) {
            throw UnsupportedArchiveProviderException(
                "The selected document provider cannot create files in this folder.",
            )
        }
        val documentUri = DocumentsContract.createDocument(
            contentResolver,
            parentUri,
            mimeType,
            displayName,
        ) ?: throw UnsupportedArchiveProviderException(
            "The selected document provider did not create the temporary archive.",
        )
        return SafCreatedArchiveDocument(
            contentResolver = contentResolver,
            initialUri = documentUri,
            initialMetadata = readMetadata(contentResolver, documentUri),
        )
    }
}

internal fun isSupportedArchiveTreeAuthority(authority: String?): Boolean =
    authority == "com.android.externalstorage.documents"

private class SafCreatedArchiveDocument(
    private val contentResolver: ContentResolver,
    initialUri: Uri,
    initialMetadata: SafDocumentMetadata,
) : ArchiveDocument {
    private var uri = initialUri
    private var metadata = initialMetadata

    override val displayName: String
        get() = metadata.displayName
    override val supportsWrite: Boolean
        get() = metadata.supports(DocumentsContract.Document.FLAG_SUPPORTS_WRITE)
    override val supportsRename: Boolean
        get() = metadata.supports(DocumentsContract.Document.FLAG_SUPPORTS_RENAME)
    override val supportsDelete: Boolean
        get() = metadata.supports(DocumentsContract.Document.FLAG_SUPPORTS_DELETE)

    override fun openWrite(): OutputStream {
        val descriptor = openLocalDescriptor(
            contentResolver = contentResolver,
            uri = uri,
            mode = "rwt",
        )
        return ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
    }

    override fun openRead(): InputStream {
        val descriptor = openLocalDescriptor(
            contentResolver = contentResolver,
            uri = uri,
            mode = "r",
        )
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    }

    override fun rename(displayName: String) {
        val renamed = DocumentsContract.renameDocument(
            contentResolver,
            uri,
            displayName,
        ) ?: throw UnsupportedArchiveProviderException(
            "The document provider did not publish the verified archive.",
        )
        uri = renamed
        metadata = readMetadata(contentResolver, renamed)
    }

    override fun delete(): Boolean =
        DocumentsContract.deleteDocument(contentResolver, uri)
}

private fun openLocalDescriptor(
    contentResolver: ContentResolver,
    uri: Uri,
    mode: String,
): ParcelFileDescriptor {
    val descriptor = contentResolver.openFileDescriptor(uri, mode)
        ?: throw UnsupportedArchiveProviderException(
            "The local document provider could not open the temporary archive.",
        )
    try {
        if (descriptor.statSize < 0) {
            throw UnsupportedArchiveProviderException(
                "Archive export requires a local, seekable document.",
            )
        }
        Os.lseek(descriptor.fileDescriptor, 0, OsConstants.SEEK_SET)
        return descriptor
    } catch (error: Throwable) {
        descriptor.close()
        if (error is UnsupportedArchiveProviderException) throw error
        throw UnsupportedArchiveProviderException(
            "Archive export requires a local, seekable document.",
        ).apply {
            addSuppressed(error)
        }
    }
}

private data class SafDocumentMetadata(
    val displayName: String,
    val flags: Int,
) {
    fun supports(flag: Int): Boolean = flags and flag != 0
}

private fun readMetadata(
    contentResolver: ContentResolver,
    uri: Uri,
): SafDocumentMetadata {
    val cursor = contentResolver.query(
        uri,
        arrayOf(
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_FLAGS,
        ),
        null,
        null,
        null,
    ) ?: throw UnsupportedArchiveProviderException(
        "The selected document provider cannot describe the archive destination.",
    )
    cursor.use {
        if (!it.moveToFirst()) {
            throw UnsupportedArchiveProviderException(
                "The selected document provider returned no destination metadata.",
            )
        }
        return SafDocumentMetadata(
            displayName = it.getString(
                it.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                ),
            ),
            flags = it.getInt(
                it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS),
            ),
        )
    }
}

internal interface ArchiveDestination {
    fun openProbeInput(): InputStream

    /**
     * The scope must exclude other writers or condition every mutation on the
     * generation it observed. Returning null rejects the provider before a write.
     */
    fun beginGuardedReplacement(): GuardedArchiveReplacement?
}

internal interface GuardedArchiveReplacement : AutoCloseable {
    val originalLength: Long
    val supportsSafeRollback: Boolean
        get() = true

    fun openInput(): InputStream
    fun openTruncateOutput(): OutputStream
    fun commitWrite() = Unit
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
            val replacement = destination.beginGuardedReplacement()
            if (replacement == null) {
                rejectUnsupportedProvider(destination)
            }
            replacement.use { guarded ->
                snapshotOriginal(guarded, backup)
                return withContext(NonCancellable) {
                    try {
                        guarded.openTruncateOutput().use { output ->
                            FileInputStream(staged).use { it.copyTo(output) }
                            output.flush()
                        }
                        guarded.commitWrite()
                        verify(guarded, staged)
                        result
                    } catch (error: Throwable) {
                        if (guarded.supportsSafeRollback) {
                            try {
                                guarded.openTruncateOutput().use { output ->
                                    FileInputStream(backup).use { it.copyTo(output) }
                                    output.flush()
                                }
                                guarded.commitWrite()
                                verify(guarded, backup)
                            } catch (recovery: Throwable) {
                                recovery.addSuppressed(error)
                                throw ArchiveRecoveryException(
                                    "The selected document may be damaged because its prior " +
                                        "contents could not be restored.",
                                    recovery,
                                )
                            }
                            throw error
                        }
                        throw ArchiveRecoveryException(
                            "The new document could not be verified and was not " +
                                "rolled back because another provider may have " +
                                "modified it concurrently.",
                            error,
                        )
                    }
                }
            }
        } finally {
            staged.delete()
            backup.delete()
        }
    }

    private fun rejectUnsupportedProvider(destination: ArchiveDestination): Nothing {
        val hasExistingBytes = destination.openProbeInput().use { it.read() != -1 }
        val message = if (hasExistingBytes) {
            "This document provider cannot safely replace an existing archive."
        } else {
            "This document provider cannot guarantee an exclusive or " +
                "generation-conditional archive write."
        }
        throw UnsupportedArchiveProviderException(message)
    }

    private fun snapshotOriginal(
        replacement: GuardedArchiveReplacement,
        backup: File,
    ) {
        val expectedLength = replacement.originalLength
        val actualLength = FileOutputStream(backup).use { output ->
            val read = replacement.openInput().use { input ->
                readBounded(input, expectedLength, output).length
            }
            output.flush()
            output.fd.sync()
            read
        }
        if (actualLength != expectedLength) {
            throw ArchiveFormatException(
                "The archive changed before its guarded replacement began.",
            )
        }
    }

    private fun verify(destination: GuardedArchiveReplacement, expected: File) {
        val expectedDigest = FileInputStream(expected).use(::digest)
        val actual = destination.openInput().use { input ->
            readBounded(input, expected.length())
        }
        if (
            actual.length != expected.length() ||
            !actual.digest.contentEquals(expectedDigest)
        ) {
            throw ArchiveFormatException(
                "The document provider did not preserve the complete archive.",
            )
        }
    }

    private fun readBounded(
        input: InputStream,
        expectedLength: Long,
        output: OutputStream? = null,
    ): BoundedRead {
        if (expectedLength < 0 || expectedLength == Long.MAX_VALUE) {
            throw ArchiveFormatException(
                "The document provider reported an invalid archive length.",
            )
        }
        val limit = expectedLength + 1
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1_024)
        var length = 0L
        while (length < limit) {
            val requested = minOf(buffer.size.toLong(), limit - length).toInt()
            val count = input.read(buffer, 0, requested)
            if (count == -1) break
            if (count == 0) {
                throw IOException("The document provider made no read progress.")
            }
            output?.write(buffer, 0, count)
            digest.update(buffer, 0, count)
            length += count
        }
        return BoundedRead(length, digest.digest())
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

    private data class BoundedRead(
        val length: Long,
        val digest: ByteArray,
    )
}

class UnsupportedArchiveProviderException(message: String) :
    ArchiveFormatException(message)

class ArchiveRecoveryException(message: String, cause: Throwable) :
    IOException(message, cause)
