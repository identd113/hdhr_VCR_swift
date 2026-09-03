# Application Flow

How a request, a show, or a recording actually moves through the app — from tuner discovery at launch to the file that lands on disk, and everywhere that state gets pushed back out: the menu bar, the LAN web guide, Discord, in-app playback, and a peer instance's virtual tuner relay.

**Reading the lines:** a **thick** edge is the critical recording write path. A **dotted** edge crosses a real process/network boundary — HTTP, SSE push, a Discord webhook, or UDP discovery. A thin solid edge is an ordinary in-process call. Edge color marks which subsystem a hop *leaves from*; each subsystem also gets one consistent color on its nodes and its subgraph panel.

```mermaid
%%{init: {"flowchart": {"curve":"basis", "nodeSpacing":34, "rankSpacing":54}}}%%
flowchart TB
    subgraph SU["Startup"]
        Launch["hdhr_VCRApp.init()<br/>MenuBarExtra"] --> State["AppState<br/>@MainActor"]
        State --> Cfg["ConfigManager<br/>loads JSON config"]
        State --> Disc["HDHRManager<br/>discovers tuners"]
        State --> Guide["GuideStore<br/>fetches EPG"]
        State --> Loop["idleLoop() begins"]
    end

    subgraph SC["Scheduling engine"]
        Loop -->|"every tick"| Check{"show due<br/>to record?"}
        Guide -->|"guide entries"| Check
        Check ==>|"yes"| StartRec["startRecording()"]
        Loop -->|"tuner missing / back"| AutoPause["auto‑pause /<br/>auto‑resume"]
        AutoPause -->|"marks"| Marker["show_fail_reason =<br/>'Tuner not detected'"]
        Marker -.->|"pass 2 skips<br/>marked shows"| WindowExpiry["window‑expiry<br/>auto‑resume (pass 2)"]
    end

    subgraph RC["Recording"]
        StartRec ==> Gate{"tuner supports<br/>transcode?"}
        Gate ==>|"no"| ForceNone["force transcode = none"]
        Gate ==>|"yes"| KeepProfile["use show's<br/>saved profile"]
        ForceNone ==> Spawn["RecordingManager<br/>spawns curl"]
        KeepProfile ==> Spawn
        Spawn ==> Disk[("recording file<br/>on disk")]
        Spawn --> SleepAssert["IOKit sleep<br/>assertion held"]
    end

    subgraph NT["Push &amp; notify"]
        Spawn -.->|"start / stop"| SSE["WebServer<br/>broadcastRecordingEvent()"]
        Spawn -.->|"start / stop"| DiscordQueue["showRuntime[id]<br/>.discordCardTask chain"]
        DiscordQueue -.->|"sequential"| DiscordCard["fireDiscordCard()<br/>→ webhook"]
    end

    subgraph UI["Menu bar UI"]
        Menu["MenuContent"] --> Forms["Add / Edit Show"]
        Forms --> Mutate["AppState<br/>addShow / updateShow"]
        Mutate --> Cfg
        Mutate -.->|"broadcast"| SSE
        Menu --> WatchNow["Watch Now!"]
    end

    subgraph PB["Playback"]
        WatchNow --> Bridge["VLCBridge /<br/>VLCPlayerView"]
        Bridge --> LiveOrRelay{"own in‑progress<br/>recording?"}
        LiveOrRelay -->|"no — live channel"| LiveStream["live tuner stream<br/>(occupies a tuner)"]
        LiveOrRelay -->|"yes"| RelayStream["/api/watch-recording<br/>local relay"]
        RelayStream --> Disk
        LiveStream --> Occupancy["activeTunerCount()<br/>= max(hw count,<br/>recording + VLC)"]
        RelayStream -.->|"excluded via<br/>vlcOccupiesTuner"| Occupancy
    end

    subgraph WEB["Web guide — :1980"]
        Browser["Browser /<br/>embedded WKWebView"] -.->|"HTTP"| Server["WebServer<br/>NWListener"]
        Server -.->|"record / pause / delete"| Mutate
        SSE -.->|"push"| Browser
        Guide -->|"entries"| Matcher["ManagedGuideMatcher<br/>.owner(for:)"]
        Matcher --> Badge{"already recorded?<br/>(skip‑cache)"}
        Badge -->|"no"| SchedRing["blue ⏱ status ring"]
        Badge -->|"yes"| SkipRing["slate ⏭ skip ring"]
        SchedRing --> Server
        SkipRing --> Server
    end

    subgraph VT["Virtual tuner relay"]
        Disk -.->|"while recording"| FakeTuner["VirtualTunerService<br/>advertises fake tuner"]
        FakeTuner -.->|"UDP discovery"| SelfFilter["excludingOwnVirtualTuner()<br/>drops own relay"]
        SelfFilter -.->|"UDP discovery"| Peer["peer instance<br/>on the LAN"]
        Peer -.->|"relays in‑progress file"| Disk
        Peer -->|"isVirtualRelay<br/>backstop"| WatchOnly["watch‑only:<br/>addShow / handleRecord reject it"]
    end

    classDef startup stroke:#6478b8,stroke-width:1.6px;
    classDef schedule stroke:#9576c9,stroke-width:1.6px;
    classDef record stroke:#d64545,stroke-width:1.8px;
    classDef notify stroke:#c9963e,stroke-width:1.6px;
    classDef ui stroke:#3fa66a,stroke-width:1.6px;
    classDef playback stroke:#d98a4f,stroke-width:1.6px;
    classDef web stroke:#3fa0c2,stroke-width:1.6px;
    classDef relay stroke:#b06bab,stroke-width:1.6px;
    classDef store stroke-width:1.4px;

    class Launch,State,Cfg,Disc,Guide,Loop startup
    class Check,AutoPause,Marker,WindowExpiry schedule
    class StartRec,Gate,ForceNone,KeepProfile,Spawn,SleepAssert record
    class SSE,DiscordQueue,DiscordCard notify
    class Menu,Forms,Mutate,WatchNow ui
    class Bridge,LiveOrRelay,LiveStream,RelayStream,Occupancy playback
    class Browser,Server,Matcher,Badge,SchedRing,SkipRing web
    class FakeTuner,SelfFilter,Peer,WatchOnly relay
    class Disk store

    style SU stroke:#6478b8
    style SC stroke:#9576c9
    style RC stroke:#d64545
    style NT stroke:#c9963e
    style UI stroke:#3fa66a
    style PB stroke:#d98a4f
    style WEB stroke:#3fa0c2
    style VT stroke:#b06bab

    linkStyle 0,1,2,3,4,5,6,8,36 stroke:#6478b8
    linkStyle 7,9,10 stroke:#9576c9
    linkStyle 11,12,13,14,15,16,17,18,19 stroke:#d64545
    linkStyle 20,35 stroke:#c9963e
    linkStyle 21,22,23,24,25,26 stroke:#3fa66a
    linkStyle 27,28,29,30,31,32 stroke:#d98a4f
    linkStyle 33,34,37,38,39,40,41 stroke:#3fa0c2
    linkStyle 43,44,45,46 stroke:#b06bab
```

## Reading it

- **Startup** — Tuner discovery runs known-hosts, mDNS, and UDP concurrently; the idle loop doesn't start scheduling until a lineup and guide exist.
- **Scheduling engine** — `idleLoop()` re-resolves each show by ID on every tick. Auto-pause marks a tuner-missing show with a fail-reason string so the older, generic window-expiry pass knows to leave it alone instead of fighting over it.
- **Transcode gate** — The one place a show's saved transcode profile gets overridden — only when the physical tuner can't actually transcode — plus the sleep assertion that keeps the Mac awake for the duration.
- **Push & notify** — SSE and Discord sends fire independently off the same event; Discord sends for one show are chained behind each other so two lifecycle events can't race and duplicate a card.
- **Menu bar UI** — Add/Edit Show writes through the same `AppState` mutators the web guide calls — there is only one path that persists a show.
- **Playback** — Watch Now! either opens a live tuner stream (counts toward tuner occupancy) or, for a show that's currently recording, relays it from disk instead — that path is explicitly excluded from the tuner count.
- **Web guide** — A second front door on the LAN, not a separate state machine. It also renders the status ring per guide entry — scheduled (blue) or already-recorded (skip, slate) — from the same managed-show data.
- **Virtual tuner relay** — While a recording is active, this instance impersonates a second HDHomeRun so a peer can watch the same file without opening a real tuner — self-filtered out of its own device list, and hard-limited to watch-only everywhere a show gets created.

Every write path funnels through `AppState`; every state change fans back out through push (SSE, Discord) rather than any client polling for it.
