#!/usr/bin/env python3
"""Read-only Wikidata subset builder; never imported by the application.

Only Python's standard library is needed. Discovery and entity batches are
cached independently, so interrupted runs resume without repeating downloads.
No Wikipedia text, dictionary, language model, or translated fallback is used.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

PROJECT = Path(__file__).resolve().parent.parent
LANGUAGES = {
    "en": ["en"], "ko": ["ko"], "ja": ["ja"],
    "zh-CN": ["zh-cn", "zh-hans", "zh"], "zh-TW": ["zh-tw", "zh-hant", "zh"],
    **{s: [s] for s in ["es", "fr", "de", "pt", "it", "ru", "ar", "hi", "id", "vi", "th"]},
}
WD_LANGUAGES = sorted({x for values in LANGUAGES.values() for x in values})
USER_AGENT = "TingQiaoTerminology/0.2.21 (read-only personal-use offline terminology preparation)"
BLOCKED_TYPES = ["Q5", "Q43229", "Q4167410", "Q13406463", "Q13442814", "Q16521", "Q571", "Q11424"]
BAD_DESCRIPTION = re.compile(
    r"\b(scientific article|scholarly article|research paper|scientific journal|academic journal|"
    r"Wikimedia|disambiguation|encyclopedia article|taxon|species of|genus of|"
    r"protein.coding gene|human gene|mouse gene|strain of|company|university|"
    r"born in|political party|fictional character|television series)\b", re.I)
# A safety gate, not an additional lexical data source. These senses need an
# explicit domain even if Wikidata classifies the underlying concept correctly.
AMBIGUOUS = set("power mean significant control plant equity return interest stock share bond charge class object thread port socket key value type model field method function process state normal random test sample range distribution account capital demand supply right duty consideration action party motion case appeal order cell sign culture resistance sensitivity positive negative memory network tree queue heap array list set group ring space point number law contract market price cost benefit utility risk growth depression stress shock shock treatment".split())
# Rejected, not corrected or translated: a small stratified source-label audit
# found these entities mixing a general concept with a local programme/history.
LABEL_CONFLICTS = {"Q1264378": "general psychiatric rehabilitation vs Japanese assistance programme",
                   "Q11086612": "local disease vs history of schistosomiasis in Japan"}


def normalized(text):
    folded = unicodedata.normalize("NFKC", text).casefold()
    return " ".join("".join(c if c.isalnum() or unicodedata.category(c).startswith("M") else " " for c in folded).split())


def conservative_character_count(text):
    # The existing Swift schema requires >=2 normalized grapheme clusters.
    # Do not count combining vowels/tones or virama-linked consonants as
    # independent characters (Python len() counts their code points).
    count, linked = 0, False
    for character in unicodedata.normalize("NFC", text):
        if unicodedata.category(character).startswith("M"):
            linked = linked or "VIRAMA" in unicodedata.name(character, "")
            continue
        if character == "\u0e33":  # Thai SARA AM joins the preceding consonant.
            continue
        if linked and character.isalpha():
            linked = False
            continue
        linked = False
        count += 1
    return count


def valid_text(text):
    return (isinstance(text, str) and 2 <= len(text) <= 120
            and not any(unicodedata.category(c).startswith("C") for c in text)
            and any(c.isalpha() for c in text)
            and not re.fullmatch(r"[QP]\d+", text)
            and not text.startswith(("http:", "https:", "Category:", "Template:", "List of "))
            and conservative_character_count(normalized(text)) >= 2)


def plausible_script(text, language):
    ranges = {"ko": [(0xac00, 0xd7a3), (0x1100, 0x11ff)],
        "ja": [(0x3040, 0x30ff), (0x3400, 0x9fff)],
        "zh-CN": [(0x3400, 0x9fff)], "zh-TW": [(0x3400, 0x9fff)],
        "ar": [(0x0600, 0x06ff), (0x0750, 0x077f)], "ru": [(0x0400, 0x052f)],
        "hi": [(0x0900, 0x097f)], "th": [(0x0e00, 0x0e7f)]}
    if language not in ranges or any(low <= ord(c) <= high for c in text for low, high in ranges[language]):
        return True
    # International names/acronyms may legitimately remain Latin (SQL, Lua,
    # Bluetooth). An untranslated English phrase such as "system image" is
    # not treated as a verified Chinese/Korean/etc. translation.
    return re.fullmatch(r"[A-Z][A-Za-z0-9+.#/_-]{1,15}", text) is not None


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def backup_verified_pair(path):
    """A broken current update must not overwrite the last good rollback."""
    path = Path(path)
    manifest_path = path.with_suffix(".manifest.json")
    if not path.exists() or not manifest_path.exists():
        return
    try:
        payload = path.read_bytes()
        manifest = json.loads(manifest_path.read_bytes())
        if manifest.get("sha256") != hashlib.sha256(payload).hexdigest():
            return
    except (OSError, ValueError):
        return
    atomic_write(path.with_suffix(".previous.json"), payload)
    atomic_write(path.with_suffix(".previous.manifest.json"), manifest_path.read_bytes())


def retry_delay(value, fallback):
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        try:
            return max(0.0, (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds())
        except (TypeError, ValueError, OverflowError):
            return fallback


class Client:
    def __init__(self, cache, wdqs_interval=65, api_interval=6.5):
        self.cache = Path(cache)
        # No owner contact URL/email is available for this local-only tool.
        # Do not impersonate a browser or a registered bot: use the anonymous
        # 10 requests/minute allowance conservatively instead of 1 req/second.
        self.intervals = {"query.wikidata.org": wdqs_interval, "www.wikidata.org": api_interval}
        self.next_request = defaultdict(float)
        self.stats = Counter()

    def get(self, base, parameters, kind):
        if base not in ("https://query.wikidata.org/sparql", "https://www.wikidata.org/w/api.php"):
            raise ValueError("only the official Wikidata endpoints are allowed")
        url = base + "?" + urllib.parse.urlencode(parameters)
        key = hashlib.sha256(url.encode()).hexdigest()
        path = self.cache / kind / (key + ".json.gz")
        if path.exists():
            self.stats["cacheHits"] += 1
            return json.loads(gzip.decompress(path.read_bytes()))
        host = urllib.parse.urlparse(url).hostname
        last_error = None
        for attempt in range(5):
            # Network etiquette/backoff, not completion polling.
            wait = self.next_request[host] - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                "Accept": "application/sparql-results+json" if kind == "queries" else "application/json",
                "Accept-Encoding": "gzip"})
            try:
                self.stats["networkRequests"] += 1
                self.next_request[host] = time.monotonic() + self.intervals[host]
                with urllib.request.urlopen(request, timeout=75) as response:
                    raw = response.read(32 * 1024 * 1024 + 1)
                    if len(raw) > 32 * 1024 * 1024:
                        raise ValueError("oversized response")
                    if response.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                    data = json.loads(raw)
                if "error" in data:
                    if data["error"].get("code") in ("maxlag", "ratelimited", "readonly"):
                        raise OSError("Wikidata temporarily unavailable: " + data["error"]["code"])
                    raise ValueError("Wikidata API error: " + data["error"].get("code", "unknown"))
                atomic_write(path, gzip.compress(encode(data), mtime=0))
                self.stats["networkSuccesses"] += 1
                return data
            except urllib.error.HTTPError as error:
                try:
                    if error.code not in (408, 429, 500, 502, 503, 504):
                        raise
                    last_error = error
                    self.stats["http" + str(error.code)] += 1
                    retry = error.headers.get("Retry-After", "")
                    backoff = retry_delay(retry, 65 * (attempt + 1))
                    reason = f"HTTP {error.code}，Retry-After={retry or '未提供'}"
                    if error.code == 429:
                        self.intervals[host] = min(120.0, max(self.intervals[host], 6.5) * 1.25)
                finally:
                    error.close()
            except (OSError, TimeoutError) as error:
                last_error = error
                self.stats["transportErrors"] += 1
                backoff = 30 * (attempt + 1)
                reason = type(error).__name__
            self.next_request[host] = max(self.next_request[host], time.monotonic() + backoff)
            print(f"{datetime.now().strftime('%H:%M:%S')} 暂缓 {host}：{reason}；等待 {backoff:.1f} 秒；请求间隔 {self.intervals[host]:.1f} 秒；第 {attempt + 1}/5 次；缓存保留", flush=True)
        raise RuntimeError("Wikidata requests failed; rerun to resume from cache") from last_error

    def entities(self, ids):
        # maxlag is intentionally not used for these read-only snapshots:
        # replica freshness is not required; rate errors still trigger backoff.
        return self.get("https://www.wikidata.org/w/api.php", {"action": "wbgetentities",
            "ids": "|".join(ids), "props": "labels|aliases|descriptions|info|sitelinks",
            "languages": "|".join(WD_LANGUAGES), "format": "json"}, "entities")["entities"]

    def search(self, expression, cap=5000):
        ids, offset, truncated = [], 0, False
        while len(ids) < cap:
            data = self.get("https://www.wikidata.org/w/api.php", {"action": "query", "list": "search",
                "srsearch": expression, "srnamespace": 0, "srlimit": min(500, cap - len(ids)),
                "sroffset": offset, "srprop": "", "srinfo": "totalhits", "srsort": "incoming_links_desc", "format": "json"}, "search")
            ids.extend(row["title"] for row in data.get("query", {}).get("search", []) if re.fullmatch(r"Q[1-9]\d*", row["title"]))
            continuation = data.get("continue", {}).get("sroffset")
            if continuation is None:
                break
            offset = continuation
            if len(ids) >= cap or offset >= 10000:
                truncated = True
                break
        return ids, truncated


def api_discovery(client, domain):
    """Bounded structured search on the same official Wikidata data.

    WDQS is optional: no dependence on its availability or new backend syntax.
    Explicit types and their immediate subclasses, not free-text matching.
    """
    root_statement = "haswbstatement:" + "|".join("P279=" + root for root in domain["roots"])
    children, truncated = client.search(root_statement + " haslabel:en", cap=500)
    classes = list(dict.fromkeys(domain["roots"] + children))
    rows, seen = [], set()
    exclusions = " ".join("-haswbstatement:P31=" + item for item in BLOCKED_TYPES)
    for start in range(0, len(classes), 24):
        group = classes[start:start + 24]
        statement = "haswbstatement:" + "|".join(prop + "=" + qid for qid in group for prop in ["P31", "P279"])
        expression = statement + " haslabel:en hasdescription:en " + exclusions
        ids, limited = client.search(expression)
        truncated = truncated or limited
        for qid in ids:
            if qid not in seen:
                seen.add(qid)
                rows.append({"item": {"value": "http://www.wikidata.org/entity/" + qid},
                    "description": {"value": "typed Wikidata candidate; verified in entity phase"}, "links": {"value": "0"}})
    return rows, {"candidates": len(rows), "possiblyTruncated": truncated, "roots": domain["roots"],
        "method": "Wikidata Action API structured haswbstatement search; immediate subclass expansion", "expandedClasses": len(classes)}


def discovery_query(domain, limit=50001):
    roots = " ".join("wd:" + root for root in domain["roots"])
    blocked = " ".join("wd:" + item for item in BLOCKED_TYPES)
    # Traverse concept subclasses, but only direct instances. Unbounded
    # instance-of/subclass-of combinations drag in papers, genes and products.
    return f'''SELECT DISTINCT ?item ?en ?ko ?description ?links WHERE {{
 VALUES ?root {{ {roots} }}
 {{ ?item wdt:P279* ?root }} UNION {{ ?item wdt:P31 ?root }}
 ?item rdfs:label ?en; schema:description ?description; wikibase:sitelinks ?links .
 FILTER(LANG(?en)="en" && LANG(?description)="en" && ?links >= 2)
 OPTIONAL {{ ?item rdfs:label ?ko . FILTER(LANG(?ko)="ko") }}
 FILTER NOT EXISTS {{ ?item wdt:P31 ?bad . VALUES ?bad {{ {blocked} }} }}
}} LIMIT {limit}'''


def forms_from_entity(entity):
    forms, language_sources = {}, {}
    labels, aliases = entity.get("labels", {}), entity.get("aliases", {})
    for language, candidates in LANGUAGES.items():
        source = next((lang for lang in candidates if valid_text(labels.get(lang, {}).get("value"))
            and plausible_script(labels[lang]["value"], language)), None)
        if source is None:
            continue
        preferred = labels[source]["value"]
        form = {"preferred": preferred}
        seen = {normalized(preferred)}
        choices = []
        for alias in aliases.get(source, []):
            text = alias.get("value", "")
            key = normalized(text)
            if (valid_text(text) and plausible_script(text, language) and key not in seen and key not in AMBIGUOUS
                    and not (len(text) <= 3 and not text.isupper())):
                seen.add(key)
                choices.append(text)
        # Keep useful long aliases before short acronyms; nothing is invented.
        choices.sort(key=lambda text: (len(text) <= 4, abs(len(text) - len(preferred)), text))
        if choices:
            form["aliases"] = choices[:3 if language in ("en", "ko") else 1]
        forms[language] = form
        language_sources[language] = source
    return forms, language_sources


def convert(entity, domain, wikipedia_count=None):
    if entity.get("id") in LABEL_CONFLICTS:
        return None
    description = entity.get("descriptions", {}).get("en", {}).get("value", "")
    forms, sources = forms_from_entity(entity)
    links = entity.get("sitelinks", {})
    # Three independent language labels, not counting zh twice; at least two
    # encyclopedic sitelinks. Missing languages are never filled by translation.
    if ("en" not in forms or len(set(sources.values())) < 3
            or (sum(key.endswith("wiki") for key in links) if wikipedia_count is None else wikipedia_count) < 2
            or not description or BAD_DESCRIPTION.search(description)):
        return None
    en = normalized(forms["en"]["preferred"])
    if re.fullmatch(r"\d+(?: \d+)*", en) or re.search(r"\b(?:gene found in|gene located on|protein encoded by|species of|genus of)\b", description, re.I):
        return None
    if domain == "medicine" and re.search(r"\b(?:plant organ|plant structure|in plants|botanical|flowering plants|insects?|arthropods?|molluscs?|invertebrates?|alcoholic (?:drink|beverage)|fruit wine|type of (?:wine|beer)|cocktail|liqueur|brewed beverage)\b", description, re.I):
        return None
    if domain == "business" and re.search(r"\b(?:fund managed by|security issued by|shares of|stock of a company)\b", description, re.I):
        return None
    contextual = en in AMBIGUOUS or " " not in en
    entry = {"id": "wd-" + entity["id"], "domain": domain,
        "kind": "contextual" if contextual else "fixed", "forms": forms}
    # Descriptions are provenance/quality evidence, not automatic sense rules.
    return entry, sources


def build(client, config, output, limit, discovery_method="wdqs"):
    candidates, discovery = {}, {}
    for domain in config["domains"]:
        if discovery_method == "search":
            rows, discovery[domain["id"]] = api_discovery(client, domain)
        else:
            query = discovery_query(domain)
            data = client.get("https://query.wikidata.org/sparql", {"query": query, "format": "json"}, "queries")
            rows = data["results"]["bindings"]
            discovery[domain["id"]] = {"candidates": len(rows), "possiblyTruncated": len(rows) >= 50001,
                "roots": domain["roots"], "querySHA256": hashlib.sha256(query.encode()).hexdigest(), "method": "WDQS"}
        for row in rows:
            qid = row["item"]["value"].rsplit("/", 1)[-1]
            if not re.fullmatch(r"Q[1-9]\d*", qid) or BAD_DESCRIPTION.search(row["description"]["value"]):
                continue
            # First, more specific configured domain wins over broad math.
            candidates.setdefault(qid, {"domain": domain["id"], "korean": "ko" in row,
                "links": int(row["links"]["value"])})
        print(f"领域 {domain['id']}：{len(rows)} 个候选，累计去重 {len(candidates)}", flush=True)

    topics = client.entities([domain["topic"] for domain in config["domains"]])
    domains = []
    for domain in config["domains"]:
        forms, _ = forms_from_entity(topics[domain["topic"]])
        domains.append({"id": domain["id"], "cues": {lang: [form["preferred"]]
            for lang, form in forms.items()}})

    ordered = sorted(candidates, key=lambda q: (not candidates[q]["korean"], -candidates[q]["links"], int(q[1:])))
    accepted, rejected, provenance = [], Counter(), {}
    signatures = set()
    for start in range(0, len(ordered), 50):
        batch = ordered[start:start + 50]
        entities = client.entities(batch)
        for qid in batch:
            entity = entities.get(qid, {})
            if entity.get("id") != qid or "missing" in entity or "redirects" in entity:
                rejected["missing_or_redirect"] += 1
                continue
            converted = convert(entity, candidates[qid]["domain"])
            if converted is None:
                rejected["quality_gate"] += 1
                continue
            entry, sources = converted
            signature = (entry["domain"], tuple((lang, normalized(form["preferred"]))
                for lang, form in sorted(entry["forms"].items())))
            if signature in signatures:
                rejected["identical_multilingual_signature"] += 1
                continue
            signatures.add(signature)
            accepted.append(entry)
            provenance[entry["id"]] = {"revision": entity.get("lastrevid"), "languageSources": sources,
                "sitelinks": len(entity.get("sitelinks", {}))}
        print(f"实体 {min(start + 50, len(ordered))}/{len(ordered)}，合格 {len(accepted)}；请求统计 {dict(getattr(client, 'stats', {}))}", flush=True)
        if len(accepted) >= limit and discovery_method == "wdqs":
            break

    # Search discovery does not return language/links metadata. Rank by the
    # actual entity data after filtering, never by search snippets or guesses.
    accepted.sort(key=lambda entry: ("ko" not in entry["forms"],
        not any("\uac00" <= c <= "\ud7a3" for c in entry["forms"].get("ko", {}).get("preferred", "")),
        -len(set(provenance[entry["id"]]["languageSources"].values())),
        -provenance[entry["id"]].get("sitelinks", 0), int(entry["id"].split("Q")[-1])))
    accepted = accepted[:limit]
    # Homonymous English labels are unsafe as fixed translation constraints.
    same_label = Counter(normalized(entry["forms"]["en"]["preferred"]) for entry in accepted)
    for entry in accepted:
        if same_label[normalized(entry["forms"]["en"]["preferred"])] > 1:
            entry["kind"] = "contextual"
    # Preserve priority order, including real Korean labels, in the local pack.
    library = {"version": 1, "domains": domains, "entries": accepted}
    payload = encode(library)
    if len(payload) > 32 * 1024 * 1024:
        low, high = 0, len(accepted)
        while low < high:
            middle = (low + high + 1) // 2
            probe = encode({**library, "entries": accepted[:middle]})
            if len(probe) <= 32 * 1024 * 1024:
                low = middle
            else:
                high = middle - 1
        rejected["byte_budget"] = len(accepted) - low
        accepted = accepted[:low]
        library["entries"] = accepted
        payload = encode(library)
    manifest = {"source": "Wikidata", "license": "CC0-1.0", "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(), "entries": len(accepted),
        "sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload),
        "requestedLimit": limit, "discovery": discovery, "rejected": dict(rejected),
        "labelConflictExclusions": LABEL_CONFLICTS,
        "requestStats": dict(getattr(client, "stats", {})),
        "domains": dict(Counter(entry["domain"] for entry in accepted)),
        "languages": dict(Counter(lang for entry in accepted for lang in entry["forms"])),
        "koreanWithHangul": sum(any("\uac00" <= c <= "\ud7a3" for c in entry["forms"].get("ko", {}).get("preferred", "")) for entry in accepted),
        "entities": {entry["id"]: provenance[entry["id"]] for entry in accepted},
        "selection": "typed concepts/direct instances; en description; >=3 real language labels; >=2 wiki sitelinks; EN/KO priority; no generated translations",
        "chineseFallback": "exact zh-cn/zh-hans or zh-tw/zh-hant first; otherwise original generic zh verbatim, no script conversion"}
    if not accepted or any(not manifest["domains"].get(domain["id"]) for domain in config["domains"]):
        raise ValueError("empty output or missing domain; no existing pack replaced")
    output = Path(output)
    backup_verified_pair(output)
    atomic_write(output.with_suffix(".manifest.json"), encode(manifest))
    atomic_write(output, payload)
    print(f"完成：{len(accepted)} 条，{len(payload) / 1024 / 1024:.2f} MiB；韩文栏 {manifest['languages'].get('ko', 0)}，含韩文字母 {manifest['koreanWithHangul']}", flush=True)
    return manifest


def install(output, destination):
    output, destination = Path(output), Path(destination)
    manifest = json.loads(output.with_suffix(".manifest.json").read_text())
    payload = output.read_bytes()
    if (hashlib.sha256(payload).hexdigest() != manifest["sha256"] or manifest["source"] != "Wikidata"
            or manifest.get("license") != "CC0-1.0" or manifest.get("schemaVersion") != 1):
        raise ValueError("manifest mismatch")
    data = json.loads(payload)
    if (len(data["entries"]) != manifest["entries"] or len(payload) > 32 * 1024 * 1024
            or len(data["entries"]) > 50000):
        raise ValueError("invalid data pack limits")
    target = destination / "wikidata.json"
    backup_verified_pair(target)
    # Only this external layer is replaced. custom.json is never touched.
    # Detailed per-entity revisions/language provenance stay with the build
    # report and raw cache; the runtime needs only this small summary.
    atomic_write(destination / "wikidata.manifest.json", encode({key: value for key, value in manifest.items() if key not in ("entities", "newEntities")}))
    atomic_write(target, payload)
    print(f"已安装外部数据层：{target}；重新加载词库或重开应用后使用", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=PROJECT / ".qa-data/wikidata-cache")
    parser.add_argument("--output", type=Path, default=PROJECT / "build/terminology/wikidata.json")
    parser.add_argument("--limit", type=int, default=49900)
    parser.add_argument("--discovery", choices=["search", "wdqs"], default="search")
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--install-only", action="store_true")
    parser.add_argument("--destination", type=Path, default=Path.home() / "Library/Application Support/TingQiao/Terminology")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50000:
        parser.error("limit must be between 1 and 50000")
    if not args.install_only:
        config = json.loads((PROJECT / "Tools/wikidata-terminology.json").read_text())
        build(Client(args.cache), config, args.output, args.limit, args.discovery)
    if args.install or args.install_only:
        install(args.output, args.destination)


if __name__ == "__main__":
    main()
