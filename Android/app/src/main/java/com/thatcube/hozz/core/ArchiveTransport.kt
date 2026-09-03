package com.thatcube.hozz.core

import android.content.ContentResolver
import android.net.Uri
import java.io.InputStream
import java.io.OutputStream

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

fun interface ArchiveSink {
    fun open(): OutputStream
}

class SafArchiveSink(
    private val contentResolver: ContentResolver,
    private val uri: Uri,
) : ArchiveSink {
    override fun open(): OutputStream =
        contentResolver.openOutputStream(uri, "w")
            ?: throw ArchiveFormatException("Android could not create the Hozz archive.")
}
