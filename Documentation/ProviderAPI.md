# Azumanga Provider API

A **provider** (or *source*) teaches Azumanga how to talk to a manga site. Providers
are plain JavaScript, installed at runtime — you never rebuild or modify the app
to add one.

This document is the contract: manifests, the JavaScript API, and the security
model that governs what a provider is allowed to do.

---

## 1. Security model

Providers are **untrusted code**. Treat everything you write as if a hostile
provider were running next to yours.

* Provider JavaScript runs in an isolated `JSVirtualMachine` — one per provider —
  inside the app process. Downloaded native code is **never** executed; only
  interpreted JavaScript.
* A provider has **no** filesystem access, no DOM, no `fetch`, no access to the
  app's Swift objects or UI, and no way to load native libraries.
* The only capability it has is the bridge described in §5. Network access is
  restricted to the hosts listed in `allowedHosts`; every other host is refused
  before a request is made.
* Manifests are validated on install **and** again on every load. A manifest may
  not claim another provider's id, use path separators, or reference a script
  outside its own directory.
* Installed providers live in
  `~/Library/Application Support/Azumanga/Sources/<id>/` and can be removed at any
  time from **Settings ▸ Sources**.

Because a provider is only as trustworthy as its author, only install providers
you trust.

---

## 2. Package formats

### Single-file bundle (`*.uzsource.json`)

The easiest way to distribute a provider — one JSON file:

```json
{
  "manifest": { "apiVersion": 1, "id": "com.example.demo", "…": "…" },
  "script": "const Source = { /* … */ };"
}
```

Install it with **Settings ▸ Sources ▸ Install from File…**.

### Remote manifest

Publish `manifest.json` next to your script on an HTTPS host and users can install
with **Install from URL…**. The app fetches `manifest.json`, then the file named by
`main` relative to it.

---

## 3. Manifest

```json
{
  "apiVersion": 1,
  "id": "com.example.mangadex-js",
  "name": "MangaDex (example JS provider)",
  "version": "1.0.0",
  "main": "index.js",
  "language": "en",
  "allowedHosts": ["api.mangadex.org", "uploads.mangadex.org", "*.mangadex.network"],
  "capabilities": ["search", "popular", "latest", "filters", "chapters", "pages"],
  "config": [
    { "key": "quality", "label": "Image quality", "type": "select",
      "options": ["data-saver", "data"], "default": "data-saver" }
  ],
  "homepage": "https://example.com"
}
```

| Field | Required | Rules |
| --- | --- | --- |
| `apiVersion` | ✔ | Must be `1`. Unknown versions are refused. |
| `id` | ✔ | Reverse-DNS, letters/digits/`.`/`-`/`_`, 3–128 chars, no leading/trailing dot, no `..`. |
| `name` | ✔ | 1–128 characters. |
| `version` | ✔ | `1.2` or `1.2.3`. |
| `main` | ✔ | A bare `.js` filename in the provider directory (no slashes or `..`). |
| `language` | ✔ | Short language tag such as `en`. |
| `allowedHosts` | ✔ | Non-empty. `example.com` also allows `*.example.com`; `*.example.com` allows subdomains only. `*` is rejected. |
| `capabilities` | ✔ | Any of `search`, `popular`, `latest`, `filters`, `chapters`, `pages`. Methods for capabilities you omit may throw `unsupported` without breaking the app. |
| `config` | – | User-settable fields (see below). |
| `icon`, `homepage` | – | Informational. |

`config` fields have `key`, `label`, `type` (`text`, `toggle`, `select`), optional
`options` (required for `select`) and optional `default`. Values are exposed to
JavaScript as `config` (a string map) and are editable in Settings.

### Updates

Reinstalling a **newer** `version` replaces the provider. Installing an **older**
version is refused unless the user explicitly forces it, and every install is
staged and swapped in atomically so a failure can't leave a broken provider.

---

## 4. The JavaScript contract

Define a global `Source` object. Every method may be `async`; anything that
returns a promise is awaited by the runtime.

```js
const Source = {
  // page is 0-based. `filters` is a map of filter id → value.
  async search(query, page, filters) {
    return { items: [ /* Manga */ ], hasNextPage: true, total: 123 };
  },

  async popular(page) { /* → { items, hasNextPage, total } */ },
  async latest(page)  { /* → { items, hasNextPage, total } */ },

  async mangaDetails(id) { /* → Manga */ },

  async chapters(mangaId) { /* → { items: [ Chapter ] } */ },

  async pages(chapterId) { /* → { items: [ { url, headers? } ] } */ },

  async filters() { /* → { items: [ Filter ] } */ }
};

globalThis.Source = Source;
```

### Manga

```jsonc
{
  "id": "uuid",            // required, stable within this source
  "title": "Solo Leveling",
  "altTitles": ["…"],
  "description": "…",
  "coverURL": "https://…",  // absolute; fetched through the app, never hotlinked
  "author": "…",
  "artist": "…",
  "status": "ongoing",      // ongoing | completed | hiatus | cancelled
  "genres": ["Action"],
  "contentRating": "safe",  // safe | suggestive | erotica | pornographic
  "year": 2018,
  "lastChapter": "179",
  "url": "https://…"        // where a user can open the title in a browser
}
```

### Chapter

```jsonc
{
  "id": "uuid",             // required
  "title": "The Long Night",
  "number": 12.5,           // numeric; omit for oneshots
  "volume": "2",
  "language": "en",
  "scanlator": "Group",
  "publishedAt": 1694534400000,  // milliseconds since the Unix epoch
  "pageCount": 20,
  "url": "https://…"        // set when the chapter is external (not readable here)
}
```

Chapters with a `url` are treated as externally hosted: the reader explains that
no pages are available and offers to open the link instead.

### Page

```jsonc
{ "url": "https://…/1.jpg", "headers": { "Referer": "https://…" } }
```

`headers` is optional and is applied to the image request. Pages are always
downloaded through the app (which caches, downsamples and respects the manifest's
`allowedHosts`).

### Filter

```jsonc
{ "id": "status", "name": "Status", "kind": "select",
  "options": [ { "id": "ongoing", "name": "Ongoing" } ] }
```

`kind` is one of `text`, `toggle`, `select`, `multiSelect`, or `group` (with a
nested `filters` array). The chosen values arrive in `search(query, page, filters)`
as `{ "status": "ongoing", "year": "2021" }`.

---

## 5. Available globals

Nothing else exists — there is no `document`, `fetch`, `XMLHttpRequest`, `URL`,
`URLSearchParams`, `setTimeout` or `require`.

| Global | Description |
| --- | --- |
| `await http.get(url, headers?)` | → `{ status, headers, url, bytes, body }`. `body` is parsed JSON when the response is JSON, otherwise a string. |
| `await http.post(url, body?, contentType?, headers?)` | Same shape. |
| `config` | Map of the provider's configured values. |
| `console.log/warn/error/info(…)` | Written to the app log. |
| `utils.base64Decode(text)` / `utils.base64Encode(text)` | String helpers. |
| `await utils.sleep(ms)` | Delay, useful for polite pacing (max 30 s). |

`http` requests go through the app's shared HTTP client, so they inherit retries,
rate limiting and a recognisable `User-Agent`. Requests to hosts outside
`allowedHosts` are rejected with an error. Responses larger than 32 MB are
refused, and a provider call that takes longer than 30 seconds is abandoned.

Since JavaScriptCore implements ECMAScript (not the web) you get `JSON`, `Math`,
`Date`, `Promise`, `encodeURIComponent`, `isFinite`, `Number` and friends, but not
browser APIs — build query strings by hand, as the sample provider does.

---

## 6. A complete example

The app ships a full provider that speaks the MangaDex REST API. Install it from
**Settings ▸ Sources ▸ Install Example Provider** to see a working source appear
without rebuilding anything, and read it as a starting point:

* `SampleProvider.manifest.json`
* `SampleProvider.index.js`

---

## 7. Testing a provider

1. Install it from Settings and enable it.
2. **Browse** — check `popular`/`latest` load and paginate (`hasNextPage`).
3. **Search** — check queries and filters arrive as expected.
4. Open a title, then a chapter, and confirm images render.
5. Check `console.log` output in the app log (Console.app, subsystem `org.azumanga`,
   category `providers`) when something misbehaves.

If a provider fails to load, the Sources screen reports the reason; malformed
manifests are rejected rather than half-installed.
