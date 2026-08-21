/**
 * Talking to Elasticsearch, one index at a time.
 *
 * A client is bound to a URL and an index because everything here scores one
 * index: the report pins an index so an A/B is not confounded by the alias
 * moving under it, and the shape search reuses that pin for every candidate.
 *
 * `search` sends one body. `msearch` sends many in one request, which is the
 * difference between five minutes and twenty-five seconds over a curated set of
 * 351 queries - the reason a shape search is feasible at all. Both retry the
 * failures worth retrying and give up immediately on the ones that are not
 * going to get better.
 */

const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);
const MAX_ATTEMPTS = 5;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Where to score against, from the environment.
 *
 * The public cluster is the default because that is what the report is about;
 * `ELASTICSEARCH_URL` points the same code at a local replica.
 */
export function esConfigFromEnv() {
    return {
        url: process.env.ELASTICSEARCH_URL || "https://search.nixos.org/backend",
        username: process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv",
        password: process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh",
    };
}

/**
 * An Elasticsearch client bound to one index.
 *
 * `log` receives retry notices; pass a no-op to keep a long search quiet.
 */
export function esClient({
    url,
    index,
    username,
    password,
    log = (message) => console.error(message),
}) {
    const auth =
        "Basic " + Buffer.from(`${username}:${password}`).toString("base64");

    async function request(path, { method = "POST", body, contentType } = {}) {
        let lastErr;
        for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            try {
                const resp = await fetch(`${url}${path}`, {
                    method,
                    headers: {
                        ...(contentType && { "Content-Type": contentType }),
                        Authorization: auth,
                    },
                    body,
                });
                // Awaited, not returned: a socket that dies part-way through a
                // large response body rejects here rather than at the `fetch`,
                // and `return resp.json()` would settle outside this `try` and
                // escape the retry entirely.
                if (resp.ok) return await resp.json();
                const text = await resp.text();
                // Non-retryable (e.g. auth/query errors): fail immediately.
                if (!RETRYABLE_STATUS.has(resp.status)) {
                    throw new Error(`ES ${resp.status}: ${text}`);
                }
                lastErr = new Error(`ES ${resp.status}: ${text}`);
            } catch (err) {
                // fetch() rejects on network faults (ECONNRESET, DNS, TLS);
                // retry those.
                if (err instanceof TypeError && err.cause) {
                    lastErr = err;
                } else {
                    throw err;
                }
            }
            if (attempt < MAX_ATTEMPTS) {
                // Exponential backoff with jitter: ~0.5s, 1s, 2s, 4s.
                const backoff = 500 * 2 ** (attempt - 1) + Math.random() * 250;
                log(
                    `[benchmark] request failed (attempt ${attempt}/${MAX_ATTEMPTS}): ${lastErr.message}; retrying in ${Math.round(backoff)}ms`,
                );
                await sleep(backoff);
            }
        }
        throw lastErr;
    }

    return {
        index,

        /**
         * A plain GET, for the metadata endpoints that take no body.
         *
         * Unlike the rest of this client the path is not index-scoped, because
         * `_settings` and `_mapping` are read by index name rather than
         * queried.
         */
        get(path) {
            return request(path, { method: "GET" });
        },

        /** One request body, one response. */
        search(bodyJson) {
            return request(`/${index}/_search`, {
                body: bodyJson,
                contentType: "application/json",
            });
        },

        /**
         * Many request bodies, one round trip, responses in the order sent.
         *
         * `_msearch` takes NDJSON of alternating header and body lines. The
         * header is empty because the client is already bound to an index. A
         * per-body failure comes back as an `error` member in that slot rather
         * than failing the request, so it is raised here - a shape that ES
         * rejects is a bug in the shape, not a score of zero.
         */
        async msearch(bodyJsons) {
            if (bodyJsons.length === 0) return [];
            const ndjson =
                bodyJsons.map((body) => `{}\n${body}`).join("\n") + "\n";
            const data = await request(`/${index}/_msearch`, {
                body: ndjson,
                contentType: "application/x-ndjson",
            });
            return data.responses.map((response, i) => {
                if (response.error) {
                    throw new Error(
                        `ES _msearch response ${i}: ${JSON.stringify(response.error)}`,
                    );
                }
                return response;
            });
        },
    };
}
