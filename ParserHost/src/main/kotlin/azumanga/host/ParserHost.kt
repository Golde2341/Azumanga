package azumanga.host

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import org.koitharu.kotatsu.parsers.MangaLoaderContext
import org.koitharu.kotatsu.parsers.MangaParser
import org.koitharu.kotatsu.parsers.model.ContentRating
import org.koitharu.kotatsu.parsers.model.ContentType
import org.koitharu.kotatsu.parsers.model.Demographic
import org.koitharu.kotatsu.parsers.model.Manga
import org.koitharu.kotatsu.parsers.model.MangaChapter
import org.koitharu.kotatsu.parsers.model.MangaListFilter
import org.koitharu.kotatsu.parsers.model.MangaListFilterOptions
import org.koitharu.kotatsu.parsers.model.MangaPage
import org.koitharu.kotatsu.parsers.model.MangaParserSource
import org.koitharu.kotatsu.parsers.model.MangaState
import org.koitharu.kotatsu.parsers.model.MangaSource
import org.koitharu.kotatsu.parsers.model.MangaTag
import org.koitharu.kotatsu.parsers.model.SortOrder
import org.koitharu.kotatsu.parsers.model.YEAR_UNKNOWN
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Method dispatch for the stdio protocol.
 *
 * Deliberately mirrors the shape of `MangaSource` on the Swift side so the app
 * never has to know a JVM is involved.
 */
class ParserHost(
    cacheDir: File = File(System.getProperty("java.io.tmpdir") ?: "/tmp", "azumanga-parser-host"),
    private val callTimeoutMs: Long = 90_000L,
) {
    companion object {
        const val PROTOCOL_VERSION = 1
    }

    private val parsers = ConcurrentHashMap<String, MangaParser>()
    private val cacheDirectory: File = cacheDir.also { it.mkdirs() }
    private val healthFilter = MangaListFilter(
        query = null,
        states = emptySet(),
        contentRating = emptySet(),
        types = emptySet(),
        demographics = emptySet(),
        yearFrom = YEAR_UNKNOWN,
        yearTo = YEAR_UNKNOWN,
        author = null,
    )

    /**
     * Timeout for the request currently being handled. Requests are serialised on
     * one thread, so a single field is enough — and it matters because a bulk source
     * check wants a much shorter deadline than an interactive read.
     */
    private var requestTimeoutMs: Long = callTimeoutMs

    private val context: MangaLoaderContext = HostLoaderContext(
        parserLookup = { source -> (source as? MangaParserSource)?.let { parser(it) } },
    )

    /// Health probes use their own clients and parsers so a dead source cannot
    /// hold a page or chapter request for the normal 45-second read timeout.
    private val healthParsers = ConcurrentHashMap<String, MangaParser>()
    private val healthContext: MangaLoaderContext = HostLoaderContext(
        callTimeoutSeconds = 8,
        connectTimeoutSeconds = 6,
        readTimeoutSeconds = 8,
        parserLookup = { source ->
            (source as? MangaParserSource)?.let { healthParsers[it.name] }
        },
    )

    fun readyEvent(): String = JSONObject()
        .put("event", "ready")
        .put("protocol", PROTOCOL_VERSION)
        .put("sourceCount", MangaParserSource.entries.size)
        .encode()

    /** Never throws: a failure becomes a structured error so the host survives. */
    fun handle(line: String): String {
        var id = -1
        return try {
            val request = JSONObject(line)
            id = request.optInt("id", -1)
            val method = request.optString("method")
            val params = request.optJSONObject("params") ?: JSONObject()
            // The caller may shorten the deadline (used by the app's bulk source check).
            requestTimeoutMs = request.optLong("timeoutMs", callTimeoutMs).coerceIn(1_000L, 600_000L)
            JSONObject().put("id", id).put("result", dispatch(method, params)).encode()
        } catch (error: Throwable) {
            JSONObject()
                .put("id", id)
                .put(
                    "error",
                    JSONObject()
                        .put("code", errorCode(error))
                        .put("message", error.message ?: error.javaClass.simpleName),
                )
                .encode()
        }
    }

    private fun dispatch(method: String, params: JSONObject): Any = when (method) {
        "ping" -> JSONObject()
            .put("protocol", PROTOCOL_VERSION)
            .put("sourceCount", MangaParserSource.entries.size)

        "sources" -> sources()
        "health" -> health(params)
        "search" -> search(params)
        "list" -> list(params)
        "details" -> details(params)
        "pages" -> pages(params)
        "image" -> image(params)
        "filterOptions" -> filterOptions(params)

        else -> throw IllegalArgumentException("Unknown method: $method")
    }

    // MARK: - Methods

    private fun sources(): JSONObject {
        val items = JSONArray()
        for (source in MangaParserSource.entries) {
            items.put(
                JSONObject()
                    .put("key", source.name)
                    .put("title", source.title)
                    .put("locale", source.locale)
                    .put("contentType", source.contentType.name)
                    .put("broken", source.isBroken),
            )
        }
        return JSONObject().put("items", items)
    }

    /// Checks several sources concurrently. The ordinary request loop is serial, so
    /// a batch endpoint is what keeps "check selected sources" from taking one
    /// timeout per dead site.
    private fun health(params: JSONObject): JSONObject = runBlocking {
        val keysJson = params.optJSONArray("sources") ?: JSONArray()
        val keys = (0 until keysJson.length()).mapNotNull { index ->
            keysJson.optString(index).takeIf { it.isNotEmpty() }
        }
        val perSourceTimeout = params.optLong("timeoutMs", 8_000L)
            .coerceIn(1_000L, 60_000L)
        val gate = Semaphore(24)
        val results = coroutineScope {
            keys.map { key ->
                async(Dispatchers.IO) {
                    gate.withPermit { checkSource(key, perSourceTimeout) }
                }
            }.awaitAll()
        }
        JSONObject().put("items", JSONArray(results))
    }

    private suspend fun checkSource(key: String, timeoutMs: Long): JSONObject = try {
        val source = MangaParserSource.entries.firstOrNull { it.name == key }
            ?: throw IllegalArgumentException("Unknown source: $key")
        val parser = healthParser(source)
        val order = parser.availableSortOrders.firstOrNull() ?: SortOrder.UPDATED
        val mangas = withTimeout(timeoutMs) {
            parser.getList(0, order, healthFilter)
        }
        if (mangas.isEmpty()) {
            JSONObject()
                .put("key", key)
                .put("ok", false)
                .put("detail", "The source returned no results.")
        } else {
            JSONObject()
                .put("key", key)
                .put("ok", true)
                .put("count", mangas.size)
                .put("detail", "${mangas.size} results")
        }
    } catch (error: Throwable) {
        JSONObject()
            .put("key", key)
            .put("ok", false)
            .put("detail", error.message ?: error.javaClass.simpleName)
    }

    /// Search several sources concurrently for the global search screen.
    private fun search(params: JSONObject): JSONObject = runBlocking {
        val keysJson = params.optJSONArray("sources") ?: JSONArray()
        val keys = (0 until keysJson.length()).mapNotNull { index ->
            keysJson.optString(index).takeIf { it.isNotEmpty() }
        }
        val query = params.optString("query").trim()
        if (keys.isEmpty() || query.isEmpty()) {
            return@runBlocking JSONObject().put("items", JSONArray())
        }
        val perSourceTimeout = params.optLong("timeoutMs", 8_000L)
            .coerceIn(1_000L, 60_000L)
        val gate = Semaphore(16)
        val results = coroutineScope {
            keys.map { key ->
                async(Dispatchers.IO) {
                    gate.withPermit { searchSource(key, query, perSourceTimeout) }
                }
            }.awaitAll()
        }
        JSONObject().put("items", JSONArray(results))
    }

    private suspend fun searchSource(key: String, query: String, timeoutMs: Long): JSONObject = try {
        val source = MangaParserSource.entries.firstOrNull { it.name == key }
            ?: throw IllegalArgumentException("Unknown source: $key")
        val parser = healthParser(source)
        val order = parser.availableSortOrders.firstOrNull() ?: SortOrder.UPDATED
        val filter = MangaListFilter(
            query = query,
            states = emptySet(),
            contentRating = emptySet(),
            types = emptySet(),
            demographics = emptySet(),
            yearFrom = YEAR_UNKNOWN,
            yearTo = YEAR_UNKNOWN,
            author = null,
        )
        val mangas = withTimeout(timeoutMs) {
            parser.getList(0, order, filter)
        }
        JSONObject()
            .put("key", key)
            .put("ok", true)
            .put("items", JSONArray(mangas.map { it.toJson() }))
    } catch (error: Throwable) {
        JSONObject()
            .put("key", key)
            .put("ok", false)
            .put("detail", error.message ?: error.javaClass.simpleName)
    }

    private fun list(params: JSONObject): JSONObject {
        val parser = parser(params)
        val offset = params.optInt("offset", 0)
        val order = params.enumOrNull<SortOrder>("sort")
            ?: parser.availableSortOrders.firstOrNull()
            ?: SortOrder.UPDATED

        val filter = MangaListFilter(
            query = params.stringOrNull("query"),
            states = params.enumSet<MangaState>("states"),
            contentRating = params.enumSet<ContentRating>("contentRatings"),
            types = params.enumSet<ContentType>("types"),
            demographics = params.enumSet<Demographic>("demographics"),
            yearFrom = params.intOrNull("yearFrom") ?: YEAR_UNKNOWN,
            yearTo = params.intOrNull("yearTo") ?: YEAR_UNKNOWN,
            author = params.stringOrNull("author"),
        )

        val mangas = call { parser.getList(offset, order, filter) }
        return JSONObject().put("items", JSONArray(mangas.map { it.toJson() }))
    }

    private fun details(params: JSONObject): JSONObject {
        val source = source(params)
        val parser = parser(source)
        val manga = mangaFromJson(params.getJSONObject("manga"), source)
        return call { parser.getDetails(manga) }.toJson(includeChapters = true)
    }

    private fun pages(params: JSONObject): JSONObject {
        val source = source(params)
        val parser = parser(source)
        val chapter = chapterFromJson(params.getJSONObject("chapter"), source)
        val pages = call { parser.getPages(chapter) }

        val items = JSONArray()
        for (page in pages) {
            // getPageUrl is what turns a page reference into a fetchable image, so
            // it has to be resolved here rather than in the app.
            val resolved = call { parser.getPageUrl(page) }
            items.put(
                JSONObject()
                    .put("id", page.id)
                    .put("url", page.url)
                    .put("resolvedUrl", resolved)
                    .put("preview", page.preview),
            )
        }
        return JSONObject().put("items", items)
    }

    /**
     * Fetches page bytes through the parser's own client.
     *
     * The bytes are written to the host's cache directory and the path is
     * returned, rather than embedded in JSON: pages are megabytes, and the app
     * already knows how to read images from file URLs (and cache them).
     */
    private fun image(params: JSONObject): JSONObject = runBlocking {
        withTimeout(requestTimeoutMs) {
            withContext(Dispatchers.IO) {
                val source = source(params)
                val url = params.getString("url")
                val request = Request.Builder()
                    .url(url)
                    .get()
                    .tag(MangaSource::class.java, source)
                    .build()

                context.httpClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) {
                        throw IllegalStateException("Image request failed with HTTP ${response.code}")
                    }
                    val bytes = response.body.bytes()
                    val file = File(cacheDirectory, fileNameFor(url))
                    file.writeBytes(bytes)
                    JSONObject()
                        .put("path", file.absolutePath)
                        .put("bytes", bytes.size)
                        .put("contentType", response.body.contentType()?.toString() ?: JSONObject.NULL)
                }
            }
        }
    }

    private fun fileNameFor(url: String): String {
        val hash = MessageDigest.getInstance("SHA-1")
            .digest(url.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val extension = url.substringBefore('?')
            .substringAfterLast('.', "")
            .take(5)
            .filter { it.isLetterOrDigit() }
        return if (extension.isEmpty()) hash else "$hash.$extension"
    }

    private fun filterOptions(params: JSONObject): JSONObject {
        val parser = parser(params)
        val options: MangaListFilterOptions = call { parser.getFilterOptions() }
        val capabilities = parser.filterCapabilities

        return JSONObject()
            .put("sortOrders", JSONArray(parser.availableSortOrders.map { it.name }))
            .put(
                "capabilities",
                JSONObject()
                    .put("search", capabilities.isSearchSupported)
                    .put("searchWithFilters", capabilities.isSearchWithFiltersSupported)
                    .put("multipleTags", capabilities.isMultipleTagsSupported)
                    .put("tagsExclusion", capabilities.isTagsExclusionSupported)
                    .put("year", capabilities.isYearSupported)
                    .put("yearRange", capabilities.isYearRangeSupported)
                    .put("author", capabilities.isAuthorSearchSupported),
            )
            .put(
                "options",
                JSONObject()
                    .put("tags", JSONArray(options.availableTags.map { it.toJson() }))
                    .put("states", JSONArray(options.availableStates.map { it.name }))
                    .put("contentRatings", JSONArray(options.availableContentRating.map { it.name }))
                    .put("contentTypes", JSONArray(options.availableContentTypes.map { it.name }))
                    .put("demographics", JSONArray(options.availableDemographics.map { it.name })),
            )
    }

    // MARK: - Plumbing

    private fun source(params: JSONObject): MangaParserSource {
        val key = params.optString("key")
        return MangaParserSource.entries.firstOrNull { it.name == key }
            ?: throw IllegalArgumentException("Unknown source: $key")
    }

    private fun parser(params: JSONObject): MangaParser = parser(source(params))

    private fun parser(source: MangaParserSource): MangaParser =
        parsers.computeIfAbsent(source.name) { context.newParserInstance(source) }

    private fun healthParser(source: MangaParserSource): MangaParser =
        healthParsers.computeIfAbsent(source.name) { healthContext.newParserInstance(source) }

    private fun <T> call(block: suspend () -> T): T = runBlocking {
        withTimeout(requestTimeoutMs) { block() }
    }

    private fun errorCode(error: Throwable): String = when (error) {
        is IllegalArgumentException -> "invalid_argument"
        is UnsupportedOperationException -> "unsupported"
        is java.util.concurrent.TimeoutException -> "timeout"
        is kotlinx.coroutines.TimeoutCancellationException -> "timeout"
        else -> "parser_error"
    }

    // MARK: - Mapping

    private fun Manga.toJson(includeChapters: Boolean = false): JSONObject {
        val json = JSONObject()
            .put("id", id)
            .put("title", title)
            .put("altTitles", altTitles.toJsonArray())
            .put("url", url)
            .put("publicUrl", publicUrl)
            .put("rating", rating.toDouble())
            .put("coverUrl", coverUrl ?: JSONObject.NULL)
            .put("largeCoverUrl", largeCoverUrl ?: JSONObject.NULL)
            .put("description", description ?: JSONObject.NULL)
            .put("state", state?.name ?: JSONObject.NULL)
            .put("contentRating", contentRating?.name ?: JSONObject.NULL)
            // The app owns the source metadata (title/locale/contentType), so only
            // the key travels with a manga.
            .put("sourceKey", (source as? MangaParserSource)?.name ?: JSONObject.NULL)
            .put("authors", authors.toJsonArray())
            .put("tags", JSONArray(tags.map { it.toJson() }))

        if (includeChapters) {
            val list = chapters ?: emptyList()
            json.put("chapters", JSONArray(list.map { it.toJson() }))
        }
        return json
    }

    private fun MangaChapter.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title ?: JSONObject.NULL)
        .put("number", number.toDouble())
        .put("volume", volume)
        .put("url", url)
        .put("scanlator", scanlator ?: JSONObject.NULL)
        .put("uploadDate", uploadDate)
        .put("branch", branch ?: JSONObject.NULL)

    private fun MangaTag.toJson(): JSONObject = JSONObject()
        .put("title", title)
        .put("key", key)

    private fun mangaFromJson(json: JSONObject, source: MangaParserSource): Manga {
        val tags = json.optJSONArray("tags")?.let { array ->
            buildSet {
                for (index in 0 until array.length()) {
                    val tag = array.optJSONObject(index) ?: continue
                    add(MangaTag(tag.optString("title"), tag.optString("key"), source))
                }
            }
        } ?: emptySet()

        return Manga(
            id = json.getLong("id"),
            title = json.optString("title"),
            altTitles = json.optJSONArray("altTitles")?.toStringList()?.toSet() ?: emptySet(),
            url = json.optString("url"),
            publicUrl = json.optString("publicUrl", json.optString("url")),
            rating = json.optDouble("rating", 0.0).toFloat(),
            contentRating = json.enumOrNull<ContentRating>("contentRating"),
            coverUrl = json.stringOrNull("coverUrl"),
            tags = tags,
            state = json.enumOrNull<MangaState>("state"),
            authors = json.optJSONArray("authors")?.toStringList()?.toSet() ?: emptySet(),
            largeCoverUrl = json.stringOrNull("largeCoverUrl"),
            description = json.stringOrNull("description"),
            chapters = null,
            source = source,
        )
    }

    private fun chapterFromJson(json: JSONObject, source: MangaParserSource): MangaChapter = MangaChapter(
        id = json.getLong("id"),
        title = json.stringOrNull("title"),
        number = json.optDouble("number", 0.0).toFloat(),
        volume = json.optInt("volume", 0),
        url = json.optString("url"),
        scanlator = json.stringOrNull("scanlator"),
        uploadDate = json.optLong("uploadDate", 0L),
        branch = json.stringOrNull("branch"),
        source = source,
    )
}
