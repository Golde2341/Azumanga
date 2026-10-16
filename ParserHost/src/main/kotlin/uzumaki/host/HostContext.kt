package uzumaki.host

import org.koitharu.kotatsu.parsers.MangaLoaderContext
import org.koitharu.kotatsu.parsers.MangaParser
import org.koitharu.kotatsu.parsers.bitmap.Bitmap
import org.koitharu.kotatsu.parsers.bitmap.Rect
import org.koitharu.kotatsu.parsers.config.ConfigKey
import org.koitharu.kotatsu.parsers.config.MangaSourceConfig
import org.koitharu.kotatsu.parsers.model.MangaSource
import org.koitharu.kotatsu.parsers.network.UserAgents
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO

/**
 * The host half of the `MangaLoaderContext` contract.
 *
 * This is the whole reason the parsers can run on macOS: none of the parsers
 * touch Android APIs, they only ask the host for an HTTP client, a cookie jar,
 * a JS engine, a bitmap implementation and some config. Everything below is
 * plain JVM.
 */
class HostLoaderContext(
    cookieJar: InMemoryCookieJar = InMemoryCookieJar(),
    private val userAgent: String = UserAgents.FIREFOX_MOBILE,
    private val domainOverrides: Map<String, String> = emptyMap(),
    parserLookup: (MangaSource) -> MangaParser? = { null },
) : MangaLoaderContext() {

    override val cookieJar: InMemoryCookieJar = cookieJar

    override val httpClient: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(this.cookieJar)
        .addInterceptor(CommonHeadersInterceptor(parserLookup))
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    override fun getConfig(source: MangaSource): MangaSourceConfig = HostSourceConfig(domainOverrides)

    override fun getDefaultUserAgent(): String = userAgent

    /**
     * Not implemented on purpose. The parsers that need script execution are
     * excluded from the curated source list, so this throws rather than
     * silently returning null and producing confusing empty results.
     */
    @Deprecated("Provide a base url")
    override suspend fun evaluateJs(script: String): String? = evaluateJs("", script, 10_000L)

    override suspend fun evaluateJs(baseUrl: String, script: String, timeout: Long): String? {
        throw UnsupportedOperationException(
            "This source requires JavaScript evaluation, which the host does not provide yet.",
        )
    }

    override fun createBitmap(width: Int, height: Int): Bitmap =
        AwtBitmap(BufferedImage(maxOf(1, width), maxOf(1, height), BufferedImage.TYPE_INT_ARGB))

    /**
     * Some sources scramble page images; the parsers describe the unscrambling
     * as a bitmap operation and the host applies it to the response body.
     */
    override fun redrawImageResponse(response: Response, redraw: (image: Bitmap) -> Bitmap): Response {
        val decoded = response.body.byteStream().use(ImageIO::read)
            ?: error("Cannot decode image for redraw")
        val redrawn = redraw(AwtBitmap(decoded)) as AwtBitmap
        return response.newBuilder()
            .body(redrawn.toPngBytes().toResponseBody("image/png".toMediaTypeOrNull()))
            .build()
    }
}

/** Minimal cookie store; the host is long-lived so cookies persist per session. */
class InMemoryCookieJar : okhttp3.CookieJar {
    private val cookies = java.util.concurrent.ConcurrentHashMap<String, MutableList<okhttp3.Cookie>>()

    override fun saveFromResponse(url: okhttp3.HttpUrl, cookies: List<okhttp3.Cookie>) {
        if (cookies.isEmpty()) return
        val key = url.host
        this.cookies.computeIfAbsent(key) { mutableListOf() }.apply {
            removeAll { existing -> cookies.any { it.name == existing.name } }
            addAll(cookies)
        }
    }

    override fun loadForRequest(url: okhttp3.HttpUrl): List<okhttp3.Cookie> {
        return cookies[url.host].orEmpty().filter { it.matches(url) }
    }
}

/**
 * Config keys fall back to the parser's own declared defaults, which is also how
 * the upstream test host behaves — parsers already declare their default domain
 * through `configKeyDomain`, so no domain plumbing is needed here.
 */
class HostSourceConfig(private val domainOverrides: Map<String, String>) : MangaSourceConfig {
    override fun <T> get(key: ConfigKey<T>): T {
        if (key is ConfigKey.Domain) {
            val override = domainOverrides[key.key]
            if (override != null) {
                @Suppress("UNCHECKED_CAST")
                return override as T
            }
        }
        return key.defaultValue
    }
}

/**
 * Attaches the headers Kotatsu's own host supplies, then hands the request to the
 * parser for its source.
 *
 * This mirrors `CommonHeadersInterceptor` from the upstream test host, and both
 * halves matter:
 *
 *  * The default `Referer` (`https://<parser.domain>/`) is what most of these
 *    sites require. Without it a plain request is answered with 403 — which is
 *    exactly what happened for image URLs before this existed.
 *  * `MangaParser` is itself an OkHttp `Interceptor`, and parsers use that to add
 *    auth headers, cookies and image descrambling. Fetching outside this path
 *    bypasses all of it.
 */
class CommonHeadersInterceptor(
    private val parserLookup: (MangaSource) -> MangaParser?,
) : okhttp3.Interceptor {

    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response {
        val request = chain.request()
        val source = request.tag(MangaSource::class.java)
        val parser = source?.let(parserLookup)

        val headers = request.headers.newBuilder()
        if (headers[HEADER_REFERER] == null && parser != null) {
            headers[HEADER_REFERER] = "https://${parser.domain}/"
        }
        val newRequest = request.newBuilder().headers(headers.build()).build()

        return if (parser != null) {
            parser.intercept(ProxyChain(chain, newRequest))
        } else {
            chain.proceed(newRequest)
        }
    }

    private class ProxyChain(
        private val delegate: okhttp3.Interceptor.Chain,
        private val request: okhttp3.Request,
    ) : okhttp3.Interceptor.Chain by delegate {
        override fun request(): okhttp3.Request = request
    }

    private companion object {
        const val HEADER_REFERER = "Referer"
    }
}

/** A [Bitmap] backed by an AWT image. */
class AwtBitmap(internal val image: BufferedImage) : Bitmap {

    override val width: Int get() = image.width
    override val height: Int get() = image.height

    override fun drawBitmap(sourceBitmap: Bitmap, src: Rect, dst: Rect) {
        val source = (sourceBitmap as? AwtBitmap)?.image ?: return
        // Parser-supplied rects are clamped: a bad rect must not abort a page.
        val left = src.left.coerceIn(0, maxOf(0, source.width - 1))
        val top = src.top.coerceIn(0, maxOf(0, source.height - 1))
        val width = src.width.coerceIn(1, source.width - left)
        val height = src.height.coerceIn(1, source.height - top)
        val sub = source.getSubimage(left, top, width, height)

        val graphics = image.createGraphics()
        try {
            graphics.drawImage(sub, dst.left, dst.top, dst.width, dst.height, null)
        } finally {
            graphics.dispose()
        }
    }

    fun toPngBytes(): ByteArray {
        val output = ByteArrayOutputStream()
        ImageIO.write(image, "png", output)
        return output.toByteArray()
    }
}
