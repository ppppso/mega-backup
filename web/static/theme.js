// Colour theme: Auto (follow the system), Light or Dark, remembered in this browser.
(function () {
  "use strict";
  var KEY = "theme", ORDER = ["auto", "light", "dark"], LABEL = { auto: "Auto", light: "Light", dark: "Dark" };
  var root = document.documentElement;

  function load() {
    try { var t = localStorage.getItem(KEY); return ORDER.indexOf(t) >= 0 ? t : "auto"; }
    catch (e) { return "auto"; }
  }
  function apply(t) {
    if (t === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", t);
    var b = document.getElementById("theme-toggle");
    if (b) b.textContent = "Theme: " + LABEL[t];
  }

  var theme = load();
  apply(theme);
  document.addEventListener("DOMContentLoaded", function () {
    apply(theme);
    var b = document.getElementById("theme-toggle");
    if (!b) return;
    b.addEventListener("click", function () {
      theme = ORDER[(ORDER.indexOf(theme) + 1) % ORDER.length];
      try { localStorage.setItem(KEY, theme); } catch (e) { /* private window: not remembered */ }
      apply(theme);
    });
  });
})();
