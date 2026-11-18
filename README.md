# Azumanga

A native macOS manga reader built with SwiftUI, SwiftData and a bundled Kotatsu
parser host.

Azumanga is a **client only**. It does not host, mirror, upload or distribute
manga. It connects to third-party providers and displays content made available
by those services.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 5](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Kotlin/JVM 17](https://img.shields.io/badge/Kotlin%2FJVM-17-7F52FF?logo=kotlin)

---

## Features

- Native **MangaDex** provider.
- Bundled **Kotatsu parser host** with support for community-maintained sources.
- Library, reading history, bookmarks and per-page progress.
- Continuous vertical (webtoon) and horizontal (classic) reading modes.
- Per-manga view settings, presets and reader backgrounds.
- Zooming, page scrubbing and chapter navigation.
- Chapter download queue with pause, resume and retry.
- Global search across enabled and pinned sources.
- Source health checks, search, pinning and bulk enable/disable.
- First-run source-language and content-type setup.

---

## Requirements

| Requirement | Version |
| --- | --- |
| macOS | 14 (Sonoma) or later |
| Xcode | 26 or later, for Swift 6.2 and a current macOS SDK |
| Swift | 5 |
| JDK | 17, for building and running the Kotatsu parser host |
| Gradle | Not required separately; use `ParserHost/gradlew` |

The parser host is optional at runtime. If the host jar is missing, the app still
launches and the native MangaDex/installed JavaScript providers remain available;
Kotatsu sources are simply unavailable.

---

## Building

### 1. Build the app

Open `Azumanga.xcodeproj` in Xcode and run the `Azumanga` scheme, or use:

```sh
xcodebuild \
  -project Azumanga.xcodeproj \
  -scheme Azumanga \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

### 2. Build the Kotatsu parser host

The parser host is a separate JVM process that runs the
[Kotatsu parser library](https://github.com/Kotatsu-Redo/kotatsu-parsers-redo) and
talks to the app over newline-delimited JSON.

A JDK 17 installation is required. Full host instructions, runtime trimming and
signing notes live in [`ParserHost/README.md`](ParserHost/README.md).

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
cd ParserHost
./gradlew fatJar
```

The resulting jar is copied into the app by the `Bundle parser host` build phase:

```text
ParserHost/build/libs/azumanga-parser-host-all.jar
```

If the jar is missing, Xcode prints a warning and the app runs without Kotatsu
sources.

### 3. Run tests

```sh
xcodebuild test \
  -project Azumanga.xcodeproj \
  -scheme Azumanga \
  -destination 'platform=macOS'
```

Some live provider tests are opt-in and require `AZUMANGA_LIVE_TESTS=1`.

---

## Project layout

| Path | Purpose |
| --- | --- |
| `Azumanga/App` | App entry point, environment, migration and onboarding |
| `Azumanga/Discovery` | Browse, global search and discovery models |
| `Azumanga/Library` | Library and reading history UI |
| `Azumanga/MangaDetail` | Manga metadata, chapter list and batch read actions |
| `Azumanga/Reading` | Reader window, layouts, zoom, scrubbing and full screen |
| `Azumanga/Downloads` | Download queue and offline records |
| `Azumanga/Providers` | Native, JavaScript and Kotatsu source adapters |
| `Azumanga/Persistence` | SwiftData models and repositories |
| `Azumanga/Settings` | Settings UI, source management and health checks |
| `AzumangaTests` | Unit and integration tests |
| `ParserHost` | Kotlin/JVM Kotatsu parser host |
| `Documentation` | Provider and developer documentation |

---

## Provider architecture

The app has three provider kinds:

1. **Built-in native providers** — currently MangaDex, implemented directly in
   Swift against the MangaDex API.
2. **Installed JavaScript providers** — user-installed sources running in a
   restricted JavaScript sandbox. See
   [`Documentation/ProviderAPI.md`](Documentation/ProviderAPI.md).
3. **Kotatsu parser sources** — Kotlin/JVM scrapers running in the separate parser
   host and accessed over a JSON line protocol.

Enabled sources and source preferences are persisted through SwiftData. Pinned
sources are shown first and remain available in Browse/Global Search.

---

## Legal and content disclaimer

Azumanga is a reader client. It does **not** include, host, store, mirror or
distribute manga, images or other copyrighted content.

- Manga, cover art, chapter images, titles and trademarks belong to their
  respective copyright owners.
- The app only displays content that third-party sources make available through
  their own APIs or websites.
- Source availability, accuracy and legality are the responsibility of the source
  operator and the user.
- You are responsible for complying with the laws of your jurisdiction and with
  each source's terms of service.
- Use Azumanga only with content you are legally permitted to access.
- Azumanga is not affiliated with MangaDex, Kotatsu, or any third-party source.

The software is provided **as is**, without warranty of any kind. The maintainers
are not responsible for how third-party sources are used or for content accessed
through them.

---

## DMCA and takedown notices

If you are a copyright owner or an authorized agent and believe that material
accessible through this project infringes your copyright, please send a written
notice to the repository maintainer using the contact information on their GitHub
profile. Replace this paragraph with a dedicated legal contact address before
publishing a production repository.

A useful notice should include:

1. Identification of the copyrighted work or works claimed to be infringed.
2. Identification of the material claimed to be infringing, including the
   provider/source name and the relevant URLs or identifiers, with enough detail
   for the material to be located.
3. Your name, address, telephone number and email address.
4. A statement that you have a good-faith belief that the disputed use is not
   authorized by the copyright owner, its agent or the law.
5. A statement, under penalty of perjury, that the information in the notice is
   accurate and that you are the copyright owner or authorized to act on the
   owner's behalf.
6. Your physical or electronic signature.

Because Azumanga does not host manga content, valid notices will generally be
handled by:

- Disabling or removing a provider/source definition from the project, where the
  project itself controls that definition.
- Directing the notice to the third-party source operator that actually hosts the
  material.

Knowingly submitting a materially false or misleading takedown notice may expose
you to liability. This section is provided for practical guidance and is **not
legal advice**; consult an attorney for DMCA or other legal questions.

If you believe material was removed in error, you may send a counter-notice with
the same contact details, identification of the removed material, a statement
under penalty of perjury that you have a good-faith belief the material was
removed by mistake or misidentification, and your consent to the jurisdiction of
the appropriate court.

---

## Contributing

- Keep provider-specific behavior inside the relevant provider adapter.
- Add tests for persistence, paging, scrubbing, source matching and parser
  protocol changes.
- Do not add code that bypasses paywalls, DRM or access controls.
- Do not commit downloaded manga, parser caches, build products or bundled runtime
  binaries unless the project explicitly requires them.
- For security issues, avoid opening a public issue with exploit details; contact
  the maintainer privately.

---

## License

No project-wide license has been declared yet. Add a `LICENSE` file before
distributing the repository or accepting external contributions.

Third-party components retain their own licenses, including Swift packages,
Kotatsu parser sources, Gradle dependencies and the bundled JVM runtime. Their
license and attribution files must be preserved when distributing a build.
