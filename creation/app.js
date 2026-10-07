/* timeline — a self-contained r1 creation.
 *
 * Keeps its own accumulated timeline in the creation's on-device storage and,
 * at most once per day, asks OS3 for the day-cards it does not have yet.
 *
 * Two ways to find the endpoint:
 *   - a small stable pointer (a gist) that tracks the owner's rotating tunnel
 *     hostname (the pre-configured state), or
 *   - an endpoint the owner pastes in on the pairing screen.
 * A per-owner pairing token is kept in the creation's secure storage and sent
 * as an Authorization header on every fetch. Only the *transport* is public;
 * the timeline data stays on the device and on the owner's own machine.
 */

(function () {
  "use strict";

  var VERSION = "timeline-2-pairing";

  // Pre-configured pointer to the current endpoint (public gist, raw).
  // Kept so the existing owner's setup keeps working untouched.
  var DEFAULT_POINTER_URL = "";
  // Fallback if the pointer cannot be read.
  var FALLBACK_ENDPOINT = "";

  var STORE_KEY = "timeline.v1";
  var CONFIG_KEY = "timeline.config.v1";
  var TOKEN_KEY = "timeline.token.v1";
  var CARD_H = 64;

  var els = {
    hdrDate: document.getElementById("hdr-date"),
    hdrDot: document.getElementById("hdr-dot"),
    body: document.getElementById("body"),
    track: document.getElementById("track"),
    cards: document.getElementById("cards"),
    detail: document.getElementById("detail"),
    detailDate: document.getElementById("detail-date"),
    detailText: document.getElementById("detail-text"),
    empty: document.getElementById("empty"),
    hint: document.getElementById("hint"),
    hdrMenu: document.getElementById("hdr-menu"),
    pair: document.getElementById("pair"),
    pairHdr: document.getElementById("pair-hdr"),
    pairSub: document.getElementById("pair-sub"),
    inEndpoint: document.getElementById("in-endpoint"),
    inToken: document.getElementById("in-token"),
    pairStatus: document.getElementById("pair-status"),
    btnTest: document.getElementById("btn-test"),
    btnSave: document.getElementById("btn-save"),
    btnBack: document.getElementById("btn-back"),
    fldEndpoint: document.getElementById("fld-endpoint"),
    fldToken: document.getElementById("fld-token"),
  };

  var state = {
    cards: [], // oldest-first; each {date, summary, detail, tags}
    focus: 0,
    expanded: false,
    lastRefreshDay: null, // UTC YYYY-MM-DD of the last successful refresh
    lastSyncAt: null, // ISO of the last successful refresh
    loading: true,
    error: null,
    // config
    endpoint: "", // explicit endpoint pasted by the owner ("" = use pointer)
    pointerUrl: DEFAULT_POINTER_URL,
    token: "", // pairing token (kept in secure storage)
    tokenInSecure: false,
    // pairing screen
    pairOpen: false,
    pairFocus: 0,
    pairBusy: false,
  };

  /* ------------------------------------------------------------------ util */

  function todayUTC() {
    return new Date().toISOString().slice(0, 10);
  }

  function fmtDate(iso) {
    var p = String(iso).slice(0, 10).split("-");
    if (p.length !== 3) return String(iso);
    var months = [
      "jan", "feb", "mar", "apr", "may", "jun",
      "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    var m = parseInt(p[1], 10) - 1;
    return parseInt(p[2], 10) + " " + (months[m] || p[1]);
  }

  function ageLabel() {
    if (!state.lastSyncAt) return "not synced";
    var mins = Math.floor((Date.now() - Date.parse(state.lastSyncAt)) / 60000);
    if (mins < 1) return "live";
    if (mins < 60) return mins + "m old";
    var hrs = Math.floor(mins / 60);
    if (hrs < 24) return hrs + "h old";
    return Math.floor(hrs / 24) + "d old";
  }

  function normaliseEndpoint(url) {
    return String(url || "").trim().replace(/\/+$/, "");
  }

  /* --------------------------------------------------------------- storage */

  function hasCreationStorage() {
    return (
      typeof window.creationStorage !== "undefined" &&
      window.creationStorage &&
      window.creationStorage.plain
    );
  }

  function hasSecureStorage() {
    return (
      typeof window.creationStorage !== "undefined" &&
      window.creationStorage &&
      window.creationStorage.secure
    );
  }

  function b64encode(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }
  function b64decode(str) {
    return decodeURIComponent(escape(atob(str)));
  }

  function plainGet(key) {
    try {
      if (hasCreationStorage()) {
        return window.creationStorage.plain.getItem(key).then(function (v) {
          return v || null;
        });
      }
      return Promise.resolve(window.localStorage.getItem(key) || null);
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  function plainSet(key, val) {
    try {
      if (hasCreationStorage()) {
        return window.creationStorage.plain.setItem(key, val);
      }
      window.localStorage.setItem(key, val);
    } catch (e) {
      /* storage full or unavailable — keep going with in-memory state */
    }
    return Promise.resolve();
  }

  function secureGet(key) {
    try {
      if (hasSecureStorage()) {
        return window.creationStorage.secure.getItem(key).then(function (v) {
          return v || null;
        });
      }
      return Promise.resolve(window.localStorage.getItem(key) || null);
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  function secureSet(key, val) {
    try {
      if (hasSecureStorage()) {
        return window.creationStorage.secure.setItem(key, val);
      }
      window.localStorage.setItem(key, val);
    } catch (e) {
      /* keep going */
    }
    return Promise.resolve();
  }

  /* ---------------------------------------------------------------- config */

  function loadConfig() {
    return plainGet(CONFIG_KEY).then(function (v) {
      var cfg = null;
      if (v) {
        try {
          cfg = JSON.parse(b64decode(v));
        } catch (e) {
          cfg = null;
        }
      }
      if (!cfg || typeof cfg !== "object") cfg = {};
      state.endpoint = typeof cfg.endpoint === "string" ? cfg.endpoint : "";
      state.pointerUrl =
        typeof cfg.pointerUrl === "string" ? cfg.pointerUrl : DEFAULT_POINTER_URL;
      return secureGet(TOKEN_KEY).then(function (t) {
        if (t) {
          try {
            state.token = b64decode(t);
            state.tokenInSecure = hasSecureStorage();
          } catch (e) {
            state.token = "";
          }
        }
        return null;
      });
    });
  }

  function saveConfig() {
    var cfg = { endpoint: state.endpoint, pointerUrl: state.pointerUrl };
    return plainSet(CONFIG_KEY, b64encode(JSON.stringify(cfg)));
  }

  function saveToken(tok) {
    state.token = tok || "";
    state.tokenInSecure = hasSecureStorage();
    if (!tok) return Promise.resolve();
    return secureSet(TOKEN_KEY, b64encode(tok));
  }

  function isConfigured() {
    return !!(state.endpoint || state.pointerUrl);
  }

  /* ---------------------------------------------------------------- network */

  function authHeaders() {
    var h = {};
    if (state.token) h.Authorization = "Bearer " + state.token;
    return h;
  }

  function fetchJSON(url, timeoutMs, headers) {
    return new Promise(function (resolve, reject) {
      var done = false;
      var ctrl =
        typeof AbortController !== "undefined" ? new AbortController() : null;
      var timer = setTimeout(function () {
        if (done) return;
        done = true;
        if (ctrl) ctrl.abort();
        reject(new Error("timeout"));
      }, timeoutMs || 12000);

      var opts = { mode: "cors" };
      if (ctrl) opts.signal = ctrl.signal;
      if (headers) opts.headers = headers;

      fetch(url, opts)
        .then(function (r) {
          if (!r.ok) throw new Error("http " + r.status);
          return r.json();
        })
        .then(function (j) {
          if (done) return;
          done = true;
          clearTimeout(timer);
          resolve(j);
        })
        .catch(function (e) {
          if (done) return;
          done = true;
          clearTimeout(timer);
          reject(e);
        });
    });
  }

  function resolveEndpoint() {
    if (state.endpoint) return Promise.resolve(state.endpoint);
    if (!state.pointerUrl) return Promise.resolve(FALLBACK_ENDPOINT);
    var bust = state.pointerUrl + (state.pointerUrl.indexOf("?") < 0 ? "?" : "&") + "t=" + Date.now();
    return fetchJSON(bust, 8000)
      .then(function (j) {
        if (j && typeof j.endpoint === "string" && j.endpoint) return j.endpoint;
        throw new Error("bad pointer");
      })
      .catch(function () {
        return FALLBACK_ENDPOINT;
      });
  }

  function latestStoredDate() {
    if (!state.cards.length) return null;
    return state.cards[state.cards.length - 1].date;
  }

  /* ---------------------------------------------------------------- refresh */

  function shouldRefresh() {
    return state.lastRefreshDay !== todayUTC();
  }

  function refresh() {
    return resolveEndpoint().then(function (endpoint) {
      var since = latestStoredDate();
      var url = endpoint.replace(/\/+$/, "") + "/timeline.json";
      if (since) url += "?since=" + encodeURIComponent(since);
      else url += "?t=" + Date.now();

      return fetchJSON(url, 15000, authHeaders()).then(function (j) {
        if (!j || j.ok !== true) throw new Error("bad feed");
        var incoming = Array.isArray(j.cards) ? j.cards : [];
        mergeCards(incoming);
        state.lastRefreshDay = todayUTC();
        state.lastSyncAt = new Date().toISOString();
        state.error = null;
        return saveState();
      });
    });
  }

  function mergeCards(incoming) {
    var today = todayUTC();
    var byDate = {};
    state.cards.forEach(function (c) {
      byDate[c.date] = c;
    });
    incoming.forEach(function (c) {
      if (!c || !c.date) return;
      // Only completed days ever enter the timeline.
      if (String(c.date).slice(0, 10) >= today) return;
      byDate[String(c.date).slice(0, 10)] = {
        date: String(c.date).slice(0, 10),
        summary: c.summary || "",
        detail: c.detail || c.summary || "",
        tags: c.tags || [],
      };
    });
    state.cards = Object.keys(byDate)
      .sort()
      .map(function (k) {
        return byDate[k];
      });
  }

  function saveState() {
    var payload = {
      cards: state.cards,
      lastRefreshDay: state.lastRefreshDay,
      lastSyncAt: state.lastSyncAt,
    };
    return plainSet(STORE_KEY, b64encode(JSON.stringify(payload)));
  }

  function loadState() {
    return plainGet(STORE_KEY).then(function (v) {
      if (!v) return null;
      try {
        return JSON.parse(b64decode(v));
      } catch (e) {
        return null;
      }
    });
  }

  /* ----------------------------------------------------------------- render */

  function render() {
    els.cards.innerHTML = "";

    if (!state.cards.length) {
      showEmpty();
      return;
    }
    hideEmpty();

    var frag = document.createDocumentFragment();
    state.cards.forEach(function (c, i) {
      var el = document.createElement("div");
      el.className = "card";
      el.setAttribute("data-i", String(i));

      var node = document.createElement("span");
      node.className = "node";

      var d = document.createElement("div");
      d.className = "date";
      d.textContent = fmtDate(c.date);

      var s = document.createElement("div");
      s.className = "sum";
      s.textContent = c.summary;

      el.appendChild(node);
      el.appendChild(d);
      el.appendChild(s);
      el.addEventListener("click", function () {
        state.focus = i;
        applyFocus();
        toggleDetail();
      });
      frag.appendChild(el);
    });
    els.cards.appendChild(frag);

    if (state.focus >= state.cards.length) state.focus = state.cards.length - 1;
    if (state.focus < 0) state.focus = 0;
    applyFocus();
    renderDetail();
  }

  function bodyHeight() {
    return els.body.clientHeight || 222;
  }

  function applyFocus() {
    var kids = els.cards.children;
    for (var i = 0; i < kids.length; i++) {
      if (i === state.focus) kids[i].classList.add("focus");
      else kids[i].classList.remove("focus");
    }
    var centre = (bodyHeight() - CARD_H) / 2;
    var y = centre - state.focus * CARD_H;
    els.track.style.transform = "translateY(" + y + "px)";

    var c = state.cards[state.focus];
    els.hdrDate.textContent = c ? fmtDate(c.date) : "—";
    els.hdrDot.className =
      "dot " + (state.lastRefreshDay === todayUTC() ? "live" : "stale");
  }

  function renderDetail() {
    var c = state.cards[state.focus];
    if (!c) return;
    els.detailDate.textContent = fmtDate(c.date);
    els.detailText.textContent = c.detail || c.summary || "";
  }

  function toggleDetail() {
    state.expanded = !state.expanded;
    if (state.expanded) {
      renderDetail();
      els.detail.classList.remove("hidden");
      els.hint.textContent = "wheel: scroll · button: back";
    } else {
      els.detail.classList.add("hidden");
      els.hint.textContent = "wheel: time · button: open";
    }
  }

  function showEmpty() {
    els.empty.classList.remove("hidden");
    if (!isConfigured()) {
      els.empty.innerHTML =
        '<div class="big">not connected</div>' +
        "<div>pair this r1 with your OS3 endpoint</div>" +
        '<div class="retry" id="connect">connect</div>';
      var cbtn = document.getElementById("connect");
      if (cbtn)
        cbtn.addEventListener("click", function () {
          openPair();
        });
      els.hdrDot.className = "dot stale";
      els.hdrDate.textContent = "—";
      return;
    }
    if (state.error) {
      els.empty.innerHTML =
        '<div class="big">couldn\'t reach OS3</div>' +
        "<div>" +
        (state.lastSyncAt
          ? "showing nothing yet · last synced " + ageLabel()
          : "no timeline yet") +
        "</div>" +
        '<div class="retry" id="retry">retry</div>';
      var r = document.getElementById("retry");
      if (r)
        r.addEventListener("click", function () {
          boot(true);
        });
      els.hdrDot.className = "dot stale";
      els.hdrDate.textContent = "—";
    } else {
      els.empty.innerHTML =
        '<div class="big">_ _ nothing here _ _</div>' +
        "<div>the timeline fills in as days complete</div>" +
        '<div class="retry" id="connect">re-pair</div>';
      var c2 = document.getElementById("connect");
      if (c2)
        c2.addEventListener("click", function () {
          openPair();
        });
    }
  }

  function hideEmpty() {
    els.empty.classList.add("hidden");
  }

  /* ---------------------------------------------------------------- pairing */

  var pairFocusables = [
    els.inEndpoint,
    els.inToken,
    els.btnTest,
    els.btnSave,
    els.btnBack,
  ];

  function openPair() {
    state.pairOpen = true;
    state.pairFocus = 0;
    els.pair.classList.remove("hidden");
    els.inEndpoint.value = state.endpoint || "";
    els.inToken.value = state.token || "";
    setPairStatus(
      state.endpoint
        ? "endpoint set · edit and save to re-pair"
        : "paste your OS3 endpoint and pairing token",
      ""
    );
    applyPairFocus();
  }

  function closePair() {
    state.pairOpen = false;
    els.pair.classList.add("hidden");
    if (typeof els.inEndpoint.blur === "function") els.inEndpoint.blur();
    if (typeof els.inToken.blur === "function") els.inToken.blur();
    render();
  }

  function applyPairFocus() {
    for (var i = 0; i < pairFocusables.length; i++) {
      var el = pairFocusables[i];
      var wrap = i === 0 ? els.fldEndpoint : i === 1 ? els.fldToken : null;
      if (i === state.pairFocus) {
        el.classList.add("focus");
        if (wrap) wrap.classList.add("focus");
      } else {
        el.classList.remove("focus");
        if (wrap) wrap.classList.remove("focus");
      }
    }
  }

  function setPairStatus(text, cls) {
    els.pairStatus.textContent = text;
    els.pairStatus.className = "pair-status" + (cls ? " " + cls : "");
  }

  function pairTest() {
    if (state.pairBusy) return;
    var endpoint = normaliseEndpoint(els.inEndpoint.value);
    var token = els.inToken.value.trim();
    if (!endpoint) {
      setPairStatus("enter an endpoint first", "err");
      return;
    }
    state.pairBusy = true;
    setPairStatus("testing…", "");
    var headers = {};
    if (token) headers.Authorization = "Bearer " + token;

    var t0 = Date.now();
    fetchJSON(endpoint + "/health", 12000, headers)
      .then(function (j) {
        var ms = Date.now() - t0;
        if (!j || j.ok !== true) throw new Error("bad response");
        var line = "connected · " + ms + "ms";
        if (typeof j.cardCount === "number")
          line += " · " + j.cardCount + " cards";
        if (j.generatedAt) line += "\nfeed built " + String(j.generatedAt).slice(0, 16).replace("T", " ");
        setPairStatus(line, "ok");
      })
      .catch(function (e) {
        var msg = e && e.message ? e.message : String(e);
        var hint = "";
        if (msg.indexOf("http 401") >= 0 || msg.indexOf("http 403") >= 0)
          hint = " · check the token";
        else if (msg === "timeout")
          hint = " · endpoint did not answer";
        else if (msg.indexOf("Failed to fetch") >= 0 || msg.indexOf("NetworkError") >= 0)
          hint = " · unreachable or CORS blocked";
        setPairStatus("failed: " + msg + hint, "err");
      })
      .then(function () {
        state.pairBusy = false;
      });
  }

  function pairSave() {
    if (state.pairBusy) return;
    var endpoint = normaliseEndpoint(els.inEndpoint.value);
    var token = els.inToken.value.trim();
    state.endpoint = endpoint;
    // Saving a new endpoint must not wipe the accumulated timeline.
    saveConfig()
      .then(function () {
        return saveToken(token);
      })
      .then(function () {
        return saveState();
      })
      .then(function () {
        setPairStatus("saved · syncing…", "ok");
        return refresh()
          .then(function () {
            state.focus = state.cards.length ? state.cards.length - 1 : 0;
            state.pairBusy = false;
            closePair();
          })
          .catch(function (e) {
            state.pairBusy = false;
            setPairStatus(
              "saved, but sync failed: " + (e && e.message ? e.message : String(e)),
              "err"
            );
          });
      });
  }

  /* ------------------------------------------------------------------ input */

  window.addEventListener("scrollUp", function () {
    if (state.pairOpen) {
      if (state.pairFocus > 0) {
        state.pairFocus--;
        applyPairFocus();
      }
      return;
    }
    if (state.expanded) {
      els.detailText.scrollTop -= 40;
      return;
    }
    if (state.focus > 0) {
      state.focus--;
      applyFocus();
    }
  });

  window.addEventListener("scrollDown", function () {
    if (state.pairOpen) {
      if (state.pairFocus < pairFocusables.length - 1) {
        state.pairFocus++;
        applyPairFocus();
      }
      return;
    }
    if (state.expanded) {
      els.detailText.scrollTop += 40;
      return;
    }
    if (state.focus < state.cards.length - 1) {
      state.focus++;
      applyFocus();
    }
  });

  window.addEventListener("sideClick", function () {
    if (state.pairOpen) {
      var el = pairFocusables[state.pairFocus];
      if (el === els.inEndpoint || el === els.inToken) {
        if (typeof el.focus === "function") el.focus();
      } else if (el && typeof el.click === "function") {
        el.click();
      }
      return;
    }
    if (state.cards.length) toggleDetail();
  });

  // Hold the side button on the timeline to re-open the pairing screen.
  window.addEventListener("longPressStart", function () {
    if (!state.pairOpen) openPair();
  });

  els.btnTest.addEventListener("click", pairTest);
  els.btnSave.addEventListener("click", pairSave);
  els.btnBack.addEventListener("click", closePair);
  if (els.hdrMenu) els.hdrMenu.addEventListener("click", openPair);

  /* ------------------------------------------------------------------- boot */

  function boot(force) {
    state.loading = true;
    state.error = null;
    if (!state.cards.length) showEmpty();

    loadConfig()
      .then(function () {
        return loadState();
      })
      .then(function (saved) {
        if (saved) {
          state.cards = Array.isArray(saved.cards) ? saved.cards : [];
          state.lastRefreshDay = saved.lastRefreshDay || null;
          state.lastSyncAt = saved.lastSyncAt || null;
        }
        state.focus = state.cards.length ? state.cards.length - 1 : 0;
        render();

        if (!isConfigured()) {
          state.loading = false;
          openPair();
          return;
        }

        if (!force && !shouldRefresh()) {
          // Already refreshed today: show the stored copy, no network call.
          state.loading = false;
          return;
        }
        return refresh()
          .then(function () {
            state.focus = state.cards.length ? state.cards.length - 1 : 0;
            render();
          })
          .catch(function (e) {
            state.error = e;
            if (!state.cards.length) showEmpty();
            else {
              els.hdrDot.className = "dot stale";
            }
          })
          .then(function () {
            state.loading = false;
          });
      })
      .catch(function () {
        state.loading = false;
        state.error = new Error("storage");
        showEmpty();
      });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      boot(false);
    });
  } else {
    boot(false);
  }
})();
