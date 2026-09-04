package com.thatcube.hozz.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

internal object ArchiveJson {
    const val MAX_NESTING_DEPTH = 64

    fun objectValue(
        json: String,
        subject: String,
        rootError: String,
    ): JsonObject = element(json, subject) as? JsonObject
        ?: throw ArchiveFormatException(rootError)

    fun element(json: String, subject: String): JsonElement {
        enforceNestingDepth(json, subject)
        return try {
            Json.parseToJsonElement(json)
        } catch (error: ArchiveFormatException) {
            throw error
        } catch (_: Exception) {
            throw ArchiveFormatException("$subject is not valid JSON.")
        }
    }

    private fun enforceNestingDepth(json: String, subject: String) {
        var depth = 0
        var inString = false
        var escaped = false
        for (character in json) {
            if (inString) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> inString = false
                }
                continue
            }
            when (character) {
                '"' -> inString = true
                '{', '[' -> {
                    depth += 1
                    if (depth > MAX_NESTING_DEPTH) {
                        throw ArchiveFormatException(
                            "$subject exceeds the maximum nesting depth of " +
                                "$MAX_NESTING_DEPTH.",
                        )
                    }
                }
                '}', ']' -> if (depth > 0) depth -= 1
            }
        }
    }
}
