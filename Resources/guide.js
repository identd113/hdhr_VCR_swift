{{TUNER_JS}}
{{RECS_BY_DEV_JS}}
var _d='',_n='',_s=0,_e=0,_ser='',_genre='',_title='',_poster='',_logo='',_chname='';
var _delConfirmAction=null;   // pending action for #del-confirm-modal, set by showDeleteConfirm()
// Escapes '"' too (not just &<>) — needed by any call site that interpolates the result into an
// HTML attribute (e.g. the search dropdown's <img src="...">), not just text content. Safe for
// existing text-content call sites too: &quot; decodes back to a literal '"' there as well.
function hej(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
// Shared POST helper — every mutating action (record/edit/delete/toggle-favorite) posts
// JSON and gets JSON back; callers still handle their own response/error logic (which
// differs enough per action — e.g. confirmRecord's r.text() fallback on a non-JSON error
// body — that only the fetch-construction boilerplate is shared here, not the response path).
function postJSON(url,payload){
  return fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
}
// Theme: .lm class on <html> = light mode active
var _mq=window.matchMedia('(prefers-color-scheme:light)');
var _themeMode='dark';
function applyLM(on){document.documentElement.classList.toggle('lm',on);document.querySelectorAll('#theme-sw button').forEach(function(b){b.classList.toggle('th-sel',b.dataset.m===_themeMode);});}
function refreshSumTheme(){var sel=document.querySelector('.g-prog.g-sel');if(sel)showInfo(sel);}
// Split from setTheme() below so a native-pushed theme (AddShowView's embedded WKWebView calling
// this directly, never setTheme itself) can never loop back through the native bridge and get
// echoed back as if the user had clicked a theme button themselves — see AddShowView.swift's
// AddShowWebView doc comment for why that distinction matters (a resolved "auto" must never get
// silently rewritten to a concrete "dark"/"light" choice in Settings just because a page loaded).
function applyNativeTheme(m){_themeMode=m;try{localStorage.setItem('theme',m);}catch(e){}applyLM(m==='light'||(m==='auto'&&_mq.matches));refreshSumTheme();}
// The theme-switcher buttons' own onclick — a genuine user choice, so (unlike applyNativeTheme
// above) this also tells the native app about it when running inside its own embedded WKWebView.
// window.webkit only exists inside a WKWebView at all, and messageHandlers.appearanceChanged only
// exists on the one instance that registered it (AddShowView's guide step) — a real browser
// connecting over the LAN has neither, so this silently no-ops there via the catch, exactly the
// "a web connection only affects its own instance" isolation this needs.
function setTheme(m){applyNativeTheme(m);try{window.webkit.messageHandlers.appearanceChanged.postMessage(m);}catch(e){}}
_mq.addEventListener('change',function(e){if(_themeMode==='auto'){applyLM(e.matches);refreshSumTheme();}});
(function(){try{_themeMode=localStorage.getItem('theme')||'dark';}catch(e){}applyLM(_themeMode==='light'||(_themeMode==='auto'&&_mq.matches));})();
function isLM(){return document.documentElement.classList.contains('lm');}
// Vertical time-axis mode: automatic, tied directly to device orientation — portrait gets the
// transposed grid (time flows top-to-bottom, channels become columns), landscape gets the
// normal one. No manual toggle, no persisted preference: isVT() and guide-vertical.css's
// @media (orientation:portrait) block both key off the same matchMedia query, so CSS layout
// and this file's scroll/now-line math always agree on which mode is actually on screen.
// _vtEligible is baked in server-side per route (WebServer.swift's includeVerticalCSS, AND only
// when the vertical stylesheet template actually loaded) — true only on GET /vertical, and only
// when the CSS it depends on is really embedded. GET / never sends the vertical <style> block at
// all, so without this flag isVT() would say true (orientation alone) while the CSS never
// actually transposed anything, desyncing this file's scroll math from what's really on screen.
var _vtEligible={{VT_ELIGIBLE}};
var _orientMq=window.matchMedia('(orientation: portrait)');
function isVT(){return _vtEligible&&_orientMq.matches;}
// Rotating the phone mid-session changes the CSS layout instantly (pure media query), but the
// now-line's inline left/top (set once by updateNowLine, see below) and the lazy-load
// observer's margin (set once by initRowObserver, keyed to the axis at call time) don't
// re-derive themselves — without this listener they'd stay wrong until updateNowLine's next
// 60s tick or the next refreshGuide() DOM swap re-runs initRowObserver().
// _vtEligible-gated work: only a VT-eligible route (GET /vertical) can actually flip CSS
// layout on rotation, so only there does gw.scrollTop/scrollLeft's *meaning* invert (rows
// become columns or vice versa) and only there does initRowObserver's rootMargin (keyed to
// isVT()) actually change — on GET / it's always the same value, so rebuilding the
// IntersectionObserver there is pure waste. scrollToNow() replaces the stale, axis-flipped
// scroll offset with a fresh one for whichever axis is now live, rather than leaving it to be
// misread under the new layout. updateNowLine()/syncHdrPin() still run unconditionally: the
// former's "nudge back toward center" check depends on the viewport dimensions a rotation
// just changed even in horizontal mode, and the latter is a cheap no-op there anyway.
_orientMq.addEventListener('change',function(){
  if(_vtEligible){scrollToNow();initRowObserver();}
  updateNowLine();syncHdrPin();
});
var _gcDk={drama:'hsl(216,48%,35%)',comedy:'hsl(47,48%,35%)',news:'hsl(342,43%,35%)',sports:'hsl(119,48%,31%)',reality:'hsl(25,48%,35%)',movie:'hsl(270,58%,38%)',talk:'hsl(173,43%,34%)',children:'hsl(315,43%,35%)',crime:'hsl(0,55%,33%)',romance:'hsl(333,50%,37%)',thriller:'hsl(238,48%,38%)',action:'hsl(12,52%,35%)',mystery:'hsl(255,52%,38%)',doc:'hsl(202,48%,35%)',science:'hsl(188,52%,33%)',nature:'hsl(82,50%,33%)',history:'hsl(28,50%,34%)',music:'hsl(287,52%,37%)',food:'hsl(52,52%,34%)',travel:'hsl(182,48%,33%)',gameshow:'hsl(58,55%,34%)',home:'hsl(35,46%,33%)',health:'hsl(148,50%,32%)',faith:'hsl(65,48%,32%)'};
var _gcLk={drama:'hsl(216,55%,88%)',comedy:'hsl(47,65%,88%)',news:'hsl(342,55%,88%)',sports:'hsl(119,60%,87%)',reality:'hsl(25,65%,88%)',movie:'hsl(270,62%,90%)',talk:'hsl(173,55%,87%)',children:'hsl(315,60%,88%)',crime:'hsl(0,60%,68%)',romance:'hsl(333,55%,70%)',thriller:'hsl(238,52%,70%)',action:'hsl(12,57%,68%)',mystery:'hsl(255,57%,70%)',doc:'hsl(202,52%,68%)',science:'hsl(188,57%,66%)',nature:'hsl(82,55%,66%)',history:'hsl(28,55%,68%)',music:'hsl(287,57%,70%)',food:'hsl(52,58%,68%)',travel:'hsl(182,52%,66%)',gameshow:'hsl(58,62%,68%)',home:'hsl(35,50%,68%)',health:'hsl(148,55%,66%)',faith:'hsl(65,53%,66%)'};
function gc(g){var lo=(g||'').toLowerCase();lo=_ggAlias[lo]||lo;var m=isLM()?_gcLk:_gcDk;return m[lo]||(isLM()?'#d8d8d8':'#424242');}
var _ggAlias={'sitcom':'comedy','movies':'movie','kids':'children','sport':'sports','documentary':'doc','game show':'gameshow','animation':'children','animated':'children'};
var _ggKnown=['drama','comedy','news','sports','reality','movie','talk','children','crime','romance','thriller','action','mystery','doc','science','nature','history','music','food','travel','gameshow','home','health','faith'];
function tagBg(f){var lo=f.toLowerCase();var g=_ggAlias[lo]||lo;return _ggKnown.indexOf(g)>=0?'var(--gg-'+g+')':null;}
function heJs(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
var _bonusMins={{SPORTS_PADDING_MINUTES}};
var _bonusEnabled={{SPORTS_PADDING_ENABLED}};
var _sigEnabled={{SIGNAL_QUALITY_ENABLED}};
var _dupEnabled={{SKIP_DUP_ENABLED}};
var _defaultTranscode='{{DEFAULT_TRANSCODE}}';
function triggerSb(id){var el=document.getElementById(id);if(!el)return;el.classList.remove('sb-anim');void el.offsetWidth;el.classList.add('sb-anim');}
function toggleBonusStar(){var chk=document.getElementById('em-bonus');var star=document.getElementById('em-bonus-star');if(chk.checked){star.textContent='+'+_bonusMins+'m';star.style.display='inline-flex';triggerSb('em-bonus-star');}else{star.style.display='none';star.classList.remove('sb-anim');}}
function ft(d){var h=d.getHours(),m=d.getMinutes(),ap=h>=12?'PM':'AM';h=h%12||12;return h+(m?':'+(m<10?'0':'')+m:'')+' '+ap;}
function so(id,v){var e=document.getElementById(id);if(v){e.textContent=v;e.style.display='block';}else{e.style.display='none';}}
function devFull(devId){var t=tuners[devId];return t&&t.t>0&&t.a>=t.t;}
function noTranscode(devId){var t=tuners[devId];return !!(t&&t.nt);}
function showInfo(el){
  var d=el.dataset;
  // Mark the selection before renderHeavyFields() runs — paintHeavyFields() gates its
  // _poster update on '.g-sel' being present on el, and the synchronous cache-hit path
  // runs before this function would otherwise reach the old end-of-function assignment.
  document.querySelectorAll('.g-prog.g-sel').forEach(function(b){b.classList.remove('g-sel');});
  el.classList.add('g-sel');
  _d=d.device;_n=d.num;_s=+d.start;_e=+d.end;_ser=d.series||'';_genre=d.genre||'';_title=d.title||'';_poster=d.poster||'';_logo=d.logo||'';_chname=d.chname||'';
  document.getElementById('sum-ph').style.display='none';
  var sc=document.getElementById('sum-c');sc.style.display='flex';sc.style.background=el.style.background||gc(d.genre);
  var li=document.getElementById('sum-logo');
  if(d.logo){li.src=d.logo;li.style.display='inline';}else{li.style.display='none';}
  document.getElementById('sum-title').textContent=d.title||'';
  var gi=document.getElementById('sum-genre');
  var _allTags=(d.filters||d.genre||'').split(',').filter(function(f){return f&&f.toLowerCase()!=='series';});
  if(d.new==='1')_allTags.unshift('__new__');
  if(_allTags.length){gi.innerHTML=_allTags.map(function(f){if(f==='__new__')return '<span class="sum-tag" style="background:#27ae60;color:#fff;font-weight:800;letter-spacing:.07em">NEW</span>';var c=tagBg(f);return '<span class="sum-tag"'+(c?' style="background:'+c+'"':'')+'>'+heJs(f.toUpperCase())+'</span>';}).join('');gi.style.display='flex';}else{gi.style.display='none';}
  renderHeavyFields(el);
  document.getElementById('sum-ct').textContent='Ch '+d.num+' · '+d.chname+' · '+ft(new Date(+d.start*1000))+' – '+ft(new Date(+d.end*1000));
  var btn=document.getElementById('sum-btn');
  var del=document.getElementById('sum-del');
  var note=document.getElementById('sum-note');
  // Reset all action elements first
  var edit=document.getElementById('sum-edit');
  btn.style.display='none';edit.style.display='none';del.style.display='none';note.style.display='none';
  del.disabled=false;del.textContent='Delete';del.classList.remove('danger');del.style.background='';del.style.color='';
  var bstar=document.getElementById('sum-bonus-star');
  bstar.style.display='none';bstar.classList.remove('sb-anim');
  if(+d.recording){
    note.textContent='● Recording now';note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
    del.textContent='Stop & Delete';del.classList.add('danger');del.style.display='inline-block';
  } else if(+d.managed){
    note.textContent='★ Scheduled';note.style.color='var(--t2)';note.style.display='inline';
    del.textContent='Remove';del.style.display='inline-block';
    if(d.showId)edit.style.display='inline-block';
    if(d.showBonus==='1'){bstar.textContent='+'+_bonusMins+'m';bstar.style.display='inline-flex';triggerSb('sum-bonus-star');}
  } else {
    var nowTs=Math.floor(Date.now()/1000);
    var isLive=(_s<=nowTs&&_e>nowTs);
    if(isLive&&devFull(_d)){
      btn.textContent='⚠ Record (tuner full)';btn.style.background=isLM()?'#e08000':'#7a4a00';btn.style.color=isLM()?'#fff':'#ffcc66';
      btn.title='All tuners busy — show will be queued when a tuner is free';
    } else {
      btn.textContent='Record';btn.style.background='#c0392b';btn.style.color='#fff';btn.title='';
    }
    btn.style.display='inline-block';btn.disabled=false;
  }
}
// Double-click on a guide tile skips straight to the relevant modal — same showInfo(el)
// selection/population step a single click does, immediately followed by whichever action the
// Summary panel would otherwise need a second click for, instead of waiting on that click.
// - Managed (data-managed="1", recording or not) → doEditFromGuide() instead of doRecord() —
//   re-adding an already-scheduled (or already-recording) show via the Record modal never made
//   sense there. doEditFromGuide() reads from the same '.g-prog.g-sel' selection showInfo(el)
//   just set, so this is the exact same data the Summary panel's own Edit button would use for a
//   scheduled (not recording) show — for a recording show it's a double-click-only shortcut, not
//   mirroring a visible button, since showInfo() itself only shows "Stop & Delete" there (not an
//   Edit button) to keep an accidental double-click away from that destructive action.
// - Unmanaged → doRecord(), the original behavior, through the exact same
//   showInfo()->doRecord() sequence as before (not a shortcut around it) so doRecord()'s in-app
//   AddShowView wizard bridge special-case (webkit.messageHandlers.record) still fires
//   correctly. Mirrors the rm-air-row ondblclick->switchAiring(idx) precedent below.
function recordFromDblClick(el){
  showInfo(el);
  if(el.dataset.managed==='1'){doEditFromGuide();}
  else{doRecord();}
}
// Heavy fields (Synopsis/poster/episode/air date) aren't baked into the initial grid HTML —
// they're fetched lazily per-row (see fetchRowHeavy/initRowObserver below). renderHeavyFields
// paints whatever's cached/present immediately (avoids a stale-data flash), then — if the row's
// IntersectionObserver hasn't already fetched it — does a just-in-time fetch for a fast click on
// a not-yet-observed row, guarded so a slow/superseded fetch can't clobber a later selection.
function paintHeavyFields(el){
  var d=el.dataset;
  if(document.querySelector('.g-prog.g-sel')===el)_poster=d.poster||'';
  var pi=document.getElementById('sum-poster');
  pi.dataset.pgen=(+pi.dataset.pgen||0)+1;
  if(d.poster&&d.logo){
    pi.onerror=function(){pi.src=d.logo;pi.onerror=function(){pi.style.display='none';};};
    pi.src=d.poster;pi.style.display='block';
  }else if(d.poster){
    pi.onerror=function(){if(_logo){pi.src=_logo;pi.onerror=function(){pi.style.display='none';};}else{pi.style.display='none';}};
    pi.src=d.poster;pi.style.display='block';
  }else if(d.logo){
    pi.onerror=function(){pi.style.display='none';};
    pi.src=d.logo;pi.style.display='block';
  }else{pi.style.display='none';}
  so('sum-ep',d.ep||'');
  so('sum-date',d.new==='1'?'':(d.date?'Orig. '+d.date:''));
  var sy=document.getElementById('sum-syn');
  if(d.syn){sy.textContent=d.syn;sy.style.display='block';}else{sy.style.display='none';}
}
function renderHeavyFields(el){
  if(applyHeavyFromCache(el)){paintHeavyFields(el);return;}
  paintHeavyFields(el);
  var gen=(el.dataset._hgen=(+el.dataset._hgen||0)+1);
  fetchRowHeavy(el.closest('.g-row')).then(function(){
    if(+el.dataset._hgen!==gen)return;
    if(document.querySelector('.g-prog.g-sel')!==el)return;
    paintHeavyFields(el);
  });
}
function closeSummary(){
  document.getElementById('sum-c').style.display='none';
  document.getElementById('sum-ph').style.display='flex';
  document.querySelectorAll('.g-prog.g-sel').forEach(function(b){b.classList.remove('g-sel');});
  var bstar=document.getElementById('sum-bonus-star');bstar.style.display='none';bstar.classList.remove('sb-anim');
}
// t = short label, matching native ShowState.rawValue exactly (native is the layout
// baseline both modals mirror) — shown on the button itself. d = longer description,
// shown on a single line below the button row for whichever option is selected.
// Full 4-way labels — kept as-is (not collapsed) since typeLabel() below still needs the
// precise "SeriesID(Channel)"/"SeriesID(All)" text for the delete-confirm dialog.
var recOpts=[
  {v:'single',        t:'Single',            d:'Record this airing only'},
  {v:'dateTime',      t:'DateTime',          d:'Record at this time each week'},
  {v:'seriesChannel', t:'SeriesID(Channel)', d:'Record new episodes on this channel'},
  {v:'seriesAll',     t:'SeriesID(All)',     d:'Record new episodes on any channel'}
];
// Collapsed set for the Type row itself: seriesChannel/seriesAll render as one "SeriesID"
// segment, with the Channel/All choice moved to the separate Scope row (renderScopeRow)
// below — mirrors the native Add/Edit dialog's Type/Scope picker split (ShowFormSection.swift).
var topOpts=[
  {v:'single',   t:'Single',   d:'Record this airing only'},
  {v:'dateTime', t:'DateTime', d:'Record at this time each week'},
  {v:'seriesID', t:'SeriesID', d:'Record new episodes automatically — pick Channel or All scope below'}
];
function topOptFor(type){ return (type==='seriesChannel'||type==='seriesAll')?'seriesID':type; }
// Renders the Type row as compact buttons (native's segmented Type picker equivalent)
// plus one description line for whichever option is selected — puts every option along
// the top like the native wizard, with the rest of the form below, instead of the old
// one-card-per-row stacked layout. Shared by the Record and Edit modals. `selected` is the
// real show type ('single'/'dateTime'/'seriesChannel'/'seriesAll'); `onSelect` is called with
// the clicked top-level value ('single'/'dateTime'/'seriesID') — the caller resolves 'seriesID'
// to a concrete type (defaulting to 'seriesChannel', or preserving the current scope).
// Resolves the collapsed 'seriesID' Type segment to a concrete show type: whichever concrete
// series type is already selected (a same-value re-tap preserves scope), defaulting to
// 'seriesChannel' the first time in. Shared by the Record and Edit modals' renderTypeRow
// onSelect callbacks so the "preserve current scope on re-tap" rule can't drift between them.
function resolveSeriesTypePick(v,current){
  return (v==='seriesID')?((current==='seriesChannel'||current==='seriesAll')?current:'seriesChannel'):v;
}
function renderTypeRow(containerId,descId,selected,onSelect){
  var container=document.getElementById(containerId);
  var descEl=document.getElementById(descId);
  container.innerHTML='';
  var selTop=topOptFor(selected);
  topOpts.forEach(function(o){
    var btn=document.createElement('button');
    btn.type='button';
    btn.className='rm-type-btn'+(o.v===selTop?' sel':'');
    btn.textContent=o.t;
    btn.onclick=function(){
      Array.from(container.querySelectorAll('.rm-type-btn')).forEach(function(b){b.classList.remove('sel');});
      btn.classList.add('sel');
      descEl.textContent=o.d;
      onSelect(o.v);
    };
    container.appendChild(btn);
  });
  var initial=topOpts.filter(function(o){return o.v===selTop;})[0]||topOpts[0];
  descEl.textContent=initial.d;
}
// Renders the Channel/All Scope row — only meaningful (and only ever shown) while the Type
// row's collapsed SeriesID segment is selected. `selected` is 'seriesChannel'/'seriesAll';
// `onSelect` is called with whichever of those two was clicked.
function renderScopeRow(containerId,selected,onSelect){
  var container=document.getElementById(containerId);
  container.innerHTML='';
  [{v:'seriesChannel',t:'Channel'},{v:'seriesAll',t:'All'}].forEach(function(o){
    var btn=document.createElement('button');
    btn.type='button';
    btn.className='rm-type-btn'+(o.v===selected?' sel':'');
    btn.textContent=o.t;
    btn.onclick=function(){
      Array.from(container.querySelectorAll('.rm-type-btn')).forEach(function(b){b.classList.remove('sel');});
      btn.classList.add('sel');
      onSelect(o.v);
    };
    container.appendChild(btn);
  });
}
// 3-bar signal SVG (same geometry/palette as the guide-row bars). bucket: poor|fair|good.
function _sigBarsSvg(bucket){
  var color=bucket==='poor'?'#e53935':bucket==='fair'?'#fbc02d':'#43a047';
  var b2=bucket!=='poor'?color:'#555';
  var b3=bucket==='good'?color:'#555';
  return '<svg viewBox="0 0 11 10" width="13" height="12" style="vertical-align:middle" title="Signal: '+bucket+'">'
    +'<rect x="0" y="6" width="3" height="4" fill="'+color+'"/>'
    +'<rect x="4" y="3" width="3" height="7" fill="'+b2+'"/>'
    +'<rect x="8" y="0" width="3" height="10" fill="'+b3+'"/></svg>';
}
// Populate the record modal's signal bars + weak-signal warning for the current channel
// (_chname) from the existing /api/signal-stats endpoint. Blank on disabled / no-data /
// error, same as the .noData behavior elsewhere. Guarded against a switchAiring race.
function renderRmSignal(){
  var sig=document.getElementById('rm-sig');
  var warn=document.getElementById('rm-sig-warn');
  if(sig)sig.innerHTML='';
  if(warn)warn.style.display='none';
  if(!_sigEnabled||!_chname)return;
  var name=_chname;
  fetch('/api/signal-stats/'+encodeURIComponent(name)).then(function(r){return r.json();}).then(function(d){
    if(_chname!==name)return;
    var b=d&&d.bucket;
    if(!b||b==='noData')return;
    if(sig)sig.innerHTML=_sigBarsSvg(b);
    if(warn)warn.style.display=(b==='poor')?'block':'none';
  }).catch(function(){});
}
// Same as renderRmSignal() above, for the edit modal — separate _editChname (not the shared
// _chname the Record modal/grid selection uses) since Edit can be opened from the tuner
// dropdown, which never touches _chname at all. Also toggles #em-sig-row's visibility (the
// Record modal's #rm-sig has no row of its own to hide — it's nested inside the Title row —
// but Edit's Signal row would otherwise show an empty label for every show when disabled/no-data).
var _editChname='';
function renderEmSignal(){
  var row=document.getElementById('em-sig-row');
  var sig=document.getElementById('em-sig');
  var warn=document.getElementById('em-sig-warn');
  if(sig)sig.innerHTML='';
  if(warn)warn.style.display='none';
  if(row)row.style.display='none';
  if(!_sigEnabled||!_editChname)return;
  var name=_editChname;
  fetch('/api/signal-stats/'+encodeURIComponent(name)).then(function(r){return r.json();}).then(function(d){
    if(_editChname!==name)return;
    var b=d&&d.bucket;
    if(!b||b==='noData')return;
    if(sig)sig.innerHTML=_sigBarsSvg(b);
    if(warn)warn.style.display=(b==='poor')?'block':'none';
    if(row)row.style.display='flex';
  }).catch(function(){});
}
function doRecord(){
  // In-app WKWebView (AddShowView wizard): send entry data to Swift instead of showing the record modal.
  // Swift intercepts this, calls applyWebGuideEntry(), and advances to the Details step.
  if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.record){
    window.webkit.messageHandlers.record.postMessage({deviceId:_d,guideNumber:_n,startTime:_s,endTime:_e,title:_title,seriesId:_ser,genre:_genre,imageURL:_poster});
    return;
  }
  document.getElementById('rm-title-in').value=_title||'';
  document.getElementById('rm-ch').textContent=document.getElementById('sum-ct').textContent||'';
  document.getElementById('rm-sid').style.display='none';
  document.getElementById('rm-airings').style.display='none';
  _airCache={};_airGen++;var _myGen=_airGen;
  _rmType='single';
  // Build day buttons — pre-check the day-of-week matching the guide entry
  _entryDow=new Date(_s*1000).getDay();
  var rmDaysEl=document.getElementById('rm-days');rmDaysEl.innerHTML='';
  _dayNames.forEach(function(day,i){
    var btn=document.createElement('button');
    btn.type='button';btn.className='day-btn'+(i===_entryDow?' sel':'');
    btn.textContent=_dayShort[i];btn.dataset.day=day;
    btn.onclick=function(){
      if(_rmType==='single'){
        var wasSel=this.classList.contains('sel');
        Array.from(rmDaysEl.querySelectorAll('.day-btn.sel')).forEach(function(b){b.classList.remove('sel');});
        if(!wasSel)this.classList.add('sel');
      } else {
        if(this.classList.contains('sel')&&rmDaysEl.querySelectorAll('.day-btn.sel').length<=1)return;
        this.classList.toggle('sel');
      }
    };
    rmDaysEl.appendChild(btn);
  });
  document.getElementById('rm-days-lbl').textContent='Day';
  document.getElementById('rm-days-row').style.display='flex';
  document.getElementById('rm-new-row').style.display='none';
  document.getElementById('rm-new').checked=false;
  document.getElementById('rm-scope-row').style.display='none';
  document.getElementById('rm-transcode').value=_defaultTranscode;
  updateNoTranscodeWarn();
  var _isSports=_genre.toLowerCase().indexOf('sport')>=0; // matches guide.php's "Sports" and XMLTV's singular "Sport"
  document.getElementById('rm-bonus-row').style.display=_bonusEnabled?'flex':'none';
  document.getElementById('rm-bonus').checked=_bonusEnabled&&_isSports;
  var rbstar=document.getElementById('rm-bonus-star');rbstar.textContent='+'+_bonusMins+'m';if(_bonusEnabled&&_isSports){rbstar.style.display='inline-flex';triggerSb('rm-bonus-star');}else{rbstar.style.display='none';rbstar.classList.remove('sb-anim');}
  // Show tuner-full warning only when the show is live and that device has no free tuners
  var nowTs=Math.floor(Date.now()/1000);
  var isLive=(_s<=nowTs&&_e>nowTs);
  document.getElementById('rm-tuner').style.display=(isLive&&devFull(_d))?'block':'none';
  renderRmSignal();
  renderTypeRow('rm-opts','rm-type-desc','single',function(v){
    _rmType=resolveSeriesTypePick(v,_rmType);
    var isSeries=_rmType==='seriesChannel'||_rmType==='seriesAll';
    document.getElementById('rm-scope-row').style.display=isSeries?'flex':'none';
    if(isSeries)renderScopeRow('rm-scope',_rmType,function(sv){
      _rmType=sv;
      // Channel/All scope changes which airings this show could actually catch — re-filter the
      // already-cached list (renderAirings itself applies the channel filter for 'seriesChannel')
      // rather than re-fetching, since /api/airings/{seriesId} always returns every channel.
      renderAirings(_airCache[_ser]||[]);
    });
    var sid=document.getElementById('rm-sid');
    if(isSeries&&_ser){document.getElementById('rm-sid-val').textContent=_ser;sid.style.display='flex';}
    else{sid.style.display='none';}
    if(_rmType==='single'||_rmType==='dateTime'){
      document.getElementById('rm-days-lbl').textContent=(_rmType==='single')?'Day':'Days';
      document.getElementById('rm-days-row').style.display='flex';
      if(_rmType==='single'){
        Array.from(rmDaysEl.querySelectorAll('.day-btn')).forEach(function(b,i){b.classList.toggle('sel',i===_entryDow);});
      }
    } else {
      document.getElementById('rm-days-row').style.display='none';
    }
    // Clear the checkbox itself, not just the row's visibility — otherwise a check left on from
    // a DateTime/Series pick before switching back to Single silently rides along in the payload.
    if(_rmType==='single')document.getElementById('rm-new').checked=false;
    document.getElementById('rm-new-row').style.display=(_rmType==='single')?'none':'flex';
    if(isSeries&&_ser){loadAirings(_ser,_myGen);}
    else{document.getElementById('rm-airings').style.display='none';}
  });
  document.getElementById('rec-modal').style.display='flex';
}
var _airCache={},_airGen=0,_airCurrent=[],_entryDow=0,_rmType='single';
function loadAirings(ser,gen){
  if(_airCache[ser]){renderAirings(_airCache[ser]);return;}
  fetch('/api/airings/'+encodeURIComponent(ser)).then(function(r){return r.json();}).then(function(d){
    if(gen!==_airGen)return;
    _airCache[ser]=d.airings||[];
    renderAirings(_airCache[ser]);
  }).catch(function(){});
}
// Double-click on an "Other Upcoming Airings" row re-anchors the whole modal to that
// airing — same fields the initial showInfo()/doRecord() pair sets up, minus the
// selected Type/Transcode/Bonus, which are left as the user already set them.
function switchAiring(idx){
  var a=_airCurrent[idx]; if(!a)return;
  _d=a.device; _n=String(a.ch); _s=+a.start; _e=+a.end; _genre=a.genre||''; _title=a.title||_title;
  _entryDow=new Date(_s*1000).getDay();
  document.getElementById('rm-title-in').value=_title;
  document.getElementById('rm-ch').textContent='Ch '+_n+' · '+(a.chName||'')+' · '+ft(new Date(_s*1000))+' – '+ft(new Date(_e*1000));
  var nowTs=Math.floor(Date.now()/1000);
  var isLive=(_s<=nowTs&&_e>nowTs);
  document.getElementById('rm-tuner').style.display=(isLive&&devFull(_d))?'block':'none';
  updateNoTranscodeWarn(); // _d may have changed to a different tuner
  renderRmSignal();
  renderAirings(_airCache[_ser]||[]);
}
// Warns when the currently-picked Transcode profile would be silently forced to None at record
// time — mirrors AppState.startRecording's own device.supportsTranscode override (see
// docs/HDHRFindings.md's "Transcode capability" section), so the modal can say so proactively
// instead of only after a failed recording. Re-run whenever the picker or the device changes.
function updateNoTranscodeWarn(){
  var sel=document.getElementById('rm-transcode');
  var show=sel&&sel.value!=='none'&&noTranscode(_d);
  document.getElementById('rm-no-transcode').style.display=show?'block':'none';
}
// Same warning, for the Edit modal (#em-no-transcode) — mirrors updateNoTranscodeWarn() above but
// keyed off _editDev (the show's already-assigned tuner) rather than the guide's currently-selected
// one, since editing an existing show never changes which tuner it's on.
function updateEmNoTranscodeWarn(){
  var sel=document.getElementById('em-transcode');
  var show=sel&&sel.value!=='none'&&noTranscode(_editDev);
  document.getElementById('em-no-transcode').style.display=show?'block':'none';
}
function renderAirings(list){
  // seriesChannel only ever records from the currently-selected channel (_n) — filter the
  // preview to it so it doesn't list airings this show could never actually catch. seriesAll
  // can record from any channel on the assigned device, so stays unfiltered. Device is
  // deliberately never filtered either way — see the exclusion filter below.
  var scoped=(_rmType==='seriesChannel')?list.filter(function(a){return String(a.ch)===_n;}):list;
  // Excludes by device too, not just channel+time — two tuners sharing one antenna report
  // the same channel number with identical airings, so channel+time alone would wrongly
  // hide the *other* device's copy of the just-selected airing, even though double-clicking
  // it is exactly how you'd steer the recording to that other tuner instead.
  var filtered=scoped.filter(function(a){return !(String(a.ch)===_n&&+a.start===_s&&String(a.device)===_d);});
  _airCurrent=filtered;
  var panel=document.getElementById('rm-airings');
  var listEl=document.getElementById('rm-airings-list');
  if(!filtered.length){panel.style.display='none';listEl.innerHTML='';return;}
  listEl.innerHTML=filtered.map(function(a,i){
    var d=new Date(a.start*1000);
    var timeLabel=_dayShort[d.getDay()]+' '+ft(d);
    var chLabel=a.chName?('Ch '+a.ch+' · '+a.chName):('Ch '+a.ch);
    var logo=a.chLogo
      ? '<img class="rm-air-logo" src="'+heJs(a.chLogo)+'" alt="" loading="lazy" onerror="this.style.visibility=\'hidden\'">'
      : '<div class="rm-air-logo"></div>';
    return '<div class="rm-air-row" ondblclick="switchAiring('+i+')" title="Double-click to record this airing instead">'
      +'<div class="rm-air-bar" style="background:'+gc(a.genre)+'"></div>'
      +logo
      +'<div class="rm-air-info">'
      +'<div class="rm-air-t">'+hej(timeLabel)+'</div>'
      +'<div class="rm-air-ch">'+hej(chLabel)+'</div>'
      +(a.ep?'<div class="rm-air-ep">'+hej(a.ep)+'</div>':'')
      +'</div></div>';
  }).join('');
  panel.style.display='flex';
}
function cancelRecord(){document.getElementById('rec-modal').style.display='none';var rbstar=document.getElementById('rm-bonus-star');rbstar.style.display='none';rbstar.classList.remove('sb-anim');}
function toggleRmBonusStar(){var chk=document.getElementById('rm-bonus');var star=document.getElementById('rm-bonus-star');if(chk.checked){star.textContent='+'+_bonusMins+'m';star.style.display='inline-flex';triggerSb('rm-bonus-star');}else{star.style.display='none';star.classList.remove('sb-anim');}}
function confirmRecord(){
  var type=_rmType||'single';
  var airDays=Array.from(document.querySelectorAll('#rm-days .day-btn.sel')).map(function(b){return b.dataset.day;});
  var transcode=document.getElementById('rm-transcode').value;
  var editedTitle=document.getElementById('rm-title-in').value.trim();
  var payload={deviceId:_d,guideNumber:_n,startTime:_s,endTime:_e,showType:type,airDays:airDays,transcode:transcode,bonusTime:document.getElementById('rm-bonus').checked,newOnly:document.getElementById('rm-new').checked};
  if(editedTitle&&editedTitle!==_title)payload.title=editedTitle;
  cancelRecord();
  var btn=document.getElementById('sum-btn');
  btn.disabled=true;btn.textContent='Scheduling…';
  postJSON('/api/record',payload)
  .then(function(r){
    if(r.ok){
      return r.json().then(function(j){
        // Update guide block in place — no page reload needed
        var sel=document.querySelector('.g-prog.g-sel');
        if(sel){
          sel.classList.remove('g-prog-now','g-st-sched','g-st-conflict');
          if(j.recStarted){
            sel.classList.add('g-prog-rec','g-st-rec');sel.dataset.recording='1';
          } else {
            sel.classList.add('g-prog-sched','g-st-sched');sel.dataset.managed='1';
          }
        }
        // Refresh tuner count button
        var tb=document.getElementById('tun-'+_d);
        if(tb&&j.tunerTotal>0){
          tb.textContent=j.tunerActive+'/'+j.tunerTotal+(j.tunerFull?' — FULL':'');
          if(j.tunerFull)tb.classList.add('t-info-full');else tb.classList.remove('t-info-full');
        }
        btn.style.display='none';
        var note=document.getElementById('sum-note');
        var del=document.getElementById('sum-del');
        note.textContent=j.recStarted?'● Recording now':j.tunerFull?'⚠ Queued — all tuners busy':'★ Scheduled';
        note.style.color=j.recStarted?(isLM()?'#cc2020':'#ff8080'):j.tunerFull?(isLM()?'#c07000':'#ffcc66'):'var(--t2)';
        note.style.display='inline';
        if(j.recStarted){del.textContent='Stop & Delete';del.classList.add('danger');}else{del.textContent='Remove';del.style.background='';del.style.color='';}del.style.display='inline-block';del.disabled=false;
        // No explicit refreshGuide() here — /api/record's addShow/updateShow already broadcasts show_updated over SSE
      });
    } else {
      return r.text().then(function(t){
        var msg;try{var j=JSON.parse(t);msg='Error: '+(j.error||t);}catch(x){msg='Error: '+t;}
        btn.textContent=msg;btn.style.background=isLM()?'#fce8e8':'#4a1010';btn.style.color=isLM()?'#8b0000':'#ff6b6b';btn.disabled=false;
        var note=document.getElementById('sum-note');note.textContent=msg;note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
      }).catch(function(){
        btn.textContent='Error ('+r.status+')';btn.disabled=false;
        var note=document.getElementById('sum-note');note.textContent='Error ('+r.status+')';note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
      });
    }
  })
  .catch(function(e){
    var msg='Error: '+(e.message||'network');
    btn.textContent=msg;btn.style.background=isLM()?'#fce8e8':'#4a1010';btn.style.color=isLM()?'#8b0000':'#ff6b6b';btn.disabled=false;
    var note=document.getElementById('sum-note');note.textContent=msg;note.style.color=isLM()?'#cc2020':'#ff8080';note.style.display='inline';
  });
}
// Decodes one gzip+base64'd string back to plain text — counterpart to WebServer.swift's
// gzipBase64(_:), used only for the SSE guide-change broadcast's *Z-suffixed fields (see that
// function's own comment for why: unlike GET /api/guide-refresh, a plain HTTP response the browser
// already transparently gzip-decodes via fetch(), the persistent SSE connection has no such layer).
// Returns a Promise<string>; requires DecompressionStream (broadly supported since ~2023 — Chrome/
// Edge 80+, Safari 16.4+, Firefox 113+), checked by the one call site below before this is ever called.
function decodeGzipB64(b64){
  var bin=atob(b64),bytes=new Uint8Array(bin.length);
  for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
  var stream=new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(stream).text();
}
// Applies a {grid,sumph,tdrop} payload to the DOM — shared by refreshGuide()'s fetch
// response and the SSE-pushed guide-change events (which carry the same shape so a
// rebuild triggered by a state change happens once server-side, not once per open tab).
function applyGuidePayload(d,selOverride){
  var gw=document.querySelector('.gw');
  var sl=gw?gw.scrollLeft:0,st=gw?gw.scrollTop:0;
  var prev=document.querySelector('.g-prog.g-sel');
  var prevStart=prev?prev.dataset.start:null,prevNum=prev?prev.dataset.num:null,prevDev=prev?prev.dataset.device:null;
  var oldGi=document.querySelector('.gi');
  if(oldGi)oldGi.innerHTML=d.grid;
  // Sync time window vars from the new g-hdr so the now-line plots against the fresh origin.
  var nh=document.querySelector('.g-hdr');
  if(nh&&nh.dataset.winstart){_winStart=+nh.dataset.winstart;_winSec=+nh.dataset.winsec;}
  var oldPh=document.getElementById('sum-ph');
  if(oldPh)oldPh.innerHTML=d.sumph;
  // Update each tuner's show list; header/toggle-open state is preserved.
  Object.keys(d.tdrop).forEach(function(dev){
    var el=document.getElementById('tdrop-body-'+dev);
    if(el)el.innerHTML=d.tdrop[dev];
  });
  _rows=document.querySelectorAll('.g-row');
  initRowObserver();
  setDev(curDev); // same id — won't self-trigger the rebuild below, since curDev didn't change
  rebuildGenreFilter(); // new guide data may have introduced/dropped genres even on an unchanged device
  if(gw){gw.scrollLeft=sl;gw.scrollTop=st;}
  syncHdrPin();
  if(prevStart){
    // Direct attribute selector instead of materializing every .g-prog into an array and
    // scanning it — lets the browser's native selector engine find the match directly.
    var match=document.querySelector('.g-prog[data-start="'+prevStart+'"][data-num="'+prevNum+'"][data-device="'+prevDev+'"]');
    if(match){if(selOverride)Object.assign(match.dataset,selOverride);showInfo(match);}
  }
}
function refreshGuide(selOverride){
  // Returns the fetch chain (existing callers all ignore the return value) so pull-to-refresh
  // can wait for the real completion instead of guessing with a timeout.
  return fetch('/api/guide-refresh').then(function(r){return r.json();}).then(function(d){
    applyGuidePayload(d,selOverride);
  }).catch(function(){});
}
function doEditFromGuide(){
  var sel=document.querySelector('.g-prog.g-sel');
  if(!sel||!sel.dataset.showId)return;
  var sd=sel.dataset;
  openEditShow({dataset:{
    id:sd.showId, title:sd.title, ch:sd.num, chname:sd.chname,
    type:sd.showType||'single', paused:sd.showPaused||'0',
    recording:sd.showRecording||'0', length:sd.showLength||'60',
    bonus:sd.showBonus||'0', transcode:sd.showTranscode||'none',
    seriesid:sd.showSeriesid||'', airdays:sd.showAirdays||'',
    failcount:sd.showFailcount||'0', failreason:sd.showFailreason||'',
    ignoredup:sd.showIgnoredup||'0', newonly:sd.showNewonly||'0', poster:sd.poster||'', logo:sd.logo||''
  }});
}
// Recording-type short labels, keyed by ShowState.rawValue — reuses the same recOpts table
// the Record/Edit modals' Type row renders from, so the confirm dialog can never disagree
// with what those modals call each type.
function typeLabel(t){
  var o=recOpts.filter(function(x){return x.v===t;})[0];
  return o?o.t:(t||'Single');
}
function showDeleteConfirm(title,poster,typeStr,isRec,onConfirm){
  var pi=document.getElementById('dc-poster');
  if(poster){pi.onerror=function(){pi.style.display='none';};pi.src=poster;pi.style.display='block';}
  else{pi.style.display='none';}
  document.getElementById('dc-title').textContent='Delete "'+(title||'this show')+'"?';
  document.getElementById('dc-type').textContent='Type: '+typeLabel(typeStr);
  document.getElementById('dc-warn').textContent=isRec
    ?'This will stop the active recording. This cannot be undone.'
    :'This cannot be undone.';
  document.getElementById('dc-confirm-btn').textContent=isRec?'Stop & Delete':'Delete';
  _delConfirmAction=onConfirm;
  document.getElementById('del-confirm-modal').style.display='flex';
}
function cancelDeleteConfirm(){
  document.getElementById('del-confirm-modal').style.display='none';
  _delConfirmAction=null;
}
function confirmDeleteConfirm(){
  var fn=_delConfirmAction;
  cancelDeleteConfirm();
  if(fn)fn();
}
function doDelete(){
  var sel=document.querySelector('.g-prog.g-sel');
  var title=document.getElementById('sum-title').textContent||'';
  var poster=_poster||_logo||'';
  var type=sel?sel.dataset.showType:'';
  // dataset.showRecording (data-show-recording) is the Show struct's own show_recording flag —
  // the same authoritative source the Edit modal's delete confirm uses (_editRec). Prefer it over
  // dataset.recording, a different, channel-occupancy-derived flag (isEntryRec) that can briefly
  // disagree with it right as a recording starts/stops, and made the two delete confirms
  // inconsistent. showRecording is only emitted for a managed (owner-matched) entry though — an
  // entry occupying a recording channel without a managed-show match (rare: a manually-started
  // single recording whose title doesn't match the guide's current airing) has no showRecording
  // attribute at all, so fall back to the occupancy flag rather than silently reading as "not recording".
  var isRec=sel?(sel.dataset.showRecording!==undefined?sel.dataset.showRecording==='1':sel.dataset.recording==='1'):false;
  showDeleteConfirm(title,poster,type,isRec,performSummaryDelete);
}
function performSummaryDelete(){
  var del=document.getElementById('sum-del');
  var _delLabel=del.textContent;
  del.disabled=true;del.textContent='Deleting…';
  var title=document.getElementById('sum-title').textContent||'';
  postJSON('/api/delete',{deviceId:_d,guideNumber:_n,startTime:_s,title:title})
  .then(function(r){return r.json();})
  .then(function(j){
    var note=document.getElementById('sum-note');
    if(j.ok){
      // Update guide tile in place — restore g-prog-now if the show is still airing
      var sel=document.querySelector('.g-prog.g-sel');
      if(sel){
        sel.classList.remove('g-prog-rec','g-prog-sched','g-prog-now','g-st-sched','g-st-rec','g-st-skip','g-st-conflict');
        sel.dataset.managed='0';sel.dataset.recording='0';
        var nowTs=Math.floor(Date.now()/1000);
        if(_s<=nowTs&&_e>nowTs){sel.classList.add('g-prog-now');}
      }
      del.style.display='none';
      note.textContent='✓ Deleted';note.style.color='var(--t3)';note.style.fontStyle='normal';note.style.display='inline';
      document.getElementById('sum-btn').textContent='Record';document.getElementById('sum-btn').style.background='#c0392b';
      document.getElementById('sum-btn').style.color='#fff';document.getElementById('sum-btn').style.display='inline-block';
      document.getElementById('sum-btn').disabled=false;
      // No explicit refreshGuide() here — deleteShow() already broadcasts show_deleted over SSE
    } else {
      del.textContent=_delLabel;del.disabled=false;
      note.textContent='Error: '+(j.error||'Delete failed');note.style.color='#ff8080';note.style.fontStyle='normal';note.style.display='inline';
    }
  })
  .catch(function(e){
    var del=document.getElementById('sum-del');del.textContent=_delLabel;del.disabled=false;
    var note=document.getElementById('sum-note');
    note.textContent='Error: '+(e.message||'network');note.style.color='#ff8080';note.style.fontStyle='normal';note.style.display='inline';
  });
}
// Generation token: bumped on every popover open and close, so async enrichment
// fetches started for an earlier generation can't append stale DOM into a rebuilt
// (or closed) popover. All enrichment callbacks compare their captured gen.
var tPopGen=0;
function showTunerInfo(devId,anchor){
  tPopGen++;var gen=tPopGen;
  var recs=recsByDev[devId]||[];
  var dt=tuners[devId]||{t:0,a:0};
  var full=dt.t>0&&dt.a>=dt.t;
  document.getElementById('t-pop-hdr').textContent=(dt.t>0?dt.a+'/'+dt.t+' tuners':'Tuners')+(full?' — FULL':'');
  var list=document.getElementById('t-pop-list');
  if(recs.length===0){
    list.innerHTML='<div style="color:var(--t4);font-size:.8rem;padding:4px 0">No active recordings</div>';
  } else {
    list.innerHTML=recs.map(function(r){
      if(r.idle==='1'){
        return '<div style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--b0)">'
          +'<span style="font-size:.67rem;color:var(--t4);min-width:48px;flex-shrink:0">'+hej(r.tuner)+'</span>'
          +'<span style="font-size:.78rem;color:var(--t4)">Idle</span>'
          +'</div>';
      }
      // "another tuner" suffix + purple dot (matches the guide grid's .g-st-inuse color, #9b59b6)
      // make explicit that this tuner isn't managed by this app — a bare title with no red dot
      // was too easy to misread as simply "not currently recording" rather than "not ours at all".
      var chLabel=hej(r.ch)+(r.chname?' · '+hej(r.chname):'')+(r.external==='1'?' · another tuner':'');
      var ipHtml=r.ip?'<div style="font-size:.67rem;color:var(--t4);padding-left:56px">'+hej(r.ip)+'</div>':'';
      var recDot=r.rec==='1'?'<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#e53935;margin-right:6px;flex-shrink:0;vertical-align:middle"></span>':'';
      var extDot=r.external==='1'?'<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#9b59b6;margin-right:6px;flex-shrink:0;vertical-align:middle"></span>':'';
      var etHtml='';
      if(r.endTime&&r.rec==='1'){var et=new Date(parseInt(r.endTime,10)*1000);etHtml='<div style="font-size:.72rem;color:var(--t3);padding-left:56px">Ends '+et.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})+'</div>';}
      // Build the element id from the raw tuner name (not hej()-escaped) so it matches the
      // r.tuner-based getElementById lookups below — an HTML-escaped id would diverge if a
      // Resource ever contained & < >, and an id attribute doesn't need HTML escaping.
      var rid='tnr-'+r.tuner.replace(/\W/g,'');
      return '<div id="'+rid+'" style="display:flex;flex-direction:column;gap:2px;padding:8px 0;border-bottom:1px solid var(--b0)">'
        +'<div style="display:flex;align-items:center;gap:8px">'
          +'<span style="font-size:.67rem;color:var(--t4);min-width:48px;flex-shrink:0">'+hej(r.tuner)+'</span>'
          +'<span style="font-size:.78rem;font-weight:600;color:var(--ac);white-space:nowrap">'+chLabel+'</span>'
        +'</div>'
        +'<div style="font-size:.82rem;color:var(--t0);padding-left:56px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'+recDot+extDot+hej(r.title)+'</div>'
        +etHtml
        +ipHtml
        +'</div>';
    }).join('');
    // Make our own recording titles clickable — jumps guide to that channel
    recs.forEach(function(r){
      if(r.rec!=='1'||!r.ch||r.ch==='?')return;
      var rid='tnr-'+r.tuner.replace(/\W/g,'');
      var row=document.getElementById(rid);if(!row)return;
      var titleDiv=row.children[1];
      if(titleDiv){titleDiv.style.cursor='pointer';titleDiv.style.textDecoration='underline dotted';(function(ch){titleDiv.onclick=function(){goToShow(ch);};})(r.ch);}
    });
    // Inline signal quality per active tuner — shows how recordable the channel
    // currently on each tuner is, with freshness ("checked Xh ago"). Appended async.
    recs.forEach(function(r){
      if(r.idle==='1'||!r.chname)return;
      var rid='tnr-'+r.tuner.replace(/\W/g,'');
      fetch('/api/signal-stats/'+encodeURIComponent(r.chname))
        .then(function(res){return res.json();})
        .then(function(s){
          if(gen!==tPopGen)return; // popover was closed or rebuilt since this fetch started
          if(!s||!s.bucket)return;
          var row=document.getElementById(rid);
          if(!row)return;
          // Same palette as the guide-row SVG bars and signal_update SSE handler (bColors).
          var col={poor:'#e53935',fair:'#fbc02d',good:'#43a047'}[s.bucket]||'#888';
          var lbl={poor:'Poor',fair:'Fair',good:'Good'}[s.bucket]||s.bucket;
          var sig=document.createElement('div');
          sig.className='sig-line';
          sig.style.cssText='font-size:.72rem;color:var(--t3);padding-left:56px;display:flex;align-items:center;gap:5px;flex-wrap:wrap';
          sig.innerHTML='<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:'+col+';flex-shrink:0"></span>'
            +'<span style="color:'+col+';font-weight:600">'+lbl+'</span>'
            +'<span>· '+s.avg+'% avg · '+s.last+'% last · checked '+relTime(s.checked)+'</span>';
          row.appendChild(sig);
        }).catch(function(){});
    });
    // Async guide enrichment for external (not-ours) streams — runs after innerHTML is set.
    // Adds episode title + end time on top of the title WebServer.swift's recsByDevJS already
    // resolved synchronously; keyed off r.external (set server-side whenever a tuned channel
    // isn't matched to one of our own shows) rather than string-matching the title text, so this
    // doesn't silently stop firing if the server-side fallback wording ever changes again.
    recs.forEach(function(r){
      if(r.external!=='1'||!r.ch||r.ch==='?')return;
      var rid='tnr-'+r.tuner.replace(/\W/g,'');
      fetch('/api/now-airing/'+encodeURIComponent(devId)+'/'+encodeURIComponent(r.ch))
        .then(function(res){return res.json();})
        .then(function(g){
          if(gen!==tPopGen)return; // popover was closed or rebuilt since this fetch started
          var row=document.getElementById(rid);
          if(!row)return;
          if(g.title){
            var titleDiv=row.children[1];
            if(titleDiv){
              titleDiv.textContent=g.title;titleDiv.style.cursor='pointer';titleDiv.style.textDecoration='underline dotted';titleDiv.onclick=function(){goToShow(r.ch);};
              // Red dot if we're recording this channel on any device
              var allRecs=Object.values(recsByDev).reduce(function(a,b){return a.concat(b);},[]);
              if(allRecs.some(function(rec){return rec.rec==='1'&&rec.ch===r.ch;})){
                var dot=document.createElement('span');
                dot.style.cssText='display:inline-block;width:8px;height:8px;border-radius:50%;background:#e53935;margin-right:6px;flex-shrink:0;vertical-align:middle';
                titleDiv.insertBefore(dot,titleDiv.firstChild);
              }
            }
          }
          if(g.epTitle){
            var ep=document.createElement('div');
            ep.style.cssText='font-size:.75rem;color:var(--t2);font-style:italic;padding-left:56px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
            ep.textContent=g.epTitle;
            var last=row.lastElementChild;
            row.insertBefore(ep,last&&last.style.fontSize==='.67rem'?last:null);
          }
          if(g.endTime){
            var et=new Date(parseInt(g.endTime,10)*1000);
            var etStr=et.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
            var etDiv=document.createElement('div');
            etDiv.style.cssText='font-size:.72rem;color:var(--t3);padding-left:56px';
            etDiv.textContent='Ends '+etStr;
            var last=row.lastElementChild;
            row.insertBefore(etDiv,last&&last.style.fontSize==='.67rem'?last:null);
          }
          if(g.poster){
            var chRow=row.children[0];
            if(chRow){var img=document.createElement('img');img.src=g.poster;img.loading='lazy';img.style.cssText='width:40px;height:27px;border-radius:3px;object-fit:cover;flex-shrink:0;margin-right:4px;background:#999';img.onerror=function(){this.style.display='none';};chRow.insertBefore(img,chRow.children[1]);}
          }
        }).catch(function(){});
    });
  }
  var statusLink=document.getElementById('t-pop-status');
  if(dt&&dt.surl){statusLink.href=dt.surl;statusLink.style.display='block';}else{statusLink.style.display='none';}
  var pop=document.getElementById('t-pop-c');
  var rect=anchor.getBoundingClientRect();
  var left=Math.min(rect.left,window.innerWidth-410);
  pop.style.left=Math.max(8,left)+'px';
  pop.style.top=(rect.bottom+8)+'px';
  document.getElementById('t-pop').style.display='block';
}
function closeTunerPop(){tPopGen++;document.getElementById('t-pop').style.display='none';}
// Compact relative time for signal "last checked" freshness.
function relTime(epoch){
  if(!epoch)return'never';
  var d=Math.floor(Date.now()/1000)-epoch;
  if(d<60)return'just now';
  if(d<3600)return Math.floor(d/60)+'m ago';
  if(d<86400)return Math.floor(d/3600)+'h ago';
  return Math.floor(d/86400)+'d ago';
}
function goToShow(ch){
  closeTunerPop();
  var now=Math.floor(Date.now()/1000);
  var rows=document.querySelectorAll('.g-row[data-ch="'+ch+'"]');
  for(var i=0;i<rows.length;i++){
    var progs=rows[i].querySelectorAll('.g-prog');
    for(var j=0;j<progs.length;j++){
      var p=progs[j];
      if(+p.dataset.start<=now&&+p.dataset.end>now){p.scrollIntoView({behavior:'smooth',block:'center',inline:'center'});showInfo(p);return;}
    }
  }
}
// Jump from a dropdown show row to its guide block. Closes the dropdown, switches
// the guide to the show's device, then scrolls to and selects the program block.
// Tries exact data-start epoch match first; falls back to currently-airing search.
function jumpToGuide(rowEl){
  var ch=rowEl.dataset.ch,dev=rowEl.dataset.dev,epoch=rowEl.dataset.next;
  document.querySelectorAll('.tdrop').forEach(function(x){x.style.display='none';});
  setDev(dev);
  var p=null;
  if(epoch&&+epoch>0)p=document.querySelector('.g-prog[data-num="'+ch+'"][data-device="'+dev+'"][data-start="'+epoch+'"]');
  if(!p){
    var now=Math.floor(Date.now()/1000);
    document.querySelectorAll('.g-row[data-ch="'+ch+'"]').forEach(function(row){
      if(p)return;
      row.querySelectorAll('.g-prog').forEach(function(prog){
        if(!p&&prog.dataset.device===dev&&+prog.dataset.start<=now&&+prog.dataset.end>now)p=prog;
      });
    });
  }
  if(p){p.scrollIntoView({behavior:'smooth',block:'nearest',inline:'center'});showInfo(p);}
}
// Per-tuner ▾ dropdown: toggle this tuner's show list; close any other open one.
function toggleTunerDrop(dev){
  var d=document.getElementById('tdrop-'+dev);if(!d)return;
  var willOpen=d.style.display==='none';
  document.querySelectorAll('.tdrop').forEach(function(x){x.style.display='none';});
  if(willOpen)d.style.display='block';
}
// Clicking inside a different tuner box closes any open dropdown belonging to another box.
// Clicking completely outside any tuner box also closes open dropdowns.
document.addEventListener('click',function(e){
  var box=e.target.closest&&e.target.closest('.tuner-box');
  if(box){
    document.querySelectorAll('.tdrop').forEach(function(x){if(!box.contains(x))x.style.display='none';});
  } else {
    document.querySelectorAll('.tdrop').forEach(function(x){x.style.display='none';});
  }
  var sBar=e.target.closest&&e.target.closest('#search-bar');
  if(!sBar){closeSearchDrop();closeSearchHelp();}
});
// ── Edit show modal ──
var _editId='',_editPaused=false,_editRec=false,_editType='single',_editPoster='',_editDev='';
var _dayNames=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
var _dayShort=['Su','M','Tu','W','Th','F','Sa'];
function updateDaysVisibility(){
  // Parity with the Record modal: show the day row for single AND dateTime (hidden for
  // series types, which always record every day), with a singular/plural label.
  var show=(_editType==='single'||_editType==='dateTime');
  document.getElementById('em-days-row').style.display=show?'flex':'none';
  if(show)document.getElementById('em-days-lbl').textContent=(_editType==='single')?'Day':'Days';
}
function toggleDay(btn){
  if(btn.classList.contains('sel')&&document.querySelectorAll('#em-days .day-btn.sel').length<=1)return;
  btn.classList.toggle('sel');
}
// Mirrors the native Add/Edit dialog's "Record even if already on disk" toggle
// (show_ignore_duplicate_once) — only meaningful for series types, and only when the
// server-side settings that make duplicate-skipping possible are both on.
function updateDupVisibility(){
  var show=_dupEnabled&&(_editType==='seriesChannel'||_editType==='seriesAll');
  document.getElementById('em-dup-row').style.display=show?'flex':'none';
}
// Mirrors the native Add/Edit dialog's "Skip reruns" toggle (show_new_only) — every type
// except single; unlike Duplicate Episodes above, not gated by any server-side setting.
function updateNewOnlyVisibility(){
  // Clear the checkbox itself, not just the row's visibility — otherwise a check left on from
  // a DateTime/Series pick before switching back to Single silently rides along in the payload.
  if(_editType==='single')document.getElementById('em-new').checked=false;
  document.getElementById('em-new-row').style.display=(_editType==='single')?'none':'flex';
}
// Hidden for seriesAll — that scope floats across every channel the tuner receives, so a
// fixed channel field would misleadingly imply a lock that doesn't exist (mirrors
// EditShowView.swift's identical hide rule for its own Channel field).
function updateChannelRowVisibility(){
  document.getElementById('em-ch-row').style.display=(_editType==='seriesAll')?'none':'flex';
}
// Shows/hides the Channel/All Scope row for the collapsed SeriesID Type segment, and
// (re)renders its two buttons — mirrors ShowFormSection.swift's Scope Picker.
function updateScopeUI(){
  var isSeries=(_editType==='seriesChannel'||_editType==='seriesAll');
  document.getElementById('em-scope-row').style.display=isSeries?'flex':'none';
  if(isSeries)renderScopeRow('em-scope',_editType,function(sv){_editType=sv;updateChannelRowVisibility();});
  updateChannelRowVisibility();
}
function openEditShow(el){
  var d=el.dataset;
  _editId=d.id;_editPaused=d.paused==='1';_editRec=d.recording==='1';_editType=d.type||'single';_editPoster=d.poster||d.logo||'';_editDev=d.dev||'';
  document.getElementById('em-title-in').value=d.title||'';
  document.getElementById('em-ch-in').value=d.ch||'';
  document.getElementById('em-len-in').value=d.length||'60';
  _editChname=d.chname||'';renderEmSignal();
  renderTypeRow('em-type-opts','em-type-desc',_editType,function(v){
    _editType=resolveSeriesTypePick(v,_editType);
    updateDaysVisibility();updateDupVisibility();updateNewOnlyVisibility();updateScopeUI();
  });
  updateScopeUI();
  var selDays=(d.airdays||'').split(',').filter(Boolean);
  var daysEl=document.getElementById('em-days');daysEl.innerHTML='';
  _dayNames.forEach(function(day,i){
    var btn=document.createElement('button');
    btn.type='button';btn.className='day-btn'+(selDays.indexOf(day)>=0?' sel':'');
    btn.textContent=_dayShort[i];btn.dataset.day=day;
    btn.onclick=function(){toggleDay(this);};
    daysEl.appendChild(btn);
  });
  updateDaysVisibility();
  document.getElementById('em-bonus').checked=d.bonus==='1';
  var ebstar=document.getElementById('em-bonus-star');ebstar.textContent='+'+_bonusMins+'m';
  if(d.bonus==='1'){ebstar.style.display='inline-flex';triggerSb('em-bonus-star');}else{ebstar.style.display='none';ebstar.classList.remove('sb-anim');}
  document.getElementById('em-bonus-row').style.display=(!_editRec&&_bonusEnabled)?'flex':'none';
  document.getElementById('em-transcode').value=d.transcode||'none';
  updateEmNoTranscodeWarn();
  document.getElementById('em-dup').checked=d.ignoredup==='1';
  updateDupVisibility();
  document.getElementById('em-new').checked=d.newonly==='1';
  updateNewOnlyVisibility();
  var sid=d.seriesid||'';
  var sidRow=document.getElementById('em-sid-row');
  if(sid){document.getElementById('em-sid').textContent=sid;sidRow.style.display='block';}
  else{sidRow.style.display='none';}
  var fc=parseInt(d.failcount)||0;
  var failRow=document.getElementById('em-fail-row');
  if(fc>0){document.getElementById('em-fail-txt').textContent=fc+' failure'+(fc>1?'s':'')+' — '+(d.failreason||'');failRow.style.display='flex';}
  else{failRow.style.display='none';}
  document.getElementById('em-rec-warn').style.display=_editRec?'block':'none';
  // 'tuners' (from tunerJS) is keyed by every currently-discovered DeviceID, so a show's
  // dev missing from it means that tuner is gone (not just offline-but-known) — flag it
  // rather than silently letting the user edit/save a show that can never record again.
  var devMissing=!!d.dev&&!(d.dev in tuners);
  var devWarn=document.getElementById('em-dev-warn');
  devWarn.style.display=devMissing?'block':'none';
  if(devMissing){document.getElementById('em-dev-warn-txt').textContent='Tuner HDHR-'+d.dev.toUpperCase()+' is no longer detected — delete this show, or leave it as is in case the tuner returns.';}
  var pb=document.getElementById('em-pause');
  // Pausing a show whose tuner is gone accomplishes nothing (there's no future occurrence
  // on that tuner to pause) — hide it like the recording case already does, so the
  // Cancel/Save buttons reflow left via the row's existing flexbox gap instead of leaving
  // a dead slot.
  pb.textContent=_editPaused?'Resume':'Pause';pb.style.display=(_editRec||devMissing)?'none':'inline-block';
  document.getElementById('em-del').textContent=_editRec?'Stop & Delete':'Delete';
  document.getElementById('edit-modal').style.display='flex';
}
function closeEditShow(){document.getElementById('edit-modal').style.display='none';var ebstar=document.getElementById('em-bonus-star');ebstar.style.display='none';ebstar.classList.remove('sb-anim');}
function doEditPause(){
  var pb=document.getElementById('em-pause');
  pb.disabled=true;pb.textContent='…';
  var np=!_editPaused;
  postJSON('/api/edit',{showId:_editId,paused:np})
  .then(function(r){return r.json();})
  .then(function(j){
    pb.disabled=false;
    if(j.ok){_editPaused=np;pb.textContent=_editPaused?'Resume':'Pause';} // /api/edit already broadcasts show_updated over SSE
    else{pb.textContent=_editPaused?'Resume':'Pause';}
  }).catch(function(){pb.disabled=false;pb.textContent=_editPaused?'Resume':'Pause';});
}
function doEditReset(){
  var btn=document.getElementById('em-reset');btn.disabled=true;btn.textContent='…';
  postJSON('/api/edit',{showId:_editId,resetFailures:true})
  .then(function(r){return r.json();})
  .then(function(j){
    btn.disabled=false;btn.textContent='Reset';
    if(j.ok){document.getElementById('em-fail-row').style.display='none';}
  }).catch(function(){btn.disabled=false;btn.textContent='Reset';});
}
function confirmEdit(){
  var btn=document.getElementById('em-save');btn.disabled=true;btn.textContent='Saving…';
  var selDays=Array.from(document.querySelectorAll('#em-days .day-btn.sel')).map(function(b){return b.dataset.day;});
  var payload={
    showId:_editId,showType:_editType,
    title:document.getElementById('em-title-in').value.trim(),
    channel:document.getElementById('em-ch-in').value.trim(),
    length:parseInt(document.getElementById('em-len-in').value)||60,
    bonusTime:document.getElementById('em-bonus').checked,
    transcode:document.getElementById('em-transcode').value,
    airDays:selDays,
    ignoreDuplicateOnce:document.getElementById('em-dup').checked,
    newOnly:document.getElementById('em-new').checked
  };
  postJSON('/api/edit',payload)
  .then(function(r){return r.json();})
  .then(function(j){
    btn.disabled=false;btn.textContent='Save';
    if(j.ok){closeEditShow();} // /api/edit already broadcasts show_updated over SSE
    else{btn.style.background='#6a1010';btn.textContent='Error: '+(j.error||'failed');}
  }).catch(function(){btn.disabled=false;btn.textContent='Save';});
}
function doEditDelete(){
  var title=document.getElementById('em-title-in').value||'';
  showDeleteConfirm(title,_editPoster,_editType,_editRec,performEditDelete);
}
function performEditDelete(){
  var btn=document.getElementById('em-del');
  var lbl=btn.textContent;
  btn.disabled=true;btn.textContent='Deleting…';
  postJSON('/api/delete',{showId:_editId})
  .then(function(r){return r.json();})
  .then(function(j){
    btn.disabled=false;btn.textContent=lbl;
    if(j.ok){closeEditShow();} // deleteShow() already broadcasts show_deleted over SSE
  }).catch(function(){btn.disabled=false;btn.textContent=lbl;});
}
var curDev='';
var _genreFilter='';
// Show-search state: _searchShow is null (no filter active) or {title, seriesId, airings, airingKeys, idx}
// once a dropdown result has been picked. _searchResults/_searchHi track the still-open dropdown's
// last fetch and arrow-key highlight; _searchReqId guards against an in-flight fetch for an older
// query landing after a newer one (fast typing can fire several overlapping requests).
var _searchShow=null;
var _searchResults=[];
var _searchHi=-1;
var _searchDebounce=null;
var _searchReqId=0;
// Errant-keystroke guard: #search-bar is collapsed to just its ⌕ icon until hovered/focused (see
// guide.css), so a single stray key typed at the guide (see the document-level keydown listener
// below) pops it open. If exactly one character sits there with nothing further typed for 5s,
// treat it as an accidental keystroke rather than an abandoned search and clear+collapse it back
// — re-armed on every keystroke via onSearchInput(), cleared once length!=1 or a filter is picked.
var _searchStrayTimer=null;
var _rows=document.querySelectorAll('.g-row');
// Heavy per-program data (synopsis/poster/date/episode), lazy-loaded per row on scroll-into-view
// via /api/guide-detail. Cached by "device:channel:start" so it survives refreshGuide() DOM swaps
// (new elements, same keys) without ever being re-fetched once known.
var _heavyCache=new Map();
// Maps "device:channel" -> the in-flight fetchRowHeavy() promise for that row, so a second
// concurrent caller (e.g. the IntersectionObserver firing while a click's JIT fetch is also
// in flight for the same row) chains onto the real fetch instead of getting a fake
// already-resolved promise that would repaint blank data and never be retried.
var _heavyRowsInFlight=new Map();
function heavyKey(dev,num,start){return dev+':'+num+':'+start;}
function applyHeavyFromCache(el){
  var d=el.dataset;
  var hit=_heavyCache.get(heavyKey(d.device,d.num,d.start));
  if(hit)Object.assign(d,hit);
  return !!hit;
}
function fetchRowHeavy(rowEl){
  if(!rowEl)return Promise.resolve();
  var dev=rowEl.dataset.dev,num=rowEl.dataset.ch;
  if(!dev||!num)return Promise.resolve();
  var rk=dev+':'+num;
  var inFlight=_heavyRowsInFlight.get(rk);
  if(inFlight)return inFlight;
  // Tell the server which window this row's DOM was actually rendered against (instead of
  // letting it recompute "now" server-side) so a lazy fetch long after page load doesn't
  // silently miss entries that have since aged out of the server's current window.
  var p=fetch('/api/guide-detail/'+encodeURIComponent(dev)+'/'+encodeURIComponent(num)+'/'+_winStart+'/'+_winSec)
    .then(function(r){return r.json();})
    .then(function(d){
      (d.entries||[]).forEach(function(entry){_heavyCache.set(heavyKey(dev,num,entry.start),entry);});
      rowEl.querySelectorAll('.g-prog').forEach(applyHeavyFromCache);
    })
    .catch(function(){})
    .finally(function(){_heavyRowsInFlight.delete(rk);});
  _heavyRowsInFlight.set(rk,p);
  return p;
}
var _rowObserver=null;
function initRowObserver(){
  if(_rowObserver)_rowObserver.disconnect();
  var root=document.querySelector('.gw');
  _rowObserver=new IntersectionObserver(function(ents){
    ents.forEach(function(ent){
      if(!ent.isIntersecting)return;
      var row=ent.target;
      var allCached=true;
      row.querySelectorAll('.g-prog').forEach(function(el){if(!applyHeavyFromCache(el))allCached=false;});
      if(!allCached)fetchRowHeavy(row);
      _rowObserver.unobserve(row);
    });
  },{root:root,rootMargin:isVT()?'0px 400px 0px 400px':'400px 0px 400px 0px',threshold:0});
  _rows.forEach(function(r){if(r.dataset.dev)_rowObserver.observe(r);});
}
initRowObserver();
// Hover almost always precedes the click that opens the Summary panel (showInfo->
// renderHeavyFields) by a couple hundred ms — enough for a local fetch to land before the
// click needs it. Warms the same _heavyCache/fetchRowHeavy dedup path the scroll observer
// uses, so a row already cached (or already in flight) is a no-op here, not a second fetch.
// Gated behind a short dwell timer — mouseover fires on every tile the cursor merely passes
// over en route elsewhere (measured: sweeping across a full ~2600-tile grid fired 100+ fetches
// instantly), which flooded the MainActor-serialized server and delayed unrelated click actions
// queued behind that backlog. Only a tile the pointer actually stops on for a beat fetches.
var _hoverPrefetchTimer=null,_hoverPrefetchEl=null;
document.addEventListener('mouseover',function(e){
  var el=e.target.closest&&e.target.closest('.g-prog');
  if(!el||el===_hoverPrefetchEl)return;
  _hoverPrefetchEl=el;
  if(_hoverPrefetchTimer)clearTimeout(_hoverPrefetchTimer);
  if(applyHeavyFromCache(el))return;
  _hoverPrefetchTimer=setTimeout(function(){
    if(_hoverPrefetchEl===el)fetchRowHeavy(el.closest('.g-row'));
  },150);
});
// Single shared dim pass for both filter types (genre select, show search) — they're mutually
// exclusive (selecting one clears the other, see filterGenre/selectSearchShow/clearSearchFilter),
// so at most one of the two branches below is ever live at a time. Keeping them in one function
// means every existing call site (setDev, on every tuner switch and after every guide refresh via
// applyGuidePayload's setDev(curDev)) reapplies whichever filter is active without new wiring.
function applyFilterDim(){
  var f=_genreFilter.toLowerCase();
  var infMode=f==='__inf';
  var newMode=f==='__new';
  document.querySelectorAll('.g-prog').forEach(function(p){
    var isInf=p.dataset.inf==='1';
    var isNew=p.dataset.new==='1';
    var dim;
    if(_searchShow){
      // Exact (device,channel,start) identity match against the server-computed airing set —
      // no client-side title/SeriesID re-derivation, so this can't drift from what
      // /api/guide-search already decided belongs to the selected show.
      dim=!_searchShow.airingKeys.has(p.dataset.device+':'+p.dataset.num+':'+p.dataset.start);
    }
    else if(newMode){dim=!isNew;}
    else if(infMode){dim=!isInf;}
    else{dim=(f&&(p.dataset.genre||'').toLowerCase()!==f)||isInf;}
    p.classList.toggle('g-prog-dim',dim);
    // Dimmed cells are pointer-events:none (CSS) already; mirror that for keyboard/screen-reader
    // reachability too, so a filtered-out show isn't tab-focusable or announced as if it were live.
    p.tabIndex=dim?-1:0;
    if(dim)p.setAttribute('aria-hidden','true');else p.removeAttribute('aria-hidden');
  });
}
function setDev(id){
  var switched=id!==curDev;
  // Both filters are scoped to "the tuner you're viewing" (search explicitly, genre because
  // rebuildGenreFilter only offers genres seen on curDev) — a switch invalidates either.
  if(switched){_genreFilter='';var sel=document.getElementById('genre-sel');if(sel)sel.value='';clearSearchFilter();}
  curDev=id;
  if(switched)rebuildGenreFilter();
  // Empty id means "no specific tuner filter" — only ever passed for a single-online-tuner setup
  // (see WebServer.swift's defaultDev comment; never happens with >1 tuner). Highlight that one
  // tuner's box as selected too, instead of leaving every box unhighlighted just because there's
  // nothing to disambiguate it from. Offline boxes render as a <span> with no data-dev, so they
  // never match here regardless.
  var onlineBtns=document.querySelectorAll('.d-btn[data-dev]');
  document.querySelectorAll('.d-btn').forEach(function(b){
    b.classList.toggle('d-sel', id ? b.dataset.dev===id : onlineBtns.length===1&&b===onlineBtns[0]);
  });
  var seen={};
  _rows.forEach(function(r){
    if(id){r.style.display=r.dataset.dev===id?'':'none';}
    else{var ch=r.dataset.ch;if(!seen[ch]){r.style.display='';seen[ch]=true;}else{r.style.display='none';}}
  });
  applyFilterDim();
  // Show/hide a section header (.g-fav-sep/.g-rec-sep) per device, based on whether any of its
  // visible rows carry the matching marker attribute (data-fav/data-rec).
  function toggleSectionSep(selector,attr){
    document.querySelectorAll(selector).forEach(function(sep){
      var dev=sep.dataset.dev;
      var has=Array.from(_rows).some(function(r){
        return r.style.display!=='none'&&r.dataset[attr]==='1'&&r.dataset.dev===dev;
      });
      sep.style.display=has?'':'none';
    });
  }
  toggleSectionSep('.g-fav-sep','fav');
  toggleSectionSep('.g-rec-sep','rec');
}
// First click on a tuner's name button switches the guide grid to that tuner (setDev);
// a second click — the tuner is already selected — opens its hardware-occupancy popover
// instead (formerly a separate "X/Y — FULL" button nested inside the ▾ show-list dropdown,
// which testing showed users couldn't find). id===curDev is the same "already selected" check
// setDev itself uses for its switched flag.
// Single-online-tuner setups bootstrap with setDev('') (see WebServer.swift's defaultDev), so
// curDev starts out '' while the button's own id is the real device ID — id===curDev alone
// would never match on that very first click, forcing a spurious extra click before the popover
// ever opened even though the tuner already reads as selected (.d-sel, applied by this same
// onlineBtns.length===1 rule in setDev above). Recognize that case as "already selected" too.
function handleDevClick(id,btn){
  var onlineBtns=document.querySelectorAll('.d-btn[data-dev]');
  var alreadySel=(id===curDev)||(curDev===''&&onlineBtns.length===1&&btn===onlineBtns[0]);
  if(alreadySel){showTunerInfo(id,btn);}
  else{setDev(id);}
}
function filterGenre(g){
  _genreFilter=g;
  // Mutually exclusive with show search — picking a genre while a show filter is active clears it.
  if(g&&_searchShow)clearSearchFilter();
  applyFilterDim();
}
// ── Show search ──
// Single-online-tuner setups bootstrap with curDev==='' (see setDev's own comment above) — the
// search endpoint needs a real device id, so fall back to the lone online tuner button's id the
// same way handleDevClick does.
function searchDeviceId(){
  if(curDev)return curDev;
  var b=document.querySelectorAll('.d-btn[data-dev]');
  return b.length===1?b[0].dataset.dev:'';
}
// #search-icon-btn's onclick — a click/Enter/Space activation without a lingering hover (e.g.
// keyboard Tab+Enter) needs an explicit push into focus; :focus-within (guide.css) then keeps the
// box expanded from there exactly like a mouse hover does.
function expandSearch(){
  var inp=document.getElementById('search-in');
  if(inp)inp.focus();
}
// (Re)arms the 5s errant-keystroke clear whenever exactly one character is in the box; cancels
// any pending timer otherwise (more was typed, it was cleared, or a filter was picked). Re-checks
// the length/filter state at fire time, not just at arm time, since a lot can happen in 5s.
function armSearchStrayTimer(){
  if(_searchStrayTimer){clearTimeout(_searchStrayTimer);_searchStrayTimer=null;}
  if(_searchShow)return;
  var inp=document.getElementById('search-in');
  if(!inp||inp.value.length!==1)return;
  _searchStrayTimer=setTimeout(function(){
    _searchStrayTimer=null;
    if(_searchShow||inp.value.length!==1)return; // something real happened since arming
    inp.value='';
    onSearchInput();
    inp.blur(); // releases :focus-within so the collapsed icon-only state returns (guide.css)
  },5000);
}
// #search-icon-btn's own disclosure state — distinct from #search-in's aria-expanded, which
// already means "the results dropdown is open" (a combobox's own ARIA pattern; see
// renderSearchDrop/closeSearchDrop). :hover/:focus-within drive the box's actual CSS
// expand/collapse (guide.css) directly with no JS involved; this just mirrors that same
// condition onto the icon button's aria-expanded for assistive tech, via the live pseudo-class
// query rather than duplicating hover/focus state in a second place that could drift out of sync.
function syncSearchIconAria(){
  var bar=document.getElementById('search-bar');
  var btn=document.getElementById('search-icon-btn');
  if(!bar||!btn)return;
  var open=bar.classList.contains('has-filter')||bar.matches(':hover')||bar.matches(':focus-within');
  btn.setAttribute('aria-expanded',open?'true':'false');
}
(function(){
  var bar=document.getElementById('search-bar');
  if(!bar)return;
  ['mouseenter','mouseleave','focusin','focusout'].forEach(function(ev){bar.addEventListener(ev,syncSearchIconAria);});
})();
function closeSearchDrop(){
  var d=document.getElementById('search-drop');
  if(d){d.style.display='none';d.innerHTML='';}
  _searchHi=-1;
  var inp=document.getElementById('search-in');
  if(inp)inp.setAttribute('aria-expanded','false');
}
// ⓘ help popover — same on/off toggle + outside-click-closes pattern as the tuner ▾ dropdowns
// and the search results dropdown, just a static explainer instead of live data.
function toggleSearchHelp(evt){
  evt.stopPropagation(); // otherwise this same click would immediately re-close it, below
  var p=document.getElementById('search-help');
  var btn=document.getElementById('search-info-btn');
  var willOpen=p.style.display==='none';
  closeSearchDrop(); // mutually exclusive with the results dropdown — no room for both
  p.style.display=willOpen?'block':'none';
  if(btn)btn.setAttribute('aria-expanded',willOpen?'true':'false');
}
function closeSearchHelp(){
  var p=document.getElementById('search-help');
  if(p)p.style.display='none';
  var btn=document.getElementById('search-info-btn');
  if(btn)btn.setAttribute('aria-expanded','false');
}
// "#5.1"-style query — jump the grid to the first *currently visible* row (respecting setDev's
// per-device show/hide, same scope the genre filter/show search already use) whose channel number
// starts with the digits after "#", live on every keystroke with no Enter needed. Mirrors
// hdhr_guide's own channel-jump (docs/TUIGuide.md's "Search / channel-jump") — same "first prefix
// match wins" rule, not a stricter "only when unambiguous" one. No-op (stays put) if nothing
// currently visible matches yet, e.g. mid-typing "#13" before the ".1" that disambiguates it.
function jumpToChannelPrefix(prefix){
  if(!prefix)return;
  var row=Array.prototype.find.call(_rows,function(r){
    return r.style.display!=='none'&&r.dataset.ch&&r.dataset.ch.indexOf(prefix)===0;
  });
  if(row)row.scrollIntoView({behavior:'smooth',block:'nearest',inline:'nearest'});
}
function onSearchInput(){
  closeSearchHelp(); // typing again means they're past reading the ⓘ explainer
  armSearchStrayTimer();
  var inp=document.getElementById('search-in');
  var q=inp.value.trim();
  if(_searchDebounce)clearTimeout(_searchDebounce);
  if(q.charAt(0)==='#'){
    _searchReqId++; // same invalidation as the length<3 case below — no show-search fetch applies here
    closeSearchDrop();_searchResults=[];
    jumpToChannelPrefix(q.slice(1));
    return;
  }
  if(q.length<3){
    _searchReqId++; // invalidate any in-flight fetch so it can't repaint a dropdown after the fact
    closeSearchDrop();_searchResults=[];
    return;
  }
  _searchDebounce=setTimeout(function(){runSearch(q);},200);
}
function runSearch(q){
  var dev=searchDeviceId();
  if(!dev)return;
  var reqId=++_searchReqId;
  fetch('/api/guide-search/'+encodeURIComponent(dev)+'/'+encodeURIComponent(q))
    .then(function(r){return r.json();})
    .then(function(d){
      if(reqId!==_searchReqId)return; // superseded by a newer query/backspace since this fetch started
      _searchResults=d.shows||[];
      renderSearchDrop();
    })
    .catch(function(){});
}
function renderSearchDrop(){
  var d=document.getElementById('search-drop');
  var inp=document.getElementById('search-in');
  if(!d)return;
  _searchHi=-1;
  if(_searchResults.length===0){
    d.innerHTML='<div class="search-empty">No matches</div>';
  } else {
    d.innerHTML=_searchResults.map(function(s,i){
      var next=s.airings[0];
      var sub=s.airings.length>1?(s.airings.length+' airings'):(next?hej(next.chName):'');
      var img=s.poster?'<img src="'+hej(s.poster)+'" loading="lazy" onerror="this.style.display=\'none\'">'
                       :'<div class="search-row-noart"></div>';
      return '<div class="search-row" role="option" aria-selected="false" data-idx="'+i+'" onclick="selectSearchShow(_searchResults['+i+'])">'
        +img+'<div class="search-row-txt"><div class="search-row-title">'+hej(s.title)+'</div><div class="search-row-sub">'+sub+'</div></div>'
        +'</div>';
    }).join('');
  }
  d.style.display='block';
  if(inp)inp.setAttribute('aria-expanded','true');
}
function highlightSearchRow(idx){
  var rows=document.querySelectorAll('#search-drop .search-row');
  rows.forEach(function(r,i){
    var hi=i===idx;
    r.classList.toggle('search-hi',hi);
    r.setAttribute('aria-selected',hi?'true':'false');
  });
  if(idx>=0&&rows[idx])rows[idx].scrollIntoView({block:'nearest'});
}
function onSearchKeydown(event){
  if(_searchShow){
    // Chip mode (a show is already selected): Escape/Backspace/Delete clears back to an editable,
    // empty search box. Left/Right episode-cycling is handled globally (see the document-level
    // listener below) so it keeps working after focus leaves the input — e.g. after clicking a
    // dropdown row, which blurs it — not just while the input itself is focused.
    if(event.key==='Escape'||event.key==='Backspace'||event.key==='Delete'){event.preventDefault();clearSearchFilter();}
    return;
  }
  var d=document.getElementById('search-drop');
  var open=d&&d.style.display!=='none'&&_searchResults.length>0;
  if(event.key==='ArrowDown'){
    if(!open)return;
    event.preventDefault();
    _searchHi=(_searchHi+1)%_searchResults.length;
    highlightSearchRow(_searchHi);
  } else if(event.key==='ArrowUp'){
    if(!open)return;
    event.preventDefault();
    _searchHi=(_searchHi-1+_searchResults.length)%_searchResults.length;
    highlightSearchRow(_searchHi);
  } else if(event.key==='Enter'){
    if(!open)return;
    event.preventDefault();
    selectSearchShow(_searchResults[_searchHi>=0?_searchHi:0]);
  } else if(event.key==='Escape'){
    var help=document.getElementById('search-help');
    var helpOpen=help&&help.style.display!=='none';
    if(open||helpOpen){event.preventDefault();closeSearchDrop();closeSearchHelp();}
  }
}
function selectSearchShow(show){
  if(!show)return;
  if(_searchStrayTimer){clearTimeout(_searchStrayTimer);_searchStrayTimer=null;}
  closeSearchDrop();
  var airingKeys=new Set(show.airings.map(function(a){return a.device+':'+a.ch+':'+a.start;}));
  _searchShow={title:show.title,seriesId:show.seriesId,airings:show.airings,airingKeys:airingKeys,idx:0};
  // Mutually exclusive with the genre filter.
  _genreFilter='';
  var gsel=document.getElementById('genre-sel');
  if(gsel)gsel.value='';
  var inp=document.getElementById('search-in');
  if(inp)inp.readOnly=true;
  var clr=document.getElementById('search-clear');
  if(clr)clr.style.display='';
  // A selected show must stay expanded (showing its chip) even after the mouse leaves and the
  // click that picked it blurs the input — :hover/:focus-within (guide.css) can't cover that, so
  // this is the one case that needs an explicit class.
  var bar=document.getElementById('search-bar');
  if(bar)bar.classList.add('has-filter');
  syncSearchIconAria();
  applyFilterDim();
  jumpToSearchAiring();
  updateSearchCounter();
}
function clearSearchFilter(){
  if(!_searchShow)return;
  _searchShow=null;
  var inp=document.getElementById('search-in');
  if(inp){inp.readOnly=false;inp.value='';}
  var clr=document.getElementById('search-clear');
  if(clr)clr.style.display='none';
  var bar=document.getElementById('search-bar');
  if(bar)bar.classList.remove('has-filter');
  syncSearchIconAria();
  closeSearchDrop();
  applyFilterDim();
}
function updateSearchCounter(){
  var inp=document.getElementById('search-in');
  if(!inp||!_searchShow)return;
  var n=_searchShow.airings.length;
  inp.value=_searchShow.title+(n>1?' ('+(_searchShow.idx+1)+'/'+n+')':'');
}
function jumpToSearchAiring(){
  if(!_searchShow)return;
  var a=_searchShow.airings[_searchShow.idx];
  if(!a)return;
  var p=document.querySelector('.g-prog[data-device="'+a.device+'"][data-num="'+a.ch+'"][data-start="'+a.start+'"]');
  if(p){p.scrollIntoView({behavior:'smooth',block:'nearest',inline:'center'});showInfo(p);}
}
function cycleSearchEpisode(delta){
  if(!_searchShow)return;
  var next=_searchShow.idx+delta;
  if(next<0||next>=_searchShow.airings.length)return; // clamp — no wraparound past a real boundary
  _searchShow.idx=next;
  jumpToSearchAiring();
  updateSearchCounter();
}
// Global Left/Right episode-cycling while a show search filter is active — not scoped to
// #search-in's own focus, since selecting a dropdown result with the mouse blurs the input
// (mousedown on the non-focusable .search-row moves focus to <body>) and arrow keys should still
// work afterward without clicking back into the search box. Skips when a modal is open or focus
// is genuinely inside an editable text field (a Record/Edit modal's title input) so it can't
// steal caret-movement keys from those — #search-in itself is readOnly in chip mode, so it's
// exempted from that check rather than blocking its own bubbled keydown.
function anyGuideModalOpen(){
  return ['rec-modal','edit-modal','del-confirm-modal'].some(function(id){
    var el=document.getElementById(id);
    return el&&el.style.display!=='none';
  });
}
document.addEventListener('keydown',function(e){
  if(!_searchShow)return;
  if(e.key!=='ArrowLeft'&&e.key!=='ArrowRight')return;
  var ae=document.activeElement;
  var editable=ae&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA')&&ae.id!=='search-in'&&!ae.readOnly;
  if(editable||anyGuideModalOpen())return;
  e.preventDefault();
  cycleSearchEpisode(e.key==='ArrowRight'?1:-1);
});
// Type-to-search: #search-bar is collapsed to its ⌕ icon (guide.css) until hovered/focused, but a
// user shouldn't have to reach for the mouse first — typing a plain character anywhere in the
// guide (nothing else focused/editable, no modal open, no filter chip already active) pops the
// box open, focuses it, and seeds it with the very key that was pressed, same as if they'd
// clicked in and typed it themselves. A single stray key left sitting there with nothing further
// typed self-clears after 5s (armSearchStrayTimer, called via onSearchInput below) so an
// incidental keystroke aimed at the guide doesn't leave the search box parked open.
document.addEventListener('keydown',function(e){
  // Cheapest checks first — plain property reads, no DOM — since the overwhelming majority of
  // keydowns in normal guide use (arrow-key episode cycling, Tab, Escape, modified shortcuts)
  // fail one of these and should never reach anyGuideModalOpen()'s 3 DOM lookups below.
  if(_searchShow)return;
  if(e.metaKey||e.ctrlKey||e.altKey)return; // leave real shortcuts (Cmd+R, etc.) alone
  // Space is excluded even though it's technically a printable character: every .g-prog block is
  // role="button" tabindex="0" with its own onkeydown activating on Space (WebServer.swift's
  // buildGuideGridHTML), and native <button>s (the theme switcher, tuner ▾, etc.) activate on
  // Space's keyup gated on this keydown's default not being prevented — hijacking it here would
  // both mis-fire a spurious search AND (via our own preventDefault below) silently break Space
  // as a keyboard-activation key everywhere else in the guide.
  if(e.key.length!==1||e.key===' ')return; // printable characters only — not Tab/Shift/F-keys/etc.
  if(anyGuideModalOpen())return;
  var inp=document.getElementById('search-in');
  if(!inp||document.activeElement===inp)return; // already open — let the input's own handler run
  var ae=document.activeElement;
  // SELECT included even though it's not "editable" text — a focused <select> (e.g. #genre-sel)
  // has its own native type-to-jump-to-option behavior that this listener would otherwise break.
  var editable=ae&&(ae.tagName==='INPUT'||ae.tagName==='TEXTAREA'||ae.tagName==='SELECT'||ae.isContentEditable);
  if(editable)return; // don't steal keystrokes aimed at a genuinely different form control
  e.preventDefault(); // also stops Firefox's own "quick find" from opening on '/' or "'"
  // "/" is the dedicated "open search" key (matching hdhr_guide's own Mode.search entry point,
  // docs/TUIGuide.md's "Search / channel-jump") — it opens/focuses the box but isn't itself typed
  // into it, unlike every other printable character below. Resets any leftover uncommitted text
  // first, so "/" always hands you a fresh, empty, focused box rather than resuming whatever was
  // typed and abandoned last time — the same "always starts clean" behavior beginSearch() gives
  // the TUI.
  if(e.key==='/'){
    inp.value='';
    inp.focus();
    onSearchInput();
    return;
  }
  inp.value=e.key;
  inp.focus();
  inp.setSelectionRange(inp.value.length,inp.value.length); // caret after the seeded key, not before it
  onSearchInput();
});
function toggleFav(evt,btn){
  evt.stopPropagation();
  var row=btn.closest('.g-row');
  if(!row)return;
  postJSON('/api/toggle-favorite',{deviceId:row.dataset.dev,guideNumber:row.dataset.ch})
  .catch(function(){}); // handleToggleFavorite already broadcasts favorite_toggled over SSE
}
// Rebuilds the genre filter from whatever's actually on the currently-viewed tuner's guide right
// now (scoped by data-device to curDev, so switching tuners shows that tuner's own genres — not a
// stale union from whichever tuner happened to be selected at page load). Re-run after every guide
// data pull (applyGuidePayload) and every tuner switch (setDev) so the list never goes stale.
function rebuildGenreFilter(){
  var sel=document.getElementById('genre-sel');
  if(!sel)return;
  while(sel.options.length>1)sel.remove(1); // keep the static "All genres" placeholder
  var scope=curDev?'.g-prog[data-genre][data-device="'+curDev+'"]':'.g-prog[data-genre]';
  var gs=new Set();
  document.querySelectorAll(scope).forEach(function(p){var g=p.dataset.genre;if(g)gs.add(g);});
  var infScope=curDev?'.g-prog[data-inf="1"][data-device="'+curDev+'"]':'.g-prog[data-inf="1"]';
  var newScope=curDev?'.g-prog[data-new="1"][data-device="'+curDev+'"]':'.g-prog[data-new="1"]';
  var hasInf=document.querySelector(infScope)!==null;
  var hasNew=document.querySelector(newScope)!==null;
  var bar=document.getElementById('genre-bar');
  if(gs.size<2&&!hasInf&&!hasNew){bar.style.display='none';return;}
  Array.from(gs).sort().forEach(function(g){var o=document.createElement('option');o.value=g;o.textContent=g;sel.appendChild(o);});
  if(hasNew){var o=document.createElement('option');o.value='__new';o.textContent='New';sel.appendChild(o);}
  if(hasInf){var o=document.createElement('option');o.value='__inf';o.textContent='Infomercials';sel.appendChild(o);}
  bar.style.display='';
}
setDev('{{DEFAULT_DEV}}');
rebuildGenreFilter();
// scrollToNow + live now-line: recompute position from winStart/winSec every 30 s
var _winStart={{WIN_START}},_winSec={{WIN_SEC}};
function nowPct(){return Math.max(0,Math.min(100,(Math.floor(Date.now()/1000)-_winStart)/_winSec*100));}
// Reads a CSS custom property live off <html> rather than hardcoding its value, since
// breakpoints (guide.css's/guide-vertical.css's small-screen overrides) can change it.
function cssVar(name,fallback){return parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name))||fallback;}
// Sticky channel-column width — .gi's scrollWidth includes it.
function chW(){return cssVar('--ch-w',125);}
// Sticky channel-header height (vertical time-axis mode's counterpart to chW()) — --ch-h is
// what .g-ch/.g-hdr-ch use as their height when isVT() is true.
function chH(){return cssVar('--ch-h',52);}
function updateNowLine(){
  var p=nowPct(),vt=isVT();
  document.querySelectorAll('.g-now-bar,.g-now-tick').forEach(function(el){
    if(vt){el.style.left='';el.style.top=p+'%';}else{el.style.top='';el.style.left=p+'%';}
  });
  // If the now-line has drifted past 75% of the viewport, nudge back to 25%.
  // If the user has scrolled ahead, the now-line is near the leading edge (<75%) so we leave them alone.
  var gw=document.querySelector('.gw'),gi=document.querySelector('.gi');
  if(!gw||!gi)return;
  if(vt){
    var ch=chH(),nowPy=ch+(gi.scrollHeight-ch)*(p/100);
    if(nowPy>gw.scrollTop+gw.clientHeight*0.75)
      gw.scrollTop=Math.max(0,nowPy-gw.clientHeight*0.25);
  }else{
    var cw=chW(),nowPx=cw+(gi.scrollWidth-cw)*(p/100);
    if(nowPx>gw.scrollLeft+gw.clientWidth*0.75)
      gw.scrollLeft=Math.max(0,nowPx-gw.clientWidth*0.25);
  }
}
function scrollToNow(){
  var gw=document.querySelector('.gw');var gi=document.querySelector('.gi');if(!gw||!gi)return;
  if(isVT()){var ch=chH(),nowPy=ch+(gi.scrollHeight-ch)*(nowPct()/100);gw.scrollTop=Math.max(0,nowPy-gw.clientHeight*0.25);}
  else{var cw=chW(),nowPx=cw+(gi.scrollWidth-cw)*(nowPct()/100);gw.scrollLeft=Math.max(0,nowPx-gw.clientWidth*0.25);}
}
// Manually pins .g-hdr (the time ruler) to the left edge while scrolling through channel
// columns in vertical mode — see guide-vertical.css's comment on .g-hdr for why this isn't
// done with position:sticky (observed failing on-device: sticky along the left/inline axis
// inside a flex row is a known weak spot in WebKit). Re-queries .g-hdr each call since
// refreshGuide() replaces it (a fresh .gi innerHTML swap), same as the g-now-btn pattern.
function syncHdrPin(){
  var hdr=document.querySelector('.g-hdr');
  if(!hdr)return;
  // Clears any stale transform from a portrait->landscape rotation — horizontal mode's .g-hdr
  // is sticky-top, not translated, so a leftover translateX would shift it off to the side.
  if(!isVT()){hdr.style.transform='';return;}
  var gw=document.querySelector('.gw');
  if(!gw)return;
  hdr.style.transform='translateX('+gw.scrollLeft+'px)';
}
(function(){
  // .gw itself persists across refreshGuide() DOM swaps (only .gi's innerHTML is replaced),
  // so this listener never needs re-attaching — same reasoning as the scrollbar/now-button IIFEs.
  var gw=document.querySelector('.gw');
  if(gw)gw.addEventListener('scroll',syncHdrPin,{passive:true});
})();
// Defer auto-select and initial scroll to after first paint so the guide grid is
// the LCP element instead of the externally-fetched show poster image.
requestAnimationFrame(function(){
  var nowTs=Math.floor(Date.now()/1000);
  var first=Array.from(_rows).find(function(r){return r.style.display!=='none';});
  if(first){
    var prog=Array.from(first.querySelectorAll('.g-prog')).find(function(el){return +el.dataset.start<=nowTs&&+el.dataset.end>nowTs;});
    if(prog)showInfo(prog);
  }
  scrollToNow();
  syncHdrPin();
  // Remove splash after first paint. If it loaded fast it's still invisible (delayed CSS animation);
  // if it's already visible, fade it out first.
  requestAnimationFrame(function(){
    var sp=document.getElementById('splash');
    if(!sp)return;
    var vis=parseFloat(getComputedStyle(sp).opacity)>0.05;
    if(vis){sp.style.animation='none';sp.style.transition='opacity .3s ease';sp.style.opacity='0';setTimeout(function(){if(sp.parentNode)sp.parentNode.removeChild(sp);},320);}
    else{sp.parentNode.removeChild(sp);}
  });
});
// Snap the red line to the true current time immediately — setInterval's first tick
// doesn't fire for 60s, and the position server-rendered into the cached GET / page
// reflects whenever prebuildPageHTML() last ran (up to ~1h stale on an hourly guide
// refresh cycle), not the moment this specific browser actually loaded it.
updateNowLine();
setInterval(updateNowLine,60000);
// Page-staleness: reload if the server version changes (redeploy) or the baked-in expiry has passed.
(function(){
  var _ver='{{APP_VERSION}}',_exp={{VER_EXP_TS}};
  function checkFreshness(){
    if(Date.now()>_exp){location.reload();return;}
    fetch('/api/ping').then(function(r){return r.json();}).then(function(j){
      if(j.version&&j.version!==_ver)location.reload();
    }).catch(function(){});
  }
  setInterval(checkFreshness,60000);
})();
// SSE: receive push events and refresh guide content in place (scroll + selection preserved)
(function(){
  if(!window.EventSource)return;
  var es=new EventSource('/api/events');
  es.onmessage=function(e){
    try{
      var d=JSON.parse(e.data);
      if(!d||!d.type)return;
      if(d.type==='tuner_update'&&d.counts){
        Object.keys(d.counts).forEach(function(dev){
          var c=d.counts[dev],a=c.a,t=c.t;
          // Refresh "nt" on an existing entry too (not just the fresh-entry fallback) — cheap, and
          // keeps it from ever silently going stale relative to what the server just sent.
          if(tuners[dev]){tuners[dev].a=a;tuners[dev].nt=c.nt;}else{tuners[dev]={t:t,a:a,surl:'',nt:c.nt};}
          var tb=document.getElementById('tun-'+dev);
          if(tb&&t>0){var full=a>=t;tb.textContent=a+'/'+t+(full?' — FULL':'');if(full)tb.classList.add('t-info-full');else tb.classList.remove('t-info-full');}
        });
      } else if(d.type==='signal_update'&&d.gname&&d.bucket){
        // Inline DOM update — no full reload needed
        var bColors={poor:'#e53935',fair:'#fbc02d',good:'#43a047'};
        var bc=bColors[d.bucket]||null;
        document.querySelectorAll('.g-row[data-gname="'+d.gname+'"]').forEach(function(row){
          var sig=row.querySelector('.g-sig');
          if(!bc){if(sig)sig.remove();return;}
          var svgStr='<svg class="g-sig" viewBox="0 0 11 10" width="11" height="10">'
            +'<rect x="0" y="6" width="3" height="4" fill="'+bc+'"/>'
            +'<rect x="4" y="3" width="3" height="7" fill="'+(d.bucket!=='poor'?bc:'#555')+'"/>'
            +'<rect x="8" y="0" width="3" height="10" fill="'+(d.bucket==='good'?bc:'#555')+'"/>'
            +'</svg>';
          var tmp=document.createElement('div');tmp.innerHTML=svgStr;
          if(sig){sig.replaceWith(tmp.firstChild);}
          else{var cn=row.querySelector('.g-cn');if(cn)cn.appendChild(tmp.firstChild);}
        });
      } else if(d.gridZ||d.sumphZ||d.tdropZ){
        // Compressed guide-change event — broadcastGuideChangeEvent gzip+base64's whatever of
        // grid/sumph/tdrop actually shrank (see its own comment in WebServer.swift), falling back
        // per-field to the plain key when it didn't, so any mix of *Z/plain keys can appear
        // together. Decode whichever *Z keys are present, fall back to the plain d.grid/d.sumph
        // string when its *Z sibling is absent, then hand the reassembled plain {grid,sumph,tdrop}
        // shape to the same applyGuidePayload the plain branch below uses. Falls back to a full
        // refreshGuide() fetch (a normal HTTP response, decompressed by fetch() at the transport
        // level regardless of this browser's DecompressionStream support) when that API is missing,
        // rather than silently doing nothing until the next reload.
        if(!window.DecompressionStream){refreshGuide();return;}
        var tdropZKeys=Object.keys(d.tdropZ||{});
        Promise.all([
          d.gridZ ? decodeGzipB64(d.gridZ) : Promise.resolve(d.grid||''),
          d.sumphZ ? decodeGzipB64(d.sumphZ) : Promise.resolve(d.sumph||''),
          Promise.all(tdropZKeys.map(function(k){return decodeGzipB64(d.tdropZ[k]);}))
        ]).then(function(res){
          var tdrop=Object.assign({},d.tdrop||{});
          tdropZKeys.forEach(function(k,i){tdrop[k]=res[2][i];});
          applyGuidePayload({grid:res[0],sumph:res[1],tdrop:tdrop});
        }).catch(function(){});
      } else if(d.grid){
        // Guide-change event (guide_refreshed/show_added/show_updated/show_deleted/
        // favorite_toggled) — server already rebuilt the grid once for everyone; apply
        // it directly instead of triggering our own refreshGuide() fetch+rebuild.
        // Must be checked before the d.sumPh||d.tdrop branch below: this payload's
        // "tdrop" is a {device:html} object (see applyGuidePayload), not the single-
        // string shape that branch expects.
        applyGuidePayload(d);
      } else if(d.sumPh||d.tdrop){
        // Fragment push — apply inline without a full page fetch
        if(d.sumPh){var ph=document.getElementById('sum-ph');if(ph)ph.innerHTML=d.sumPh;}
        // Update just the affected tuner's shows (tdrop-body, not the full tdrop with its header).
        if(d.tdrop&&d.tdropDev){var td=document.getElementById('tdrop-body-'+d.tdropDev);if(td)td.innerHTML=d.tdrop;}
        // For recording events: toggle recording state on the currently-airing guide entry
        // and push fresh tuner counts so the badge and popover stay accurate.
        if((d.type==='recording_started'||d.type==='recording_stopped')&&d.channel&&d.device){
          var isRec=d.type==='recording_started';
          var nowTs=Math.floor(Date.now()/1000);
          document.querySelectorAll('.g-prog[data-num="'+d.channel+'"][data-device="'+d.device+'"]').forEach(function(el){
            var s=parseInt(el.dataset.start,10),en=parseInt(el.dataset.end,10);
            if(s<=nowTs&&en>nowTs){
              if(isRec){
                el.classList.add('g-prog-rec','g-st-rec');el.classList.remove('g-prog-now','g-st-sched','g-st-conflict');
              } else {
                el.classList.remove('g-prog-rec','g-st-rec');el.classList.add('g-prog-now');
              }
            }
          });
          if(d.tunerT>0){
            if(tuners[d.device])tuners[d.device].a=d.tunerA;
            else tuners[d.device]={t:d.tunerT,a:d.tunerA,surl:''};
            var tb=document.getElementById('tun-'+d.device);
            if(tb){var full=d.tunerA>=d.tunerT;tb.textContent=d.tunerA+'/'+d.tunerT+(full?' — FULL':'');if(full)tb.classList.add('t-info-full');else tb.classList.remove('t-info-full');}
          }
        }
      } else if(d.devbar){
        // deviceOnline/deviceOffline — swap the dev-bar's tuner boxes in place instead
        // of falling through to refreshGuide(), whose payload never touches #dev-bar.
        // buildDevBarHTML always renders every .tdrop closed (it has no notion of client
        // UI state), so a bare innerHTML swap would silently close whichever tuner's
        // dropdown the user currently has open — at most one is ever open at a time
        // (toggleTunerDrop closes the rest), so just remember its id and reopen it.
        var db=document.getElementById('dev-bar');
        if(db){
          var openId=null;
          db.querySelectorAll('.tdrop').forEach(function(x){if(x.style.display==='block')openId=x.id;});
          // If the user has a dropdown open whose device is absent from the incoming dev-bar
          // (device fully gone and referenced by no scheduled show), skip the swap so the open
          // dropdown isn't silently destroyed — the next full refresh reconciles the bar.
          var skip=false;
          if(openId){var tmp=document.createElement('div');tmp.innerHTML=d.devbar;if(!tmp.querySelector('[id="'+openId+'"]'))skip=true;}
          if(!skip){
            db.innerHTML=d.devbar;
            if(openId){var reopened=document.getElementById(openId);if(reopened)reopened.style.display='block';}
          }
        }
      } else {
        refreshGuide();
      }
    }catch(x){}
  };
})();
// ── Now button visibility: show only when the red now-line is left of the visible scroll area ──
(function(){
  var gw=document.querySelector('.gw');
  var gi=document.querySelector('.gi');
  if(!gw||!gi)return;
  // Shows a few pixels early — while the now-line is still just barely on-screen — rather
  // than waiting for it to fully scroll out of view first.
  var NOW_BTN_MARGIN=5;
  function check(){
    // Re-query each call: refreshGuide() replaces .gi innerHTML, detaching any cached ref.
    var btn=document.getElementById('g-now-btn');
    if(!btn)return;
    if(isVT()){
      var ch=chH(),nowPy=ch+(gi.scrollHeight-ch)*(nowPct()/100);
      btn.classList.toggle('g-now-vis',nowPy<gw.scrollTop+NOW_BTN_MARGIN);
    }else{
      var cw=chW(),nowPx=cw+(gi.scrollWidth-cw)*(nowPct()/100);
      btn.classList.toggle('g-now-vis',nowPx<gw.scrollLeft+NOW_BTN_MARGIN);
    }
  }
  gw.addEventListener('scroll',check,{passive:true});
  // Rotation flips which of gw.scrollTop/scrollLeft check() reads (via isVT()) — the 5s poll
  // eventually catches up, but resyncing immediately avoids a visibly-stale button in the meantime.
  _orientMq.addEventListener('change',check);
  setInterval(check,5000);
  check();
})();
// ── Custom horizontal scrollbar ───────────────────────────────────────
(function(){
  var gw=document.querySelector('.gw');
  var gi=document.querySelector('.gi');
  var track=document.getElementById('g-hscroll');
  var thumb=document.getElementById('g-hscroll-thumb');
  if(!gw||!gi||!track||!thumb)return;
  function syncThumb(){
    // Hidden entirely when isVT() is true (vertical mode) — the horizontal axis there is
    // channels, not time, and the native vertical scrollbar covers time-axis navigation instead.
    if(isVT()){track.style.display='none';return;}
    var trackW=track.clientWidth;
    var maxScroll=gi.scrollWidth-gw.clientWidth;
    if(maxScroll<=0){track.style.display='none';return;}
    track.style.display='';
    var thumbW=Math.max(40,trackW*(gw.clientWidth/gi.scrollWidth));
    var thumbLeft=maxScroll>0?(gw.scrollLeft/maxScroll)*(trackW-thumbW):0;
    thumb.style.width=thumbW+'px';
    thumb.style.left=thumbLeft+'px';
  }
  gw.addEventListener('scroll',syncThumb,{passive:true});
  window.addEventListener('resize',syncThumb);
  // Belt-and-suspenders alongside the resize listener above — orientationchange and resize
  // don't fire in a strictly guaranteed order/timing across browsers, and syncThumb() itself
  // is idempotent, so an explicit rotation listener removes any doubt about a stale thumb.
  _orientMq.addEventListener('change',syncThumb);
  syncThumb();
  var _dragX,_dragSL;
  thumb.addEventListener('mousedown',function(e){
    _dragX=e.clientX;_dragSL=gw.scrollLeft;
    thumb.classList.add('g-dragging');e.preventDefault();
    function onMove(e){
      var maxScroll=gi.scrollWidth-gw.clientWidth;
      var delta=(e.clientX-_dragX)/(track.clientWidth-thumb.clientWidth)*maxScroll;
      gw.scrollLeft=Math.max(0,Math.min(maxScroll,_dragSL+delta));
    }
    function onUp(){thumb.classList.remove('g-dragging');document.removeEventListener('mousemove',onMove);document.removeEventListener('mouseup',onUp);}
    document.addEventListener('mousemove',onMove);document.addEventListener('mouseup',onUp);
  });
  track.addEventListener('click',function(e){
    if(e.target===thumb)return;
    var rect=track.getBoundingClientRect();
    var thumbW=thumb.clientWidth;
    var frac=(e.clientX-rect.left-thumbW/2)/(track.clientWidth-thumbW);
    var maxScroll=gi.scrollWidth-gw.clientWidth;
    gw.scrollLeft=Math.max(0,Math.min(maxScroll,frac*maxScroll));
  });
  // Shift+scroll → horizontal scroll (standard convention for timeline navigation)
  gw.addEventListener('wheel',function(e){
    if(!e.shiftKey)return;
    e.preventDefault();
    gw.scrollLeft+=e.deltaY*1.5;
  },{passive:false});
})();

// Pull-to-refresh (touch only). .gw persists across refreshGuide()'s own DOM swaps (only .gi's
// innerHTML is replaced), so these listeners are attached once and never need re-wiring.
// Deliberately calls refreshGuide() — the same in-place AJAX path the SSE fallback already uses
// — instead of a native page reload: applyGuidePayload() preserves scroll position and
// re-selects whatever program was already selected, so pulling to refresh keeps you looking at
// the same part of the grid instead of jumping to "now" the way a fresh page load's auto-select-
// on-load + scrollToNow() would.
(function(){
  var PULL_TRIGGER=32, PULL_MAX=72, PULL_DAMPING=0.5;
  var gw=document.querySelector('.gw'), spin=document.querySelector('.pull-spin');
  if(!gw||!spin)return;
  var startY=0,startX=0,dist=0,pulling=false,refreshing=false;
  function resetPull(animated){
    if(animated)gw.classList.add('pull-snap');
    gw.style.transform='';
    spin.classList.remove('visible','spinning');
    dist=0;pulling=false;
    if(animated)setTimeout(function(){gw.classList.remove('pull-snap');},200);
  }
  gw.addEventListener('touchstart',function(e){
    if(refreshing||e.touches.length!==1||gw.scrollTop>0){startY=-1;return;}
    startY=e.touches[0].clientY;startX=e.touches[0].clientX;
  },{passive:true});
  gw.addEventListener('touchmove',function(e){
    if(startY<0||refreshing)return;
    var dy=e.touches[0].clientY-startY, dx=Math.abs(e.touches[0].clientX-startX);
    // Bail on an upward drag, a mostly-horizontal gesture (channel-row/time-axis panning), or
    // having scrolled away from the top mid-gesture — only a clean pull-down-from-top continues.
    if(dy<=0||dx>dy||gw.scrollTop>0){ if(pulling)resetPull(false); startY=-1; return; }
    pulling=true;
    e.preventDefault(); // suppress the rubber-band bounce while actively driving the pull ourselves
    dist=Math.min(PULL_MAX,dy*PULL_DAMPING);
    gw.style.transform='translateY('+dist+'px)';
    spin.classList.toggle('visible',dist>8);
    spin.style.transform='rotate('+(dist/PULL_MAX*360)+'deg)';
  },{passive:false});
  gw.addEventListener('touchend',function(){
    startY=-1;
    if(!pulling)return;
    if(dist<PULL_TRIGGER){resetPull(true);return;}
    refreshing=true;
    gw.classList.add('pull-snap');
    gw.style.transform='translateY(40px)';
    spin.classList.add('spinning');
    var minDelay=new Promise(function(res){setTimeout(res,400);}); // perceptible even on a fast LAN
    Promise.all([refreshGuide(),minDelay]).then(function(){
      refreshing=false;
      resetPull(true);
    });
  },{passive:true});
})();
