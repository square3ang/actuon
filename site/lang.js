(function () {
  var pages = ["ko", "ja", "zh"];

  function saved() {
    try { return localStorage.getItem("lang"); } catch (e) { return null; }
  }

  function save(lang) {
    try { localStorage.setItem("lang", lang); } catch (e) {}
  }

  // The browser's first language we have a page for; English counts, so en-then-ko stays on English.
  function preferred(languages) {
    for (var i = 0; i < languages.length; i++) {
      var code = languages[i].toLowerCase().split("-")[0];
      if (code === "en" || pages.indexOf(code) >= 0) return code;
    }
    return "en";
  }

  document.addEventListener("click", function (e) {
    var link = e.target.closest && e.target.closest("a[hreflang]");
    if (link) save(link.hreflang);
  });

  if (location.pathname !== "/") return;
  // The English link carries this, so it still works where storage is blocked.
  if (location.search === "?lang=en") return save("en");
  var lang = saved() || preferred(navigator.languages || [navigator.language || ""]);
  if (pages.indexOf(lang) >= 0) location.replace("/" + lang + "/");
})();
