package azumanga.host

import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.nio.charset.StandardCharsets

/**
 * Newline-delimited JSON over stdin/stdout. One request per line, one response
 * per line, correlated by `id`.
 *
 * The protocol stream is captured *before* anything else can write to stdout and
 * stdout is then redirected to stderr: parsers (and their libraries) occasionally
 * print, and a stray line would corrupt the stream the app is parsing.
 */
fun main(args: Array<String>) {
    System.setProperty("java.awt.headless", "true")

    val cacheDir = args.firstOrNull { it.startsWith("--cache-dir=") }
        ?.removePrefix("--cache-dir=")
        ?.let(::File)

    val host = if (cacheDir != null) ParserHost(cacheDir = cacheDir) else ParserHost()
    val protocolOut = PrintWriter(
        BufferedWriter(OutputStreamWriter(System.out, StandardCharsets.UTF_8)),
    )
    System.setOut(java.io.PrintStream(System.err, true, StandardCharsets.UTF_8))

    protocolOut.println(host.readyEvent())
    protocolOut.flush()

    val reader = BufferedReader(InputStreamReader(System.`in`, StandardCharsets.UTF_8))
    while (true) {
        val line = reader.readLine() ?: break
        if (line.isBlank()) continue
        protocolOut.println(host.handle(line))
        protocolOut.flush()
    }
    protocolOut.flush()
}
