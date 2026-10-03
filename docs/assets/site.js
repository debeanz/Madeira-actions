/* Madeira — site script. No dependencies, no build step.
   Everything people write (titles, descriptions, settings) reaches the page
   through textContent, never as HTML. */
(function () {
  "use strict";

  var cfg = window.MADEIRA_CONFIG || {};

  // ── Vocabulary — the same ids the app sends and supabase/schema.sql checks ──

  var RATINGS = [
    { id: "perfect",  label: "Perfect",  blurb: "Plays like it does on a PC." },
    { id: "playable", label: "Playable", blurb: "Small problems that don't get in the way." },
    { id: "runs",     label: "Runs",     blurb: "Reaches gameplay, with problems you notice." },
    { id: "boots",    label: "Boots",    blurb: "Starts, but can't really be played." },
    { id: "broken",   label: "Broken",   blurb: "Doesn't start, or crashes right away." }
  ];
  var RATING = {};
  RATINGS.forEach(function (r, i) { RATING[r.id] = { id: r.id, label: r.label, blurb: r.blurb, rank: i }; });

  var ISSUES = {
    crash: "Crashes", slow: "Low frame rate", graphics: "Graphics glitches",
    audio: "Audio problems", controls: "Controls", video: "Videos don't play"
  };
  var FPS = {
    "under-20": "Under 20 fps", "20-30": "20–30 fps", "30-45": "30–45 fps", "45-60": "45–60 fps", "60": "60 fps"
  };
  var DEVICES = {
    "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
    "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd gen)", "iPhone14,7": "iPhone 14",
    "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
    "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
    "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
    "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e"
  };

  var reduceMotion = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ── DOM helper ─────────────────────────────────────────────────────────────

  function h(tag, props) {
    var n = document.createElement(tag);
    if (props) {
      Object.keys(props).forEach(function (k) {
        var v = props[k];
        if (v == null || v === false) return;
        if (k === "class") n.className = v;
        else if (k === "text") n.textContent = v;
        else if (k === "style") n.setAttribute("style", v);
        else if (k.slice(0, 2) === "on") n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v === true ? "" : v);
      });
    }
    for (var i = 2; i < arguments.length; i++) append(n, arguments[i]);
    return n;
  }
  function append(n, kid) {
    if (kid == null || kid === false) return;
    if (Array.isArray(kid)) { kid.forEach(function (k) { append(n, k); }); return; }
    n.appendChild(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  function $(sel, root) { return (root || document).querySelector(sel); }

  // ── Covers — Steam header art, else the app's own placeholder ───────────────

  // FNV-1a over UTF-8, exactly LauncherPalette.hue(for:) in the app, so a game
  // without art gets the same colours here as in the Games tab.
  function hue(title) {
    var x = 0x811c9dc5, bytes = new TextEncoder().encode(title);
    for (var i = 0; i < bytes.length; i++) { x ^= bytes[i]; x = Math.imul(x, 0x01000193) >>> 0; }
    return (x >>> 0) % 360;
  }
  function placeholderStyle(title) {
    var hh = hue(title);
    // HSB(0.55, 0.55) → HSB(0.65, 0.22) from the app, converted to HSL.
    return "background:linear-gradient(135deg,hsl(" + hh + " 37.9% 39.9%),hsl(" + hh + " 48.1% 14.9%))";
  }
  function steamId(v) { var n = Number(v); return Number.isInteger(n) && n > 0 ? n : null; }
  var STEAM = [
    function (id) { return "https://shared.steamstatic.com/store_item_assets/steam/apps/" + id + "/header.jpg"; },
    function (id) { return "https://cdn.cloudflare.steamstatic.com/steam/apps/" + id + "/header.jpg"; }
  ];
  function cover(title, sid, eager) {
    var ph = h("div", { class: "ph", style: placeholderStyle(title) }, title);
    var box = h("div", { class: "cover" }, ph);
    var id = steamId(sid);
    if (id) {
      var tried = 0;
      var img = h("img", { alt: "", class: "loading", decoding: "async", loading: eager ? "eager" : "lazy" });
      img.addEventListener("load", function () { img.classList.remove("loading"); ph.remove(); });
      img.addEventListener("error", function () {
        tried += 1;
        if (tried < STEAM.length) img.src = STEAM[tried](id); else img.remove();
      });
      img.src = STEAM[0](id);
      box.insertBefore(img, ph);
    }
    return box;
  }
  function headerUrl(sid) { var id = steamId(sid); return id ? STEAM[0](id) : null; }

  // ── Small formatters ───────────────────────────────────────────────────────

  var rtf = window.Intl && Intl.RelativeTimeFormat ? new Intl.RelativeTimeFormat("en", { numeric: "auto" }) : null;
  function ago(iso) {
    var s = (new Date(iso).getTime() - Date.now()) / 1000;
    var units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
    for (var i = 0; i < units.length; i++) {
      if (Math.abs(s) >= units[i][1]) {
        return rtf ? rtf.format(Math.round(s / units[i][1]), units[i][0]) : new Date(iso).toLocaleDateString();
      }
    }
    return "just now";
  }
  function deviceName(id) { return DEVICES[id] || id; }
  // "0.1.125 (125, 5b4a587+wow64)" → "0.1.125"
  function shortVersion(v) { return String(v).split(" ")[0]; }
  function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }
  function frameCapText(v) {
    if (/^\d+$/.test(v)) return v + " fps cap";
    if (/^MAX/i.test(v)) return "Display-rate cap";
    if (/^RAW/i.test(v)) return "Unthrottled";
    return null;
  }

  // ── Ratings ────────────────────────────────────────────────────────────────

  // The rating most reports agree on; a tie goes to the better one.
  function verdict(g) {
    var best = null;
    RATINGS.forEach(function (r) {
      var n = Number(g[r.id]) || 0;
      if (n > 0 && (!best || n > best.n)) best = { id: r.id, n: n };
    });
    return best ? best.id : null;
  }
  function ratingBadge(id, large) {
    var r = RATING[id];
    return h("span", { class: "rating r-" + (r ? id : "none") + (large ? " lg" : "") }, r ? r.label : "No reports");
  }
  function distBar(g, large) {
    var total = 0;
    RATINGS.forEach(function (r) { total += Number(g[r.id]) || 0; });
    var label = RATINGS.map(function (r) { return r.label + ": " + (Number(g[r.id]) || 0); }).join(", ");
    var bar = h("div", { class: "dist" + (large ? " lg" : ""), role: "img", "aria-label": label });
    RATINGS.forEach(function (r) {
      var n = Number(g[r.id]) || 0;
      if (!n) return;
      var seg = h("span", { class: "r-" + r.id, title: r.label + ": " + n });
      seg.dataset.w = (n / (total || 1) * 100).toFixed(2) + "%";
      bar.appendChild(seg);
    });
    grow(bar);
    return bar;
  }

  // ── Motion ─────────────────────────────────────────────────────────────────

  var io = "IntersectionObserver" in window ? new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (!e.isIntersecting) return;
      var t = e.target;
      if (t.classList.contains("dist")) {
        Array.prototype.forEach.call(t.children, function (s) { s.style.width = s.dataset.w; });
      } else {
        t.classList.add("in");
      }
      io.unobserve(t);
    });
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 }) : null;

  function grow(bar) {
    if (!io || reduceMotion) {
      Array.prototype.forEach.call(bar.children, function (s) { s.style.width = s.dataset.w; });
    } else {
      io.observe(bar);
    }
  }
  function reveal(root) {
    var els = (root || document).querySelectorAll(".reveal:not(.in)");
    Array.prototype.forEach.call(els, function (el) {
      if (io && !reduceMotion) io.observe(el); else el.classList.add("in");
    });
  }

  // The hero's iPhone: focus walks the Games tab like a controller would, and
  // every third game gets a press of Play.
  function initDevice() {
    var stage = $(".device-stage"), dev = $(".device");
    if (!stage || !dev) return;
    var tiles = Array.prototype.slice.call(dev.querySelectorAll(".tile"));
    var track = $(".lib-track", dev), title = $(".lib-card .t", dev), sub = $(".lib-card .s", dev), play = $(".lib-play", dev);
    if (!tiles.length) return;

    // Art for the tiles.
    tiles.forEach(function (t) {
      var c = cover(t.dataset.title, t.dataset.steam, true);
      while (c.firstChild) t.appendChild(c.firstChild);
    });

    var i = 0, visible = true;
    function focus(n, instant) {
      tiles.forEach(function (t, k) { t.classList.toggle("focus", k === n); });
      var step = tiles.length > 1 ? tiles[1].offsetLeft - tiles[0].offsetLeft : 0;
      track.style.transform = "translateX(" + (-Math.max(0, n - 1) * step) + "px)";
      if (instant) { title.textContent = tiles[n].dataset.title; sub.textContent = tiles[n].dataset.sub; return; }
      title.classList.add("swap"); sub.classList.add("swap");
      setTimeout(function () {
        title.textContent = tiles[n].dataset.title; sub.textContent = tiles[n].dataset.sub;
        title.classList.remove("swap"); sub.classList.remove("swap");
      }, 230);
    }
    focus(0, true);
    if (reduceMotion) return;

    if (io) {
      new IntersectionObserver(function (es) { visible = es[0].isIntersecting; }).observe(stage);
    }
    setInterval(function () {
      if (!visible || document.hidden) return;
      i = (i + 1) % tiles.length;
      focus(i);
      if (i % 3 === 2) {
        setTimeout(function () {
          play.classList.add("press");
          setTimeout(function () { play.classList.remove("press"); }, 240);
        }, 1100);
      }
    }, 2600);
    window.addEventListener("resize", function () { focus(i, true); });

    if (matchMedia("(pointer: fine)").matches) {
      stage.addEventListener("pointermove", function (e) {
        var r = stage.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
        dev.style.setProperty("--ty", (x * 12 - 6).toFixed(2) + "deg");
        dev.style.setProperty("--tx", (-y * 9 + 3).toFixed(2) + "deg");
      });
      stage.addEventListener("pointerleave", function () {
        dev.style.removeProperty("--ty"); dev.style.removeProperty("--tx");
      });
    }
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  function configured() { return Boolean(cfg.supabaseUrl && cfg.supabaseAnonKey); }
  function api(path) {
    return fetch(cfg.supabaseUrl.replace(/\/+$/, "") + "/rest/v1/" + path, {
      headers: { apikey: cfg.supabaseAnonKey, Authorization: "Bearer " + cfg.supabaseAnonKey }
    }).then(function (res) {
      if (!res.ok) throw new Error("The compatibility database answered " + res.status + ".");
      return res.json();
    });
  }
  var REPORT_COLUMNS = "id,created_at,game,steam_app_id,rating,issues,fps,description,madeira_version,device,ios,arch,settings,has_log";

  function notice(title, lines) {
    return h("div", { class: "notice" }, h("h3", { text: title }),
      (lines || []).map(function (l) { return h("p", null, l); }));
  }
  function notConnected() {
    return notice("Reports aren't connected yet", [
      "The compatibility database is still being set up. Once it is, games show up here as people report them from Madeira."
    ]);
  }
  function failed(err) {
    return notice("Couldn't load reports", [String(err && err.message || err), "Try again in a moment."]);
  }
  function skeletonCards(n) {
    var out = [];
    for (var i = 0; i < n; i++) {
      out.push(h("div", { class: "game-card skeleton", "aria-hidden": "true" },
        h("div", { class: "cover" }), h("div", { class: "bar" }), h("div", { class: "bar short" })));
    }
    return out;
  }

  function gameCard(g, i) {
    var v = verdict(g), n = Number(g.reports) || 0;
    return h("a", {
      class: "game-card reveal", href: "game.html?g=" + encodeURIComponent(g.key),
      style: "--d:" + Math.min(i || 0, 8)
    },
      cover(g.game, g.steam_app_id),
      h("div", { class: "info" },
        h("div", { class: "row" }, h("span", { class: "title", text: g.game }), ratingBadge(v)),
        distBar(g),
        h("span", { class: "sub" }, plural(n, "report") + " · " + ago(g.last_report))));
  }

  // ── Home: the most recently reported games ─────────────────────────────────

  function initHome() {
    var box = $("#recent");
    if (!box) return;
    if (!configured()) { box.replaceChildren(notConnected()); return; }
    box.replaceChildren(h("div", { class: "games-grid" }, skeletonCards(6)));
    api("game_summary?select=*&order=last_report.desc&limit=6").then(function (rows) {
      if (!rows.length) {
        box.replaceChildren(notice("No reports yet", [
          "Be the first: open a game's ⋯ menu in Madeira and choose Report Compatibility."
        ]));
        return;
      }
      box.replaceChildren(h("div", { class: "games-grid" }, rows.map(gameCard)));
      reveal(box);
    }).catch(function (e) { box.replaceChildren(failed(e)); });
  }

  // ── Compatibility list ─────────────────────────────────────────────────────

  function initGames() {
    var list = $("#games");
    if (!list) return;
    var input = $("#q"), sort = $("#sort"), count = $("#count");
    var toggles = Array.prototype.slice.call(document.querySelectorAll(".toggle[data-r]"));
    var all = [], active = {};

    function render() {
      var q = (input.value || "").trim().toLowerCase();
      var on = Object.keys(active).filter(function (k) { return active[k]; });
      var rows = all.filter(function (g) {
        if (q && String(g.game).toLowerCase().indexOf(q) < 0) return false;
        if (on.length && on.indexOf(verdict(g)) < 0) return false;
        return true;
      });
      if (sort.value === "reports") rows.sort(function (a, b) { return b.reports - a.reports || a.game.localeCompare(b.game); });
      else if (sort.value === "name") rows.sort(function (a, b) { return a.game.localeCompare(b.game); });
      else rows.sort(function (a, b) { return new Date(b.last_report) - new Date(a.last_report); });
      count.textContent = rows.length === all.length ? plural(all.length, "game") : rows.length + " of " + plural(all.length, "game");
      if (!rows.length) {
        list.replaceChildren(notice("Nothing matches", ["Try a different name, or clear the rating filters."]));
        return;
      }
      list.replaceChildren(h("div", { class: "games-grid" }, rows.map(gameCard)));
      reveal(list);
    }

    toggles.forEach(function (t) {
      t.addEventListener("click", function () {
        active[t.dataset.r] = !active[t.dataset.r];
        t.setAttribute("aria-pressed", active[t.dataset.r] ? "true" : "false");
        render();
      });
    });
    input.addEventListener("input", render);
    sort.addEventListener("change", render);

    if (!configured()) { count.textContent = ""; list.replaceChildren(notConnected()); return; }
    list.replaceChildren(h("div", { class: "games-grid" }, skeletonCards(9)));
    api("game_summary?select=*&order=last_report.desc&limit=2000").then(function (rows) {
      all = rows;
      if (!all.length) {
        count.textContent = "";
        list.replaceChildren(notice("No reports yet", [
          "Be the first: open a game's ⋯ menu in Madeira and choose Report Compatibility."
        ]));
        return;
      }
      render();
    }).catch(function (e) { list.replaceChildren(failed(e)); });
  }

  // ── One game ───────────────────────────────────────────────────────────────

  var ICON = {
    tag: "M3 12V4h8l9 9-8 8z M7.5 7.5h.01",
    phone: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z M11 18h2",
    chip: "M7 7h10v10H7z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4",
    screen: "M3 5h18v12H3z M8 21h8 M12 17v4",
    gauge: "M12 14l4-4 M4 18a9 9 0 1 1 16 0",
    bolt: "M13 2L4 14h7l-1 8 9-12h-7z",
    doc: "M6 2h8l4 4v16H6z M14 2v4h4 M9 13h6 M9 17h6"
  };
  function icon(name) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("fill", "none"); svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.8"); svg.setAttribute("stroke-linecap", "round"); svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    var p = document.createElementNS(ns, "path"); p.setAttribute("d", ICON[name]); svg.appendChild(p);
    return svg;
  }
  function meta(name, text) { return h("span", null, icon(name), text); }

  function reportCard(r, i) {
    var tags = [];
    (Array.isArray(r.issues) ? r.issues : []).forEach(function (k) { if (ISSUES[k]) tags.push(h("span", { class: "chip" }, ISSUES[k])); });
    if (FPS[r.fps]) tags.push(h("span", { class: "chip" }, FPS[r.fps]));

    var m = [], st = r.settings && typeof r.settings === "object" ? r.settings : {};
    if (r.madeira_version) m.push(meta("tag", "Madeira " + shortVersion(r.madeira_version)));
    if (r.device) m.push(meta("phone", deviceName(r.device) + (r.ios ? " · iOS " + r.ios : "")));
    if (r.arch) m.push(meta("chip", r.arch === "x86" ? "32-bit" : "64-bit"));
    if (typeof st.resolution === "string" && /^\d{2,5}x\d{2,5}$/.test(st.resolution)) m.push(meta("screen", st.resolution.replace("x", "×")));
    if (typeof st.frameCap === "string" && frameCapText(st.frameCap)) m.push(meta("gauge", frameCapText(st.frameCap)));
    if (st.x86MemoryOrdering === false) m.push(meta("bolt", "x86 memory-ordering off"));
    if (r.has_log) m.push(meta("doc", "Log sent"));

    var desc = String(r.description || "").trim();
    var when = h("time", { datetime: r.created_at, title: new Date(r.created_at).toLocaleString() }, ago(r.created_at));
    return h("article", { class: "report reveal", style: "--d:" + Math.min(i || 0, 6) },
      h("div", { class: "report-top" }, ratingBadge(r.rating), when),
      desc ? h("p", { class: "report-desc", text: desc }) : h("p", { class: "report-desc empty" }, "No description."),
      tags.length ? h("div", { class: "report-tags" }, tags) : null,
      m.length ? h("div", { class: "report-meta" }, m) : null);
  }

  function initGame() {
    var root = $("#game");
    if (!root) return;
    var key = new URLSearchParams(location.search).get("g") || "";
    if (!/^[a-z0-9-]{1,120}$/.test(key)) {
      root.replaceChildren(h("div", { class: "wrap section tight" },
        notice("No game picked", ["Choose a game from the ", h("a", { href: "games.html" }, "compatibility list"), "."])));
      return;
    }
    if (!configured()) { root.replaceChildren(h("div", { class: "wrap section tight" }, notConnected())); return; }

    var k = encodeURIComponent(key);
    Promise.all([
      api("game_summary?select=*&key=eq." + k),
      api("reports?select=" + REPORT_COLUMNS + "&game_key=eq." + k + "&order=created_at.desc&limit=200")
    ]).then(function (res) {
      var g = res[0][0], reports = res[1];
      if (!g) {
        root.replaceChildren(h("div", { class: "wrap section tight" },
          notice("No reports for this game yet", ["Open its ⋯ menu in Madeira and choose Report Compatibility to add the first."])));
        return;
      }
      document.title = g.game + " — Madeira compatibility";
      var v = verdict(g), devices = {}, newest = null;
      reports.forEach(function (r) { if (r.device) devices[r.device] = 1; if (!newest && r.madeira_version) newest = r.madeira_version; });

      var bg = headerUrl(g.steam_app_id);
      var backdrop = h("div", { class: "backdrop", style: bg ? "background-image:url('" + bg + "')" : placeholderStyle(g.game) });

      var hero = h("section", { class: "game-hero" }, backdrop,
        h("div", { class: "wrap" },
          h("div", { class: "reveal" }, cover(g.game, g.steam_app_id, true)),
          h("div", { class: "reveal", style: "--d:1" },
            h("a", { href: "games.html", class: "muted", style: "font-size:14px" }, "← All games"),
            h("h1", { text: g.game }),
            h("div", { class: "verdict-row" }, ratingBadge(v, true),
              v ? h("span", { class: "muted", style: "font-size:15px" }, RATING[v].blurb) : null),
            distBar(g, true),
            h("div", { class: "tier-key" }, RATINGS.map(function (r) {
              return h("span", { class: "r-" + r.id }, h("i"), r.label + " " + (Number(g[r.id]) || 0));
            })),
            h("div", { class: "stats" },
              h("div", null, h("b", null, String(g.reports)), h("span", null, Number(g.reports) === 1 ? "report" : "reports")),
              h("div", null, h("b", null, ago(g.last_report)), h("span", null, "latest report")),
              newest ? h("div", null, h("b", null, shortVersion(newest)), h("span", null, "newest Madeira build")) : null,
              h("div", null, h("b", null, String(Object.keys(devices).length || "—")), h("span", null, "devices"))))));

      var list = h("section", { class: "section tight" }, h("div", { class: "wrap" },
        h("div", { class: "section-head row" },
          h("div", null, h("span", { class: "eyebrow" }, "Reports"), h("h2", { class: "h2" }, "What people saw")),
          h("p", { class: "muted", style: "margin:0;max-width:30em;font-size:15px" },
            "Add yours from Madeira: open the game's ⋯ menu and choose Report Compatibility.")),
        h("div", { class: "reports" }, reports.map(reportCard))));

      root.replaceChildren(hero, list);
      reveal(root);
    }).catch(function (e) { root.replaceChildren(h("div", { class: "wrap section tight" }, failed(e))); });
  }

  // ── Boot ───────────────────────────────────────────────────────────────────

  function boot() {
    var y = $("#year"); if (y) y.textContent = new Date().getFullYear();
    initDevice();
    initHome();
    initGames();
    initGame();
    reveal();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
})();
