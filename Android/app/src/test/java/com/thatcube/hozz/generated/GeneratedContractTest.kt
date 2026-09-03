package com.thatcube.hozz.generated

import java.io.InputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GeneratedContractTest {
    @Test
    fun generatedMappingsMatchSharedSchemaResource() {
        val schema = resource("/hozz/v1/health-connect-mappings.json")
        val contractObject = Json.parseToJsonElement(schema).jsonObject
        val sourceIdentifiers = contractObject["recordMappings"]!!
            .jsonArray
            .map {
                it.jsonObject["sourceIdentifier"]!!.jsonPrimitive.content
            }
            .toSet()

        assertEquals(
            contractObject["schemaVersion"]!!.jsonPrimitive.content.toInt(),
            GeneratedContract.SCHEMA_VERSION,
        )
        assertEquals(sourceIdentifiers, GeneratedContract.recordMappings.keys)
        assertTrue(GeneratedContract.archiveOnlyKinds.contains("electrocardiogram"))
        assertTrue(GeneratedContract.archiveOnlyKinds.contains("medicationDose"))
    }

    @Test
    fun canonicalFixtureIsAvailableToKotlin() {
        val lines = resource("/hozz/v1/fixtures/canonical-records.ndjson")
            .lineSequence()
            .filter(String::isNotBlank)
            .toList()

        assertEquals(3, lines.size)
        for (line in lines) {
            val fixtureObject = Json.parseToJsonElement(line).jsonObject
            assertEquals(
                GeneratedContract.SCHEMA_VERSION,
                fixtureObject["schemaVersion"]!!.jsonPrimitive.content.toInt(),
            )
            assertTrue(fixtureObject.containsKey("canonicalId"))
            assertTrue(fixtureObject.containsKey("canonicalType"))
            assertTrue(fixtureObject.containsKey("sourceRecord"))
            assertTrue(fixtureObject.containsKey("lineage"))
        }
    }

    private fun resource(path: String): String = requireNotNull(
        javaClass.getResourceAsStream(path),
    ).use { it.readBytes() }.toString(Charsets.UTF_8)
}
