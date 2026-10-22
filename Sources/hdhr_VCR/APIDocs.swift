import Foundation

// Debug builds only (compiled out of release, like Settings → Developer): a machine- and human-readable description of the web API.
//   GET /api/help  → OpenAPI-style JSON built from `APIDocs.routes`
//   GET /api/docs  → a small self-contained page that lists every route with a Try-it form
// The table is the single source: the page builds itself from /api/help. APIDocsTests fails when a route literal in WebServer.swift is
// neither documented here nor on the internal list, so the table cannot silently drift.
#if DEBUG

struct APIParam {
    enum Place: String { case path, query }
    var name: String
    var place: Place
    var summary: String
    var example: String = ""
}

struct APIRoute {
    var method: String
    var path: String                  // "/api/now-airing/{deviceId}/{channel}" — {x} are path parameters
    var group: String
    var summary: String
    var params: [APIParam] = []
    var body: String? = nil           // example JSON request body (POST)
    var response: String = "JSON"
    /// Changes something (records, deletes, scans, edits): the page asks before sending.
    var changesState = false
    /// Streams or returns a non-JSON body: the page offers an Open link instead of a Try-it fetch.
    var streaming = false
}

enum APIDocs {
    static let internalPaths: Set<String> = ["/api/", "/api/transcode-source-relay", "/api/feed-local-relay"]   // plumbing between this app's own pieces

    static let routes: [APIRoute] = [
        // — Status
        APIRoute(method: "GET", path: "/api/ping", group: "Status", summary: "Liveness and build identity: ok, version stamp, release, build number."),
        APIRoute(method: "GET", path: "/api/events", group: "Status", summary: "Server-sent events: guide, recording and tuner changes pushed to the web guide.", response: "text/event-stream", streaming: true),
        APIRoute(method: "GET", path: "/api/now.json", group: "Status", summary: "What is recording and what is up next."),
        APIRoute(method: "GET", path: "/api/tuner-status.json", group: "Status", summary: "Per-tuner occupancy for Home Assistant (404 unless enabled in Settings → Sharing)."),
        APIRoute(method: "GET", path: "/api/hls-status", group: "Status", summary: "Is web streaming (Watch Now! in the browser) switched on?"),
        // — Guide
        APIRoute(method: "GET", path: "/api/guide.json", group: "Guide", summary: "The guide for the default tuner: channels, entries, devices, window."),
        APIRoute(method: "GET", path: "/api/guide.json/{deviceId}", group: "Guide", summary: "The same for one tuner.",
                 params: [APIParam(name: "deviceId", place: .path, summary: "HDHomeRun DeviceID", example: "105404BE")]),
        APIRoute(method: "GET", path: "/api/guide-refresh", group: "Guide", summary: "The grid and side data the web guide re-renders from after a change."),
        APIRoute(method: "GET", path: "/api/guide-search/{query}", group: "Guide", summary: "Search upcoming programs by title.",
                 params: [APIParam(name: "query", place: .path, summary: "text to find", example: "news")]),
        APIRoute(method: "GET", path: "/api/guide-detail/{deviceId}/{channel}/{winStart}/{winSec}", group: "Guide",
                 summary: "Synopsis, poster, episode and air date for every entry of one channel in a window.",
                 params: [APIParam(name: "deviceId", place: .path, summary: "DeviceID", example: "105404BE"),
                          APIParam(name: "channel", place: .path, summary: "GuideNumber", example: "4.1"),
                          APIParam(name: "winStart", place: .path, summary: "window start, epoch seconds", example: "0"),
                          APIParam(name: "winSec", place: .path, summary: "window length, seconds", example: "86400")]),
        APIRoute(method: "GET", path: "/api/now-airing/{deviceId}/{channel}", group: "Guide", summary: "The program airing now on a channel.",
                 params: [APIParam(name: "deviceId", place: .path, summary: "DeviceID", example: "105404BE"),
                          APIParam(name: "channel", place: .path, summary: "GuideNumber", example: "4.1")]),
        APIRoute(method: "GET", path: "/api/airings/{seriesId}", group: "Guide", summary: "Up to 4 upcoming airings of a series, across tuners.",
                 params: [APIParam(name: "seriesId", place: .path, summary: "SiliconDust SeriesID")]),
        // — Recording
        APIRoute(method: "POST", path: "/api/record", group: "Recording", summary: "Schedule a recording of a guide airing.",
                 body: #"{"deviceId":"105404BE","guideNumber":"4.1","startTime":1792519200,"showType":"single","transcode":"none","bonusTime":false}"#,
                 response: #"{"ok":true,…} or {"ok":false,"error":…}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/edit", group: "Recording", summary: "Change a scheduled show (type, pause, title, channel, length, days…).",
                 body: #"{"showId":"…","paused":true}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/delete", group: "Recording", summary: "Delete a show (stops it if recording). Give showId, or deviceId + guideNumber.",
                 body: #"{"showId":"…"}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/toggle-favorite", group: "Recording", summary: "Mark or unmark a channel as a favorite on the tuner.",
                 body: #"{"deviceId":"105404BE","guideNumber":"4.1"}"#, changesState: true),
        // — Signal
        APIRoute(method: "GET", path: "/api/signal", group: "Signal", summary: "Signal quality bucket per channel name."),
        APIRoute(method: "GET", path: "/api/signal-stats/{channelName}", group: "Signal", summary: "Signal history and stats for one channel.",
                 params: [APIParam(name: "channelName", place: .path, summary: "GuideName", example: "WCCO-DT")]),
        APIRoute(method: "POST", path: "/api/signal-scan", group: "Signal", summary: "Measure signal on idle tuners.",
                 body: #"{"force":false}"#, changesState: true),
        // — Over-the-air guide
        APIRoute(method: "POST", path: "/api/ota-scan", group: "Over-the-air guide",
                 summary: "Start a scan of the air, change the running scan's tuner count, or cancel it. Everything optional; \"rf\":[31] refreshes just those multiplexes.",
                 body: #"{"lineupOnly":true}"#, response: #"{"status":"…"}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/ota-scan", group: "Over-the-air guide", summary: "Allow the running scan N tuners.",
                 body: #"{"tuners":1}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/ota-scan", group: "Over-the-air guide", summary: "Cancel the running scan.",
                 body: #"{"cancel":true}"#, changesState: true),
        APIRoute(method: "GET", path: "/api/ota-status", group: "Over-the-air guide",
                 summary: "Scan progress: status, running, finished/total, multiplexes, channels, listings, tuners, secondsLeft (-1 unknown)."),
        APIRoute(method: "POST", path: "/api/live-start", group: "Playback",
                 summary: "Start live TV for a lineup or air-only channel in the browser (spools the tuner stream; play /api/hls/{id}/index.m3u8). Needs Web Streaming on and a free tuner.",
                 body: #"{"deviceId":"105404BE","guideNumber":"19.1"}"#, response: #"{"ok":true,"id":"live-…","title":"…"}"#, changesState: true),
        APIRoute(method: "POST", path: "/api/live-stop", group: "Playback",
                 summary: "A browser closed its live player; the tuner is freed when the last viewer of that channel is gone.",
                 body: #"{"id":"live-…"}"#, changesState: true),
        // — Playback
        APIRoute(method: "GET", path: "/api/watch-recording?show={showId}&start={offset}", group: "Playback",
                 summary: "Play a recording in progress from disk (the local relay).", response: "video/mp2t", streaming: true),
        APIRoute(method: "GET", path: "/api/hls/{showId}/{file}", group: "Playback", summary: "Web streaming playlist and segments for Watch Now! in the browser.",
                 response: "m3u8 / ts", streaming: true),
        // — Assets
        APIRoute(method: "GET", path: "/api/art?u={url}", group: "Assets", summary: "Cached/proxied poster or logo image.", response: "image", streaming: true),
        APIRoute(method: "GET", path: "/api/icon", group: "Assets", summary: "The app icon.", response: "image/png", streaming: true),
        // — Virtual tuner (only answers while something is recording)
        APIRoute(method: "GET", path: "/discover.json", group: "Virtual tuner (HDHomeRun protocol, outside /api/ on purpose)", summary: "HDHomeRun-style discovery for the recording relay (404 when not recording)."),
        APIRoute(method: "GET", path: "/lineup.json", group: "Virtual tuner (HDHomeRun protocol, outside /api/ on purpose)", summary: "The relay's lineup: the shows being recorded."),
        APIRoute(method: "GET", path: "/status.json", group: "Virtual tuner (HDHomeRun protocol, outside /api/ on purpose)", summary: "The relay's tuner status."),
        APIRoute(method: "GET", path: "/auto/v{channel}", group: "Virtual tuner (HDHomeRun protocol, outside /api/ on purpose)", summary: "Stream a recording in progress as if it were a tuner channel.", response: "video/mp2t", streaming: true),
    ]

    /// Every `"/api/…"`-style literal the documentation must account for (used by the drift test).
    static var documentedPaths: Set<String> {
        Set(routes.map { r in
            var p = r.path
            if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
            // Collapse "{x}" parameters to the literal prefix the router matches on.
            if let brace = p.firstIndex(of: "{") { p = String(p[..<brace]) }
            return p
        }).union(["/api/docs", "/api/help"])
    }

    static func helpJSON() -> Data {
        var paths: [String: [String: Any]] = [:]
        for r in routes {
            var op: [String: Any] = ["summary": r.summary, "tags": [r.group], "x-changesState": r.changesState,
                                     "responses": ["200": ["description": r.response]]]
            if !r.params.isEmpty {
                op["parameters"] = r.params.map { ["name": $0.name, "in": $0.place.rawValue, "description": $0.summary, "example": $0.example] }
            }
            if let body = r.body, let data = body.data(using: .utf8), let example = try? JSONSerialization.jsonObject(with: data) {
                op["requestBody"] = ["content": ["application/json": ["example": example]]]
            }
            // Same path can carry several POST examples (ota-scan): keep each under its own summary-keyed extension.
            let key = r.path
            var item = paths[key] ?? [:]
            if item[r.method.lowercased()] == nil { item[r.method.lowercased()] = op }
            else {
                var examples = (item["x-more-" + r.method.lowercased()] as? [[String: Any]]) ?? []
                examples.append(op)
                item["x-more-" + r.method.lowercased()] = examples
            }
            paths[key] = item
        }
        let doc: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "hdhrVCRplus web API", "version": appVersion,
                     "description": "LAN-only. POST bodies are JSON and must send Content-Type: application/json. Debug builds only. Every route is under /api/ except the virtual tuner group, which must sit at the root to look like an HDHomeRun to other instances and clients."],
            "servers": [["url": "/"]],
            "paths": paths,
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    static let pageHTML: String = #"""
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>hdhrVCRplus API</title>
    <style>
    :root{--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--card:#f5f5f7;--line:#d2d2d7;--ac:#0a64d8;--get:#1a7f37;--post:#b35900;--bad:#c0392b}
    @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f2f2f7;--mut:#98989d;--card:#2c2c2e;--line:#3a3a3c;--ac:#4c9aff;--get:#4cc26b;--post:#ffb454;--bad:#ff6b6b}}
    body{margin:0;background:var(--bg);color:var(--fg);font:14px -apple-system,BlinkMacSystemFont,sans-serif}
    main{max-width:880px;margin:0 auto;padding:16px}
    h1{font-size:1.3rem;margin:.2em 0}h2{font-size:1rem;margin:22px 0 8px;color:var(--mut);text-transform:uppercase;letter-spacing:.06em}
    .note{color:var(--mut);font-size:.85rem}
    .route{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:8px 0}
    .route>summary{cursor:pointer;padding:9px 12px;display:flex;gap:10px;align-items:baseline;list-style:none}
    .m{font-weight:700;font-size:.75rem;min-width:42px}.m.GET{color:var(--get)}.m.POST{color:var(--post)}
    .p{font-family:ui-monospace,Menlo,monospace;font-size:.85rem;word-break:break-all}.s{color:var(--mut);font-size:.82rem}
    .body{padding:4px 12px 12px;border-top:1px solid var(--line)}
    label{display:block;font-size:.78rem;color:var(--mut);margin:8px 0 2px}
    input,textarea{width:100%;box-sizing:border-box;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px 8px;font:12px ui-monospace,Menlo,monospace}
    textarea{min-height:70px}
    button{background:var(--ac);color:#fff;border:0;border-radius:6px;padding:6px 14px;font-weight:600;margin-top:10px;cursor:pointer}
    button.danger{background:var(--bad)}a.open{margin-left:12px;color:var(--ac)}
    pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px;overflow:auto;max-height:340px;font:12px ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-all}
    .st{font-size:.8rem;margin-top:8px}.ok{color:var(--get)}.err{color:var(--bad)}
    </style></head><body><main>
    <h1>hdhrVCRplus web API</h1>
    <p class="note">Debug build. Every route here is also available to anything on your LAN. Raw spec: <a href="/api/help">/api/help</a>. Routes marked ⚠ change state and ask first.</p>
    <div id="root">Loading…</div></main>
    <script>
    var esc=function(s){return String(s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});};
    fetch('/api/help').then(function(r){return r.json();}).then(function(spec){
      var groups={},order=[];
      Object.keys(spec.paths).forEach(function(path){
        var item=spec.paths[path];
        Object.keys(item).forEach(function(k){
          var ops=k.indexOf('x-more-')===0?item[k].map(function(o){return[k.slice(7),o];}):(k.indexOf('x-')===0?[]:[[k,item[k]]]);
          ops.forEach(function(mo){var op=mo[1],g=op.tags[0];if(!groups[g]){groups[g]=[];order.push(g);}groups[g].push({method:mo[0].toUpperCase(),path:path,op:op});});
        });
      });
      var html='';
      order.forEach(function(g){
        html+='<h2>'+esc(g)+'</h2>';
        groups[g].forEach(function(r,i){
          var id=g.replace(/\W/g,'')+i,streaming=/stream|video|image|m3u8/.test(JSON.stringify(r.op.responses)),danger=r.op['x-changesState'];
          html+='<details class="route" id="'+id+'" data-method="'+r.method+'" data-path="'+esc(r.path)+'" data-danger="'+(danger?1:0)+'"><summary><span class="m '+r.method+'">'+r.method+'</span><span class="p">'+esc(r.path)+'</span><span class="s">'+(danger?'⚠ ':'')+esc(r.op.summary)+'</span></summary><div class="body">';
          (r.op.parameters||[]).forEach(function(p){html+='<label>'+esc(p.name)+' ('+p['in']+') — '+esc(p.description)+'</label><input data-param="'+esc(p.name)+'" value="'+esc(p.example||'')+'">';});
          if(r.op.requestBody){html+='<label>JSON body</label><textarea data-body>'+esc(JSON.stringify(r.op.requestBody.content['application/json'].example,null,2))+'</textarea>';}
          if(streaming){html+='<a class="open" href="'+esc(r.path.replace(/\{[^}]*\}/g,''))+'" target="_blank">Open</a> <span class="s">streams or returns a non-JSON body</span>';}
          else{html+='<button class="'+(danger?'danger':'')+'" onclick="tryIt(\''+id+'\')">Try it</button>';}
          html+='<div class="st" data-status></div><pre data-out style="display:none"></pre></div></details>';
        });
      });
      document.getElementById('root').innerHTML=html;
    });
    function tryIt(id){
      var el=document.getElementById(id),method=el.dataset.method,path=el.dataset.path,danger=el.dataset.danger==='1';
      el.querySelectorAll('[data-param]').forEach(function(i){path=path.replace('{'+i.dataset.param+'}',encodeURIComponent(i.value));});
      var ta=el.querySelector('[data-body]'),body=ta?ta.value:null;
      if(danger&&!confirm(method+' '+path+'\n\nThis changes state on the app. Send it?'))return;
      var st=el.querySelector('[data-status]'),out=el.querySelector('[data-out]'),t0=Date.now();
      st.textContent='…';st.className='st';
      var opts={method:method};if(method==='POST'){opts.headers={'Content-Type':'application/json'};opts.body=body||'{}';}
      fetch(path,opts).then(function(r){return r.text().then(function(t){
        st.textContent=r.status+' '+r.statusText+' · '+(Date.now()-t0)+' ms · '+t.length+' bytes';st.className='st '+(r.ok?'ok':'err');
        try{t=JSON.stringify(JSON.parse(t),null,2);}catch(e){}
        out.style.display='block';out.textContent=t.length>200000?t.slice(0,200000)+'\n… (truncated)':t;
      });}).catch(function(e){st.textContent='Failed: '+e;st.className='st err';});
    }
    </script></body></html>
    """#
}

#endif
