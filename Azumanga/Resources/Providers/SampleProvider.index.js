// Sample Azumanga provider — a complete source written in JavaScript.
//
// It talks to the public MangaDex API and exists as a reference implementation
// for provider authors: install it at runtime from Settings ▸ Sources without
// rebuilding the app. Only the globals listed in Documentation/ProviderAPI.md
// are available (http, console, utils, config) — there is no DOM, no filesystem
// and no network access beyond the hosts declared in the manifest.

const API = "https://api.mangadex.org";
const UPLOADS = "https://uploads.mangadex.org";
const PAGE_SIZE = 24;

function language() {
    const value = (config && config.language ? String(config.language) : "").trim();
    return value || "en";
}

function quality() {
    return config && config.quality === "data" ? "data" : "data-saver";
}

function contentRatings() {
    return ["safe", "suggestive"];
}

// JavaScriptCore has no URL/URLSearchParams, so query strings are built by hand.
function encodeQuery(params) {
    const parts = [];
    const keys = Object.keys(params || {});
    for (let i = 0; i < keys.length; i += 1) {
        const key = keys[i];
        const value = params[key];
        if (value === undefined || value === null || value === "") {
            continue;
        }
        const values = Array.isArray(value) ? value : [value];
        for (let j = 0; j < values.length; j += 1) {
            if (values[j] === undefined || values[j] === null || values[j] === "") {
                continue;
            }
            parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(values[j])));
        }
    }
    return parts.length ? "?" + parts.join("&") : "";
}

async function getJSON(path, params) {
    const response = await http.get(API + path + encodeQuery(params));
    if (response.status >= 400) {
        throw new Error("MangaDex request failed with status " + response.status);
    }
    return response.body;
}

function localize(map, preferred) {
    if (!map) {
        return null;
    }
    if (map[preferred]) {
        return map[preferred];
    }
    if (map.en) {
        return map.en;
    }
    if (map["ja-ro"]) {
        return map["ja-ro"];
    }
    const keys = Object.keys(map);
    return keys.length ? map[keys[0]] : null;
}

// The primary title is often not English, while an English translation usually
// lives in altTitles — prefer English so the library reads well.
function titleOf(attributes) {
    if (attributes.title && attributes.title.en) {
        return attributes.title.en;
    }
    const alternates = attributes.altTitles || [];
    for (let i = 0; i < alternates.length; i += 1) {
        if (alternates[i].en) {
            return alternates[i].en;
        }
    }
    return localize(attributes.title, "en") || "Untitled";
}

function coverURL(entity) {
    const relationship = (entity.relationships || []).find(function (item) {
        return item.type === "cover_art";
    });
    const fileName = relationship && relationship.attributes && relationship.attributes.fileName;
    if (!fileName) {
        return null;
    }
    return UPLOADS + "/covers/" + entity.id + "/" + fileName + ".512.jpg";
}

function namesOf(entity, type) {
    return (entity.relationships || [])
        .filter(function (item) { return item.type === type; })
        .map(function (item) { return item.attributes && item.attributes.name; })
        .filter(Boolean)
        .join(", ");
}

function mapManga(entity) {
    const attributes = entity.attributes || {};
    const tags = (attributes.tags || []).filter(function (tag) {
        const group = tag.attributes && tag.attributes.group;
        return group === "genre" || group === "theme";
    });
    return {
        id: entity.id,
        title: titleOf(attributes),
        altTitles: (attributes.altTitles || []).map(function (item) { return localize(item, "en"); }).filter(Boolean),
        description: localize(attributes.description, "en"),
        coverURL: coverURL(entity),
        author: namesOf(entity, "author") || null,
        artist: namesOf(entity, "artist") || null,
        status: attributes.status || null,
        genres: tags.map(function (tag) { return localize(tag.attributes.name, "en"); }).filter(Boolean),
        contentRating: attributes.contentRating || "safe",
        year: attributes.year || null,
        lastChapter: attributes.lastChapter || null,
        url: "https://mangadex.org/title/" + entity.id
    };
}

function mapChapter(entity) {
    const attributes = entity.attributes || {};
    const group = (entity.relationships || []).find(function (item) {
        return item.type === "scanlation_group";
    });
    const parsed = attributes.chapter === null || attributes.chapter === undefined || attributes.chapter === ""
        ? null
        : Number(attributes.chapter);
    const published = attributes.readableAt || attributes.publishAt || attributes.createdAt || null;
    return {
        id: entity.id,
        title: attributes.title || null,
        number: parsed !== null && isFinite(parsed) ? parsed : null,
        volume: attributes.volume || null,
        language: attributes.translatedLanguage || language(),
        scanlator: (group && group.attributes && group.attributes.name) || null,
        publishedAt: published ? Date.parse(published) : null,
        pageCount: attributes.pages || null,
        url: attributes.externalUrl || null
    };
}

function listParams(page) {
    return {
        limit: PAGE_SIZE,
        offset: Math.max(0, page || 0) * PAGE_SIZE,
        "includes[]": ["cover_art", "author", "artist"],
        hasAvailableChapters: "true",
        "contentRating[]": contentRatings()
    };
}

function applyFilters(params, filters) {
    const values = filters || {};
    if (values.status) {
        params["status[]"] = values.status;
    }
    if (values.demographic) {
        params["publicationDemographic[]"] = values.demographic;
    }
    if (values.contentRating && values.contentRating.length) {
        params["contentRating[]"] = values.contentRating;
    }
    if (values.originalLanguage && values.originalLanguage.length) {
        params["originalLanguage[]"] = values.originalLanguage;
    }
    if (values.year) {
        params.year = values.year;
    }
}

function pageResult(data) {
    const offset = data.offset || 0;
    const limit = data.limit || 0;
    const total = data.total || 0;
    return {
        items: (data.data || []).map(mapManga),
        hasNextPage: offset + limit < total,
        total: total
    };
}

const Source = {
    async popular(page) {
        const params = listParams(page);
        params["order[followedCount]"] = "desc";
        return pageResult(await getJSON("/manga", params));
    },

    async latest(page) {
        const params = listParams(page);
        params["order[latestUploadedChapter]"] = "desc";
        return pageResult(await getJSON("/manga", params));
    },

    async search(query, page, filters) {
        const params = listParams(page);
        const trimmed = (query || "").trim();
        if (trimmed) {
            params.title = trimmed;
            params["order[relevance]"] = "desc";
        } else {
            params["order[followedCount]"] = "desc";
        }
        applyFilters(params, filters);
        return pageResult(await getJSON("/manga", params));
    },

    async mangaDetails(id) {
        const data = await getJSON("/manga/" + id, {
            "includes[]": ["cover_art", "author", "artist"]
        });
        return mapManga(data.data);
    },

    async chapters(mangaId) {
        const items = [];
        const limit = 500;
        let offset = 0;
        while (offset < 9500) {
            const data = await getJSON("/manga/" + mangaId + "/feed", {
                "translatedLanguage[]": [language()],
                "order[volume]": "asc",
                "order[chapter]": "asc",
                limit: limit,
                offset: offset,
                "includes[]": ["scanlation_group"],
                "contentRating[]": contentRatings()
            });
            const batch = data.data || [];
            for (let i = 0; i < batch.length; i += 1) {
                items.push(mapChapter(batch[i]));
            }
            offset += limit;
            if (batch.length < limit) {
                break;
            }
        }
        return { items: items };
    },

    async pages(chapterId) {
        const data = await getJSON("/at-home/server/" + chapterId, {});
        let base = String(data.baseUrl || "");
        while (base.length && base.charAt(base.length - 1) === "/") {
            base = base.slice(0, -1);
        }
        const chapter = data.chapter || {};
        const mode = quality();
        const files = mode === "data" ? (chapter.data || []) : (chapter.dataSaver || []);
        const directory = base + "/" + mode + "/" + chapter.hash + "/";
        return {
            items: files.map(function (file) {
                return { url: directory + file };
            })
        };
    },

    async filters() {
        return {
            items: [
                {
                    id: "status",
                    name: "Status",
                    kind: "select",
                    options: [
                        { id: "", name: "Any" },
                        { id: "ongoing", name: "Ongoing" },
                        { id: "completed", name: "Completed" },
                        { id: "hiatus", name: "Hiatus" },
                        { id: "cancelled", name: "Cancelled" }
                    ]
                },
                {
                    id: "demographic",
                    name: "Demographic",
                    kind: "select",
                    options: [
                        { id: "", name: "Any" },
                        { id: "shounen", name: "Shounen" },
                        { id: "shoujo", name: "Shoujo" },
                        { id: "seinen", name: "Seinen" },
                        { id: "josei", name: "Josei" },
                        { id: "none", name: "None" }
                    ]
                },
                {
                    id: "contentRating",
                    name: "Content",
                    kind: "multiSelect",
                    options: [
                        { id: "safe", name: "Safe" },
                        { id: "suggestive", name: "Suggestive" },
                        { id: "erotica", name: "Erotica" },
                        { id: "pornographic", name: "Pornographic" }
                    ]
                },
                {
                    id: "originalLanguage",
                    name: "Original language",
                    kind: "multiSelect",
                    options: [
                        { id: "ja", name: "Japanese" },
                        { id: "ko", name: "Korean" },
                        { id: "zh", name: "Chinese" },
                        { id: "en", name: "English" }
                    ]
                },
                { id: "year", name: "Year", kind: "text" }
            ]
        };
    }
};

// Expose the object under the name the runtime looks for.
globalThis.Source = Source;
