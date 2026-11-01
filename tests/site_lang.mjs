// Checks the site's language redirect and that every page links to every language. Usage: node tests/site_lang.mjs
import assert from "node:assert";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const root = new URL("../site/", import.meta.url);
const script = readFileSync(new URL("lang.js", root), "utf8");

function visit({ path = "/", search = "", languages = ["en"], stored = null, blocked = false }) {
  let went = null;
  const store = { lang: stored };
  const localStorage = {
    getItem(k) { if (blocked) throw new Error("blocked"); return store[k]; },
    setItem(k, v) { if (blocked) throw new Error("blocked"); store[k] = v; },
  };
  vm.runInNewContext(script, {
    localStorage,
    navigator: { languages },
    document: { addEventListener() {} },
    location: { pathname: path, search, replace(to) { went = to; } },
  });
  return { went, stored: store.lang };
}

assert.equal(visit({ languages: ["ko-KR", "en"] }).went, "/ko/");
assert.equal(visit({ languages: ["ja"] }).went, "/ja/");
assert.equal(visit({ languages: ["zh-TW"] }).went, "/zh/");
assert.equal(visit({ languages: ["en-US", "ko"] }).went, null);
assert.equal(visit({ languages: ["fr", "ja"] }).went, "/ja/");
assert.equal(visit({ languages: ["fr"] }).went, null);
assert.equal(visit({ languages: ["ko"], stored: "en" }).went, null);
assert.equal(visit({ languages: ["en"], stored: "ja" }).went, "/ja/");
assert.equal(visit({ path: "/ko/", languages: ["ja"] }).went, null);
const english = visit({ search: "?lang=en", languages: ["ko"] });
assert.equal(english.went, null);
assert.equal(english.stored, "en");
assert.equal(visit({ search: "?lang=en", languages: ["ko"], blocked: true }).went, null);
assert.equal(visit({ languages: ["ko"], blocked: true }).went, "/ko/");

for (const [page, lang] of [["index.html", "en"], ["ko/index.html", "ko"], ["ja/index.html", "ja"], ["zh/index.html", "zh-Hans"]]) {
  const html = readFileSync(new URL(page, root), "utf8");
  assert.ok(html.includes(`<html lang="${lang}">`), page);
  assert.ok(html.includes('<script src="/lang.js"></script>'), page);
  for (const code of ["en", "ko", "ja", "zh-Hans", "x-default"]) assert.ok(html.includes(`rel="alternate" hreflang="${code}"`), `${page} ${code}`);
  for (const code of ["en", "ko", "ja", "zh"]) assert.ok(html.includes(`hreflang="${code}" lang=`), `${page} switcher ${code}`);
}
console.log("site languages ok");
