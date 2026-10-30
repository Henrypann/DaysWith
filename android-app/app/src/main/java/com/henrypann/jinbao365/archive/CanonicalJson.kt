package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** UTF-8 byte order, matching the protocol's device id and entity id comparison. */
fun utf8Compare(left: String, right: String): Int {
    val a = left.encodeToByteArray()
    val b = right.encodeToByteArray()
    val length = minOf(a.size, b.size)
    for (index in 0 until length) {
        val compared = (a[index].toInt() and 0xff).compareTo(b[index].toInt() and 0xff)
        if (compared != 0) return compared
    }
    return a.size.compareTo(b.size)
}

val UTF8_ORDER: Comparator<String> = Comparator { left, right -> utf8Compare(left, right) }

/**
 * Sorted object keys, UTF-8, no insignificant whitespace.
 * Numbers and booleans keep the literal stored on the [JsonPrimitive].
 */
fun canonicalJson(element: JsonElement): String = buildString { appendCanonical(element) }

fun jsonEqual(left: JsonElement, right: JsonElement): Boolean = canonicalJson(left) == canonicalJson(right)

private fun StringBuilder.appendCanonical(element: JsonElement) {
    when (element) {
        is JsonNull -> append("null")
        is JsonPrimitive -> {
            if (element.isString) append(jsonString(element.content))
            else append(element.content)
        }
        is JsonArray -> {
            append('[')
            element.forEachIndexed { index, child ->
                if (index > 0) append(',')
                appendCanonical(child)
            }
            append(']')
        }
        is JsonObject -> {
            append('{')
            val keys = element.keys.sortedWith(UTF8_ORDER)
            keys.forEachIndexed { index, key ->
                if (index > 0) append(',')
                append(jsonString(key))
                append(':')
                appendCanonical(element.getValue(key))
            }
            append('}')
        }
    }
}

private fun jsonString(value: String): String {
    val out = StringBuilder(value.length + 2)
    out.append('"')
    value.forEach { character ->
        when (character) {
            '"' -> out.append("\\\"")
            '\\' -> out.append("\\\\")
            '\b' -> out.append("\\b")
            '\u000C' -> out.append("\\f")
            '\n' -> out.append("\\n")
            '\r' -> out.append("\\r")
            '\t' -> out.append("\\t")
            else -> {
                if (character.code < 0x20) out.append("\\u%04x".format(character.code))
                else out.append(character)
            }
        }
    }
    out.append('"')
    return out.toString()
}
