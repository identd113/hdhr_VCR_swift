# Application Flow

How a request, a show, or a recording actually moves through the app — from tuner discovery at launch to the file that lands on disk, and everywhere that state gets pushed back out: the menu bar, the LAN web guide, Discord, and a peer instance's Watch Now.

**Reading the lines:** a **thick** edge is the critical recording write path. A **dotted** edge crosses a real process/network boundary — HTTP, SSE push, a Discord webhook, or UDP discovery. A thin solid edge is an ordinary in-process call. Each subsystem below also gets one consistent color, on its nodes, its subgraph panel, and its outgoing arrows.

```mermaid
%%{init: {"flowchart": {"curve":"basis", "nodeSpacing":36, "rankSpacing":58}}}%%
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
    end

    subgraph RC["Recording"]
        StartRec ==> Gate{"tuner supports<br/>transcode?"}
        Gate ==>|"no"| ForceNone["force transcode = none"]
        Gate ==>|"yes"| KeepProfile["use show's<br/>saved profile"]
        ForceNone ==> Spawn["RecordingManager<br/>spawns curl"]
        KeepProfile ==> Spawn
        Spawn ==> Disk[("recording file<br/>on disk")]
    end

    subgraph NT["Push &amp; notify"]
        Spawn -.->|"start / stop"| SSE["WebServer<br/>broadcastRecordingEvent()"]
        Spawn -.->|"start / stop"| DiscordCard["fireDiscordCard()<br/>→ webhook"]
    end

    subgraph UI["Menu bar UI"]
        Menu["MenuContent"] --> Forms["Add / Edit Show"]
        Forms --> Mutate["AppState<br/>addShow / updateShow"]
        Mutate --> Cfg
        Mutate -.->|"broadcast"| SSE
    end

    subgraph WEB["Web guide — :1980"]
        Browser["Browser /<br/>embedded WKWebView"] -.->|"HTTP"| Server["WebServer<br/>NWListener"]
        Server -.->|"record / pause / delete"| Mutate
        SSE -.->|"push"| Browser
    end

    subgraph VT["Virtual tuner relay"]
        Disk -.->|"while recording"| FakeTuner["VirtualTunerService<br/>advertises fake tuner"]
        FakeTuner -.->|"UDP discovery"| Peer["peer instance<br/>on the LAN"]
        Peer -.->|"relays in‑progress file"| Disk
    end

    classDef startup stroke:#6478b8,stroke-width:1.6px;
    classDef schedule stroke:#9576c9,stroke-width:1.6px;
    classDef record stroke:#d64545,stroke-width:1.8px;
    classDef notify stroke:#c9963e,stroke-width:1.6px;
    classDef ui stroke:#3fa66a,stroke-width:1.6px;
    classDef web stroke:#3fa0c2,stroke-width:1.6px;
    classDef relay stroke:#b06bab,stroke-width:1.6px;
    classDef store stroke-width:1.4px;

    class Launch,State,Cfg,Disc,Guide,Loop startup
    class Check,AutoPause schedule
    class StartRec,Gate,ForceNone,KeepProfile,Spawn record
    class SSE,DiscordCard notify
    class Menu,Forms,Mutate ui
    class Browser,Server web
    class FakeTuner,Peer relay
    class Disk store

    style SU stroke:#6478b8
    style SC stroke:#9576c9
    style RC stroke:#d64545
    style NT stroke:#c9963e
    style UI stroke:#3fa66a
    style WEB stroke:#3fa0c2
    style VT stroke:#b06bab

    linkStyle 7,9,10,11,12,13,14 stroke:#d64545
    linkStyle 15,16,20,23 stroke:#c9963e
    linkStyle 21,22 stroke:#3fa0c2
    linkStyle 24,25,26 stroke:#b06bab
```

## Reading it

- **Startup** — Tuner discovery runs known-hosts, mDNS, and UDP concurrently; the idle loop doesn't start scheduling until a lineup and guide exist.
- **Scheduling engine** — `idleLoop()` re-resolves each show by ID on every tick — never a cached index — because the list can mutate mid-await from the web UI.
- **Transcode gate** — The one place a show's saved transcode profile gets overridden, and only when the physical tuner can't actually transcode.
- **Push & notify** — SSE and Discord sends fire independently off the same event, each chained per-show so two lifecycle events can't race and duplicate a card.
- **Menu bar UI** — Add/Edit Show writes through the same `AppState` mutators the web guide calls — there is only one path that persists a show.
- **Web guide** — A second front door on the LAN, not a separate state machine — every mutating request still lands on the same `AppState` the menu bar uses.
- **Virtual tuner relay** — While a recording is active, this instance impersonates a second HDHomeRun so a peer can watch the same file without opening a real tuner.

Every write path funnels through `AppState`; every state change fans back out through push (SSE, Discord) rather than any client polling for it.
