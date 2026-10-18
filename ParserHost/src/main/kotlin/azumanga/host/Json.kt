package azumanga.host

import org.json.JSONArray
import org.json.JSONObject

/**
 * Small helpers so mapping code stays readable. The protocol is plain JSON over
 * newline-delimited stdio, so everything here is deliberately dependency-free
 * beyond org.json (which the parsers already bring).
 */

fun JSONObject.stringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val value = optString(key, "")
    return value.ifEmpty { null }
}

fun JSONObject.stringSet(key: String): Set<String> {
    val array = optJSONArray(key) ?: return emptySet()
    return buildSet {
        for (index in 0 until array.length()) {
            array.optString(index).takeIf { it.isNotEmpty() }?.let(::add)
        }
    }
}

fun JSONObject.intOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return optInt(key)
}

inline fun <reified E : Enum<E>> JSONObject.enumSet(key: String): Set<E> {
    val names = stringSet(key)
    if (names.isEmpty()) return emptySet()
    return names.mapNotNull { name -> enumValues<E>().firstOrNull { it.name == name } }.toSet()
}

inline fun <reified E : Enum<E>> JSONObject.enumOrNull(key: String): E? {
    val name = stringOrNull(key) ?: return null
    return enumValues<E>().firstOrNull { it.name == name }
}

fun JSONArray.toStringList(): List<String> = buildList {
    for (index in 0 until length()) {
        optString(index).takeIf { it.isNotEmpty() }?.let(::add)
    }
}

fun Collection<String>.toJsonArray(): JSONArray = JSONArray().also { array ->
    forEach(array::put)
}

/** Compact single-line encoding — the transport is newline-delimited. */
fun JSONObject.encode(): String = toString()
