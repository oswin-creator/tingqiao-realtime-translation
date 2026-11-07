import copy
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location("wikidata_builder", Path(__file__).parents[1] / "Tools/update-wikidata.py")
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)


def entity(qid="Q123", english="synthetic specialist concept"):
    return {"id": qid, "lastrevid": 1234,
        "labels": {lang: {"language": lang, "value": value} for lang, value in {
            "en": english, "ko": "합성 전문 개념", "ja": "合成専門概念", "zh": "合成专业概念"}.items()},
        "aliases": {"en": [{"language": "en", "value": value} for value in [english.upper(), "power", "specialist alternative", "Q123", "synthetic specialist concept"]]},
        "descriptions": {"en": {"value": "technical concept used only in this offline test"}},
        "sitelinks": {"enwiki": {}, "kowiki": {}}}


class BuilderTests(unittest.TestCase):
    def test_labels_are_not_translated_or_filled(self):
        forms, sources = wd.forms_from_entity(entity())
        self.assertNotIn("fr", forms)
        self.assertEqual(forms["ko"]["preferred"], "합성 전문 개념")
        self.assertEqual(forms["zh-CN"]["preferred"], "合成专业概念")
        self.assertEqual(forms["zh-TW"]["preferred"], "合成专业概念")
        self.assertEqual(sources["zh-TW"], "zh")
        for alias in forms["en"].get("aliases", []):
            self.assertNotIn(alias, ["power", "Q123"])
        self.assertLessEqual(len(forms["en"].get("aliases", [])), 3)

    def test_exact_chinese_variant_wins_without_conversion(self):
        item = entity()
        item["labels"]["zh-hant"] = {"value": "合成專業概念"}
        forms, sources = wd.forms_from_entity(item)
        self.assertEqual(forms["zh-TW"]["preferred"], "合成專業概念")
        self.assertEqual(sources["zh-TW"], "zh-hant")

    def test_quality_gate(self):
        self.assertIsNotNone(wd.convert(entity(), "statistics"))
        for modify in [
            lambda e: e["labels"].pop("en"),
            lambda e: e.update(sitelinks={"enwiki": {}}),
            lambda e: e.update(descriptions={"en": {"value": "scientific article about statistics"}}),
            lambda e: e.update(descriptions={"en": {"value": "human gene"}}),
            lambda e: e["labels"]["en"].update(value="Q123"),
        ]:
            item = entity(); modify(item)
            with self.subTest(item=item):
                self.assertIsNone(wd.convert(item, "statistics"))
        item = entity(); item["labels"] = {key: item["labels"][key] for key in ["en", "zh"]}
        self.assertIsNone(wd.convert(item, "statistics"), "generic Chinese cannot count as two independent languages")

    def test_verified_wikipedia_count_does_not_fabricate_site_records(self):
        item = entity(); item["sitelinks"] = {}
        self.assertIsNone(wd.convert(item, "statistics"))
        self.assertIsNone(wd.convert(item, "statistics", wikipedia_count=1))
        self.assertIsNotNone(wd.convert(item, "statistics", wikipedia_count=2))
        self.assertEqual(item["sitelinks"], {}, "an audited count must not invent source records")
        item["labels"].pop("ko"); item["labels"].pop("ja")
        self.assertIsNone(wd.convert(item, "statistics", wikipedia_count=50), "site count cannot replace multilingual quality")

    def test_missing_korean_not_invented(self):
        item = entity(); item["labels"].pop("ko")
        converted = wd.convert(item, "statistics")
        self.assertIsNotNone(converted)
        self.assertNotIn("ko", converted[0]["forms"])

    def test_medical_concept_is_not_rejected_merely_for_mentioning_protein(self):
        item = entity(english="antibody")
        item["descriptions"]["en"]["value"] = "protein used by the immune system"
        self.assertIsNotNone(wd.convert(item, "medicine"))

    def test_beverages_and_known_cross_language_conflicts_are_not_medical_terms(self):
        for description in ["alcoholic drink made from grain", "type of fruit wine", "anatomical structure in insects"]:
            item = entity(); item["descriptions"]["en"]["value"] = description
            self.assertIsNone(wd.convert(item, "medicine"))
        self.assertIsNone(wd.convert(entity(qid="Q11086612"), "medicine"))

    def test_raw_english_phrase_in_asian_label_is_omitted_not_translated(self):
        item = entity(); item["labels"]["zh"]["value"] = "system image"
        forms, _ = wd.forms_from_entity(item)
        self.assertNotIn("zh-CN", forms)
        item["labels"]["zh"]["value"] = "SQL"
        forms, _ = wd.forms_from_entity(item)
        self.assertEqual(forms["zh-CN"]["preferred"], "SQL")
        self.assertEqual(wd.convert(entity(english="legitimacy"), "law")[0]["kind"], "contextual")

    def test_ambiguous_words_remain_contextual(self):
        for text in ["power", "mean", "charge", "test"]:
            self.assertEqual(wd.convert(entity(english=text), "statistics")[0]["kind"], "contextual")

    def test_invalid_strings(self):
        for text in ["Q123", "123", "bad\nvalue", "x\u200by", "https://example.com", "List of treatments"]:
            self.assertFalse(wd.valid_text(text), text)
        for text in ["검정력", "p-value", "सांख्यिकीय परीक्षण", "kiểm định"]:
            self.assertTrue(wd.valid_text(text), text)

    def test_single_grapheme_labels_do_not_invalidate_swift_library(self):
        for text in ["ฝี", "स्पा", "गो"]:
            self.assertFalse(wd.valid_text(text), text)
        self.assertTrue(wd.valid_text("सांख्यिकीय परीक्षण"))

    def test_discovery_is_narrow_and_official(self):
        query = wd.discovery_query({"roots": ["Q210832"]})
        self.assertIn("?item wdt:P279* ?root", query)
        self.assertNotIn("wdt:P31/wdt:P279*", query)
        self.assertIn("?links >= 2", query)
        self.assertIn("FILTER NOT EXISTS", query)
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                wd.Client(folder).get("https://example.com", {}, "entities")

    def test_structured_search_expands_only_typed_classes(self):
        class Fixture:
            def __init__(self): self.calls = []
            def search(self, expression, cap=5000):
                self.calls.append(expression)
                if len(self.calls) == 1: return ["Q124", "Q125"], False
                return ["Q200", "Q201", "Q200"], False
        client = Fixture()
        rows, metadata = wd.api_discovery(client, {"roots": ["Q123"]})
        self.assertEqual(len(rows), 2)
        self.assertEqual(metadata["expandedClasses"], 3)
        self.assertIn("P31=Q124", client.calls[1])
        self.assertIn("P279=Q125", client.calls[1])
        self.assertIn("-haswbstatement:P31=Q5", client.calls[1])
        self.assertNotIn("statistics", client.calls[1], "free text is not evidence for domain membership")

    def test_search_pagination_uses_continuation_and_records_limit(self):
        with tempfile.TemporaryDirectory() as folder:
            client = wd.Client(folder)
            replies = [{"query": {"search": [{"title": "Q1"}]}, "continue": {"sroffset": 1}},
                {"query": {"search": [{"title": "Q2"}]}, "continue": {"sroffset": 2}}]
            with patch.object(client, "get", side_effect=replies) as get:
                ids, truncated = client.search("haswbstatement:P31=Q123", cap=2)
                self.assertEqual(ids, ["Q1", "Q2"])
                self.assertTrue(truncated)
                self.assertEqual(get.call_args_list[1].args[1]["sroffset"], 1)

    def test_cache_and_headers(self):
        calls = []
        class Response:
            headers = {"Content-Encoding": "gzip"}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return gzip.compress(b'{"entities":{}}')
        def open_request(request, timeout):
            calls.append(request)
            return Response()
        with tempfile.TemporaryDirectory() as folder, patch.object(wd.urllib.request, "urlopen", open_request):
            client = wd.Client(folder)
            self.assertEqual(client.entities(["Q123"]), {})
            self.assertEqual(client.entities(["Q123"]), {})
            self.assertEqual(len(calls), 1)
            self.assertIn("TingQiao", calls[0].headers["User-agent"])
            self.assertEqual(calls[0].headers["Accept-encoding"], "gzip")

    def test_retry_after_is_respected(self):
        clock = [0.0]
        sleeps = []
        class Response:
            headers = {}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"entities":{}}'
        error = urllib.error.HTTPError("https://www.wikidata.org/w/api.php", 429, "limited", {"Retry-After": "120"}, None)
        def sleep(seconds): sleeps.append(seconds); clock[0] += seconds
        with tempfile.TemporaryDirectory() as folder, patch.object(wd.urllib.request, "urlopen", side_effect=[error, Response()]), patch.object(wd.time, "monotonic", lambda: clock[0]), patch.object(wd.time, "sleep", sleep):
            self.assertEqual(wd.Client(folder).entities(["Q123"]), {})
            self.assertGreaterEqual(sleeps[0], 120)

    def test_anonymous_rate_is_conservative_and_http_errors_are_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            client = wd.Client(folder)
            self.assertGreaterEqual(client.intervals["www.wikidata.org"], 6)
            self.assertEqual(wd.retry_delay("12", 65), 12)
            self.assertEqual(wd.retry_delay("invalid", 65), 65)
            self.assertEqual(wd.retry_delay("Thu, 01 Jan 1970 00:00:00 GMT", 65), 0)
        clock = [0.0]
        stream = unittest.mock.Mock()
        error = urllib.error.HTTPError("https://www.wikidata.org/w/api.php", 429, "limited", {"Retry-After": "120"}, stream)
        class Response:
            headers = {}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit): return b'{"entities":{}}'
        def sleep(seconds): clock[0] += seconds
        with tempfile.TemporaryDirectory() as folder, patch.object(wd.urllib.request, "urlopen", side_effect=[error, Response()]), patch.object(wd.time, "monotonic", lambda: clock[0]), patch.object(wd.time, "sleep", sleep):
            client = wd.Client(folder)
            client.entities(["Q123"])
            self.assertEqual(client.stats["http429"], 1)
            self.assertEqual(client.stats["networkSuccesses"], 1)
            self.assertGreater(client.intervals["www.wikidata.org"], 6.5)
            stream.close.assert_called_once()

    def test_build_install_backup_and_custom_isolation(self):
        class FixtureClient:
            def get(self, *args):
                return {"results": {"bindings": [{"item": {"value": "http://www.wikidata.org/entity/Q123"},
                    "description": {"value": "specialist concept"}, "links": {"value": "4"}, "ko": {"value": "합성"}}]}}
            def entities(self, ids): return {qid: entity(qid) for qid in ids}
        config = {"domains": [{"id": "statistics", "topic": "Q12483", "roots": ["Q210832"]}]}
        with tempfile.TemporaryDirectory() as folder:
            output, destination = Path(folder) / "pack.json", Path(folder) / "install"
            wd.build(FixtureClient(), config, output, 50000)
            original = output.read_bytes()
            destination.mkdir(); (destination / "custom.json").write_bytes(b"user work")
            wd.install(output, destination)
            wd.install(output, destination)
            self.assertEqual((destination / "custom.json").read_bytes(), b"user work")
            self.assertEqual((destination / "wikidata.previous.json").read_bytes(), original)
            self.assertTrue((destination / "wikidata.previous.manifest.json").exists())
            summary = json.loads((destination / "wikidata.manifest.json").read_text())
            self.assertNotIn("entities", summary)
            self.assertEqual(summary["entries"], 1)
            self.assertEqual(summary["sha256"], hashlib.sha256(original).hexdigest())
            (destination / "wikidata.json").write_bytes(b"bad current")
            wd.install(output, destination)
            self.assertEqual((destination / "wikidata.previous.json").read_bytes(), original, "a corrupt current pack cannot overwrite verified rollback")
            output.write_bytes(b"tampered")
            with self.assertRaises(ValueError): wd.install(output, destination)
            self.assertEqual((destination / "wikidata.json").read_bytes(), original)

    def test_atomic_failure_preserves_original(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "custom.json"; path.write_bytes(b"original")
            with patch.object(wd.os, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError): wd.atomic_write(path, b"new")
            self.assertEqual(path.read_bytes(), b"original")
            self.assertEqual([p.name for p in Path(folder).iterdir()], ["custom.json"])


if __name__ == "__main__":
    unittest.main()
