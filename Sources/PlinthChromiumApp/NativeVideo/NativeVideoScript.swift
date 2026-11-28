import Foundation

/// The page side of native video. Plinth's Chromium is built without H.264 and AAC (CEF's free builds leave
/// out the patent-licensed codecs), so videos in those formats fail with "format not supported". This script
/// finds them and reports each one's file and place on screen; Plinth then draws the video with macOS's own
/// player (AVFoundation) over that spot (NativeVideoController.swift). It does nothing when the engine can
/// play H.264 itself. The renderer helper runs it in every http(s) frame and hands it a private `post`.
enum NativeVideoScript {
    static let source = #"""
(function (post) {
  'use strict';
  // Main frame only: positions are measured against the page's own viewport.
  if (window.top !== window || window.__plinthNativeVideo) return;
  try { Object.defineProperty(window, '__plinthNativeVideo', { value: true }); } catch (e) { return; }
  var Q = String.fromCharCode(34);
  try {
    if (window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs=' + Q + 'avc1.42E01E' + Q)) return;
  } catch (e) {}
  post({ type: 'reset' });

  // Files the page's own API responses list for its videos (X lists every variant), by media id.
  var files = new Map();
  var ID = /\/(?:ext_tw_video|amplify_video|ext_tw_video_thumb|amplify_video_thumb)\/(\d+)\//;
  function mediaId(u) { var m = ID.exec(u || ''); return m ? m[1] : null; }
  function remember(variants, poster) {
    var best = null;
    for (var i = 0; i < variants.length; i++) {
      var v = variants[i];
      if (!v || typeof v.url !== 'string') continue;
      var type = String(v.content_type || v.contentType || '');
      if (type.indexOf('mp4') < 0 && !/\.mp4(\?|$)/.test(v.url)) continue;
      var rate = v.bitrate || v.bit_rate || 0;
      if (!best || rate > best.rate) best = { url: v.url, rate: rate };
    }
    if (!best) return;
    var id = mediaId(best.url) || mediaId(poster);
    if (id) files.set(id, best.url);
  }
  function walk(o, depth) {
    if (!o || typeof o !== 'object' || depth > 48) return;
    if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) walk(o[i], depth + 1); return; }
    if (o.video_info && Array.isArray(o.video_info.variants)) remember(o.video_info.variants, o.media_url_https);
    for (var k in o) {
      if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
      var v = o[k];
      if (v && typeof v === 'object') walk(v, depth + 1);
    }
  }
  function scan(text) {
    if (typeof text !== 'string' || text.indexOf('video_info') < 0) return;
    try { walk(JSON.parse(text), 0); } catch (e) {}
  }
  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function () {
      var result = originalFetch.apply(this, arguments);
      result.then(function (r) {
        try {
          if ((r.headers.get('content-type') || '').indexOf('json') >= 0) r.clone().text().then(scan, function () {});
        } catch (e) {}
      }, function () {});
      return result;
    };
  }
  var originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', function () {
      try {
        if (this.responseType === '' || this.responseType === 'text') scan(this.responseText);
        else if (this.responseType === 'json') walk(this.response, 0);
      } catch (e) {}
    });
    return originalSend.apply(this, arguments);
  };

  // The file macOS should play for a video this engine can't, or null.
  function fileFor(v) {
    var src = v.currentSrc || v.src || '';
    if (!src) { var s = v.querySelector('source[src]'); if (s) src = s.src; }
    if (/^blob:/i.test(src)) {
      var id = mediaId(v.poster);
      return id && files.has(id) ? files.get(id) : null;
    }
    if (!/^https?:/i.test(src)) return null;
    var failed = (v.error && v.error.code === 4) || v.networkState === 3;
    return failed ? src : null;
  }
  // The rounded corners of the box the video sits in.
  function radiusFor(v) {
    var e = v;
    for (var i = 0; i < 8 && e && e !== document.body; i++, e = e.parentElement) {
      var r = parseFloat(getComputedStyle(e).borderTopLeftRadius) || 0;
      if (r > 0) return r;
    }
    return 0;
  }

  var tracked = new Map();
  var nextId = 1;
  var autoplaySite = /(^|\.)(x|twitter)\.com$/i.test(location.hostname);
  function report() {
    var seen = new Set();
    var videos = document.getElementsByTagName('video');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      var url = fileFor(v);
      if (!url) continue;
      seen.add(v);
      var t = tracked.get(v);
      if (!t || t.url !== url) {
        if (t) post({ type: 'gone', id: t.id });
        t = { id: nextId++, url: url, last: '' };
        tracked.set(v, t);
      }
      var r = v.getBoundingClientRect();
      var cs = getComputedStyle(v);
      var hidden = cs.visibility === 'hidden' || cs.display === 'none' || document.visibilityState !== 'visible';
      var m = {
        type: 'video', id: t.id, url: url, page: location.href,
        x: r.left, y: r.top, w: r.width, h: r.height,
        vw: document.documentElement.clientWidth || innerWidth, vh: innerHeight,
        radius: radiusFor(v), fill: cs.objectFit === 'cover', hidden: hidden,
        muted: v.muted || autoplaySite, loop: v.loop || /\/tweet_video\//.test(url),
        autoplay: v.autoplay || autoplaySite
      };
      var key = [m.x, m.y, m.w, m.h, m.vw, m.vh, m.radius, m.hidden].map(Math.round).join(',');
      if (key !== t.last) { t.last = key; post(m); }
    }
    tracked.forEach(function (t, v) {
      if (!seen.has(v)) { post({ type: 'gone', id: t.id }); tracked.delete(v); }
    });
  }
  // Every frame while native videos are on the page, so they follow scrolling; otherwise twice a second.
  var scheduled = false;
  function tick() {
    scheduled = false;
    try { report(); } catch (e) {}
    if (tracked.size) { scheduled = true; requestAnimationFrame(tick); }
  }
  function soon() { if (!scheduled) { scheduled = true; requestAnimationFrame(tick); } }
  setInterval(soon, 500);
  document.addEventListener('error', soon, true);
  document.addEventListener('visibilitychange', soon);
  addEventListener('pagehide', function () { tracked.forEach(function (t) { post({ type: 'gone', id: t.id }); }); tracked.clear(); });
})
"""#
}
