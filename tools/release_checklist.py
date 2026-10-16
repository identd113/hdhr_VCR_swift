#!/usr/bin/env python3
"""tools/release_checklist.py — docs/Distribution.md's "Release Checklist", automated (everything except the build).

`./deploy_release.sh <version>` is the BUILD script (compile, sign, notarize, DMG) and is unchanged. This script is the
checklist around it: the checks before the build and the notes / GitHub Release / README steps after it, in order:

  release_checklist.py preflight <version> [--tests] [--ui]    read-only readiness report (exit 1 on any ✗)
  release_checklist.py stamp     <version> [--date YYYY-MM-DD]  CHANGELOG "## Unreleased" -> "## v<version> — <date>",
                                                               sync the bundled copy + RELEASES' date (re-run keeps it)
  release_checklist.py notes     <version>                      write dist/release-<version>/notes.md (Release notes)
  release_checklist.py publish   <version> [--yes] [--live]     create the GitHub Release from the DMG; with --live
                                                               also update README's "Latest" heading + link.
                                                               Dry run unless --yes; a DRAFT unless --live.

Typical day:
  1. tools/release_checklist.py preflight 2.6.5 --tests        # fix anything marked ✗
  2. tools/release_checklist.py stamp 2.6.5 && git commit …    # changelog now says v2.6.5
  3. ./deploy_release.sh 2.6.5                       # build, sign, notarize, DMG  (not run by this script)
  4. tools/release_checklist.py notes 2.6.5
  5. git push (commit Version.swift first), then
     tools/release_checklist.py publish 2.6.5 --yes            # draft Release with the DMG; review it on GitHub
     tools/release_checklist.py publish 2.6.5 --yes --live     # publish it and update README's Latest heading + link

It never pushes, tags by itself, builds or edits anything outside the repo. Set RELEASE_REPO_ROOT to run
it against a copy (that is how it is tested).
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.environ.get("RELEASE_REPO_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
CHANGELOG_COPY = os.path.join(ROOT, "Sources/hdhr_VCR/CHANGELOG.md")
RELEASES = os.path.join(ROOT, "RELEASES.md")
README = os.path.join(ROOT, "README.md")
DIST = os.path.join(ROOT, "dist")
NOTARY_PROFILE = "hdhrVCR-notary"
REPO_SLUG = "identd113/hdhr_VCR_swift"
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

OK, BAD, WARN = "✓", "✗", "!"
problems = 0


def say(mark, text):
    global problems
    if mark == BAD:
        problems += 1
    print(f"  {mark} {text}")


def sh(args, check=False, cwd=None, timeout=120):
    r = subprocess.run(args, cwd=cwd or ROOT, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        sys.exit(f"command failed: {' '.join(args)}\n{r.stderr or r.stdout}")
    return r


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def last_tag():
    r = sh(["git", "describe", "--tags", "--abbrev=0"])
    return r.stdout.strip().lstrip("v") if r.returncode == 0 else None


def check_version(version):
    if not SEMVER.match(version):
        sys.exit(f"'{version}' is not a plain semantic version (e.g. 2.6.5, no leading 'v')")


# ── RELEASES.md helpers ──────────────────────────────────────────────────────

def releases_section(version):
    """The text of RELEASES.md's `## v<version> (…)` entry (heading included), or None."""
    text = read(RELEASES)
    m = re.search(rf"^## v{re.escape(version)} \(.*?\)\n", text, re.M)
    if not m:
        return None
    nxt = re.search(r"^## v\d", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    return text[m.start():end]


# ── live app state (same source the live UI tests use) ──────────────────────

def live_config_shows():
    d = os.path.expanduser("~/Library/Application Support/hdhrVCRplus")
    try:
        files = sorted((f for f in os.listdir(d) if f.startswith("hdhr_VCR-") and f.endswith(".json")),
                       key=lambda f: os.path.getmtime(os.path.join(d, f)), reverse=True)
        with open(os.path.join(d, files[0]), encoding="utf-8") as fh:
            return json.load(fh).get("shows", [])
    except (OSError, IndexError, ValueError):
        return None


# ── preflight ────────────────────────────────────────────────────────────────

def preflight(args):
    v = args.version
    check_version(v)
    print(f"Release preflight for v{v}\n")

    print("Version & git")
    tag = last_tag()
    if tag and vtuple(v) <= vtuple(tag):
        say(BAD, f"v{v} is not newer than the last tag v{tag}")
    else:
        say(OK, f"v{v} is newer than the last tag v{tag}")
    if sh(["git", "tag", "-l", f"v{v}"]).stdout.strip():
        say(BAD, f"tag v{v} already exists")
    branch = sh(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    say(OK if branch == "main" else WARN, f"on branch {branch}")
    dirty = [l for l in sh(["git", "status", "--short"]).stdout.splitlines() if "Version.swift" not in l]
    say(OK if not dirty else BAD, "working tree clean" if not dirty else f"uncommitted changes: {', '.join(l[3:] for l in dirty[:4])}")
    if "Version.swift" in sh(["git", "status", "--short"]).stdout:
        say(WARN, "Version.swift (build stamp) is modified — commit it before pushing")
    since = sh(["git", "rev-list", "--count", f"v{tag}..HEAD"]).stdout.strip() if tag else "?"
    say(OK, f"{since} commits since v{tag}")
    ahead = sh(["git", "rev-list", "--count", "origin/main..HEAD"]).stdout.strip()
    say(OK if ahead == "0" else WARN, "HEAD is pushed" if ahead == "0" else f"{ahead} commits not pushed yet (publish needs them pushed)")

    print("\nRelease notes")
    cl = read(CHANGELOG)
    stamped = re.search(rf"^## v{re.escape(v)} — ", cl, re.M) is not None
    unreleased = re.search(r"^## Unreleased\n(.*?)(?=^## )", cl, re.S | re.M)
    n_entries = len([l for l in (unreleased.group(1) if unreleased else "").splitlines() if l.startswith("- ")])
    if stamped:
        say(OK, f"CHANGELOG.md already has the v{v} section (stamped)")
    elif n_entries:
        say(OK, f"CHANGELOG.md has {n_entries} Unreleased entries — `release_checklist.py stamp {v}` will turn them into v{v}")
    else:
        say(BAD, "CHANGELOG.md has no Unreleased entries and no v%s section" % v)
    say(OK if read(CHANGELOG) == read(CHANGELOG_COPY) else BAD,
        "Sources/hdhr_VCR/CHANGELOG.md is a byte copy" if read(CHANGELOG) == read(CHANGELOG_COPY)
        else "Sources/hdhr_VCR/CHANGELOG.md differs — cp CHANGELOG.md Sources/hdhr_VCR/CHANGELOG.md")
    sec = releases_section(v)
    if not sec:
        say(BAD, f"RELEASES.md has no '## v{v} (date)' entry")
    else:
        say(OK if len(sec.splitlines()) >= 15 else WARN, f"RELEASES.md entry: {len(sec.splitlines())} lines")
    readme = read(README)
    m = re.search(r"### 📦 Latest: \[v([0-9.]+)\]", readme)
    if m:
        say(OK, f"README 'Latest' currently points at v{m.group(1)}")
    else:
        say(BAD, "README has no '### 📦 Latest' section")

    print("\nBuild tooling")
    ident_file = os.path.join(ROOT, "tools/signing_identity.txt")
    ident = read(ident_file).strip() if os.path.exists(ident_file) else ""
    if not ident:
        say(BAD, "tools/signing_identity.txt missing (tools/setup_signing.sh)")
    else:
        certs = sh(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
        say(OK if ident in certs else BAD, "Developer ID certificate is in the keychain" if ident in certs else "signing identity not found in the keychain")
    r = sh(["xcrun", "notarytool", "history", "--keychain-profile", NOTARY_PROFILE], timeout=60)
    say(OK if r.returncode == 0 else BAD, "notarytool profile '%s' works" % NOTARY_PROFILE if r.returncode == 0 else "notarytool profile unusable (tools/setup_signing.sh)")
    say(OK if shutil.which("create-dmg") else BAD, "create-dmg installed" if shutil.which("create-dmg") else "create-dmg missing (brew install create-dmg)")
    gh = shutil.which("gh") and sh(["gh", "auth", "status"]).returncode == 0
    say(OK if gh else BAD, "gh is logged in" if gh else "gh missing or not logged in")
    free = shutil.disk_usage(ROOT).free / 1e9
    say(OK if free > 5 else BAD, f"{free:.0f} GB free for the build")

    print("\nSafe to rebuild now? (deploy_release.sh relaunches the app)")
    shows = live_config_shows()
    if shows is None:
        say(WARN, "could not read the live config")
    else:
        mocks = [s["show_title"] for s in shows if s.get("show_title", "").startswith("[MOCK]")]
        say(OK if not mocks else BAD, "no [MOCK] shows" if not mocks else f"[MOCK] shows left: {mocks} (tools/mock_scenario.py clean)")
        rec = [s["show_title"] for s in shows if s.get("show_recording")]
        say(OK if not rec else WARN, "nothing recording" if not rec else f"recording now: {rec} (a relaunch reattaches, but wait if you can)")
        soon = []
        now = datetime.datetime.now(datetime.timezone.utc)
        for s in shows:
            n = s.get("show_next")
            if n and s.get("show_active") and not s.get("show_paused"):
                try:
                    mins = (datetime.datetime.fromisoformat(n.replace("Z", "+00:00")) - now).total_seconds() / 60
                except ValueError:
                    continue
                if -2 < mins < 45:
                    soon.append(f"{s['show_title']} in {mins:.0f} min")
        say(OK if not soon else WARN, "no real recording due in the next 45 min" if not soon else "due soon: " + "; ".join(soon))

    if args.tests:
        print("\nTests (swift build && swift test)")
        r = sh(["swift", "build"], timeout=900)
        say(OK if r.returncode == 0 else BAD, "swift build" if r.returncode == 0 else "swift build FAILED:\n" + r.stderr[-600:])
        r = sh(["swift", "test"], timeout=1800)
        tail = [l for l in (r.stdout + r.stderr).splitlines() if "Test run with" in l][-1:]
        say(OK if r.returncode == 0 else BAD, (tail[0] if tail else "swift test") if r.returncode == 0 else "swift test FAILED")
    if args.ui:
        print("\nUI suite (needs the app running + Accessibility; ~5 min)")
        env = dict(os.environ, RUN_WINDOW_NAV_TESTS="1")
        r = subprocess.run(["swift", "test", "--filter", "WindowNavigationTests"], cwd=ROOT, capture_output=True, text=True, env=env, timeout=3600)
        tail = [l for l in (r.stdout + r.stderr).splitlines() if "Test run with" in l][-1:]
        say(OK if r.returncode == 0 else BAD, tail[0] if tail else "UI suite")

    print()
    if problems:
        print(f"✗ {problems} blocking problem(s) — fix, then run preflight again.")
        sys.exit(1)
    print("Ready. Next: stamp → ./deploy_release.sh %s → notes → push → publish." % v)


# ── stamp ────────────────────────────────────────────────────────────────────

def stamp(args):
    v = args.version
    check_version(v)
    cl = read(CHANGELOG)
    existing = re.search(rf"^## v{re.escape(v)} — ([0-9-]+)\n", cl, re.M)
    if existing:
        date = args.date or existing.group(1)           # re-running never silently re-dates a stamped release
        if date != existing.group(1):
            cl = cl[:existing.start(1)] + date + cl[existing.end(1):]
            write(CHANGELOG, cl)
            print(f"CHANGELOG.md: v{v} re-dated to {date}")
        else:
            print(f"CHANGELOG.md already has v{v} — {date}; nothing to stamp.")
    else:
        date = args.date or datetime.date.today().isoformat()
        m = re.search(r"^## Unreleased\n", cl, re.M)
        if not m:
            sys.exit("CHANGELOG.md has no '## Unreleased' section to stamp")
        body = re.search(r"^## Unreleased\n(.*?)(?=^## |\Z)", cl, re.S | re.M).group(1)
        if not any(l.startswith("- ") for l in body.splitlines()):
            sys.exit("'## Unreleased' has no entries")
        # Precedent (v2.5.0, v2.6.0 at their tags): no Unreleased heading is left behind — the first change after the
        # release adds one again, so the About screen never shows an empty section.
        cl = cl[:m.start()] + f"## v{v} — {date}\n" + cl[m.end():]
        write(CHANGELOG, cl)
        print(f"CHANGELOG.md: Unreleased → v{v} — {date}")
    write(CHANGELOG_COPY, read(CHANGELOG))
    print("Sources/hdhr_VCR/CHANGELOG.md synced")
    rel = read(RELEASES)
    new = re.sub(rf"^(## v{re.escape(v)} )\([0-9-]+\)", rf"\1({date})", rel, count=1, flags=re.M)
    if new != rel:
        write(RELEASES, new)
        print(f"RELEASES.md heading date → {date}")
    elif releases_section(v) is None:
        print(f"! RELEASES.md has no v{v} entry yet")
    print("\nNext: review `git diff`, commit, then ./deploy_release.sh %s" % v)


# ── notes ────────────────────────────────────────────────────────────────────

def unwrap_markdown(text):
    """RELEASES.md is hard-wrapped at ~105 columns for reading in an editor. GitHub's Release page renders every single
    newline as a <br> (comment-style), so a wrapped paragraph shows ragged mid-sentence breaks — join each paragraph and each
    list item onto one line. Headings, rules and blank lines are left alone; a list gets a blank line before it."""
    out = []
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            if out and out[-1] != "":
                out.append("")
            continue
        is_item = re.match(r"^\s*([-*]|\d+\.)\s+", line) is not None
        is_block = re.match(r"^#{1,6}\s", stripped) is not None or re.match(r"^-{3,}$", stripped) is not None
        prev = out[-1] if out else ""
        if is_block:
            if prev != "":
                out.append("")
            out.append(stripped)
        elif is_item:
            prev_is_item = re.match(r"^\s*([-*]|\d+\.)\s+", prev) is not None
            if prev != "" and not prev_is_item:
                out.append("")
            out.append(line)
        else:
            continues = prev != "" and not re.match(r"^#{1,6}\s", prev) and not re.match(r"^-{3,}$", prev)
            if continues:
                out[-1] = prev + " " + stripped
            else:
                out.append(stripped)
    return "\n".join(out).strip() + "\n"


def notes(args):
    v = args.version
    check_version(v)
    sec = releases_section(v)
    if not sec:
        sys.exit(f"RELEASES.md has no '## v{v} (date)' entry")
    body = sec
    body = re.sub(r"^## v.*\n+", "", body, count=1)            # GitHub shows the title itself
    body = re.sub(r"\n---\s*$", "", body.rstrip()).rstrip()
    body = unwrap_markdown(body).rstrip()
    body += (f"\n\n---\n**Download** `hdhrVCRplus-{v}.dmg` below — Apple Silicon, macOS 15 or later, notarized. "
             f"Full change list: [CHANGELOG](https://github.com/{REPO_SLUG}/blob/v{v}/CHANGELOG.md).\n")
    out_dir = os.path.join(DIST, f"release-{v}")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "notes.md")
    write(path, body)
    print(f"wrote {path} ({len(body.splitlines())} lines)")


# ── publish ──────────────────────────────────────────────────────────────────

def publish(args):
    v = args.version
    check_version(v)
    dmg = os.path.join(DIST, f"hdhrVCRplus-{v}.dmg")
    notes_path = os.path.join(DIST, f"release-{v}", "notes.md")
    sec = releases_section(v)
    plan = []
    if not os.path.exists(dmg):
        sys.exit(f"{dmg} not found — run ./deploy_release.sh {v} first")
    if not os.path.exists(notes_path):
        sys.exit(f"{notes_path} not found — run `release_checklist.py notes {v}` first")
    if sh(["git", "tag", "-l", f"v{v}"]).stdout.strip():
        sys.exit(f"tag v{v} already exists locally")
    if sh(["git", "rev-list", "--count", "origin/main..HEAD"]).stdout.strip() != "0":
        sys.exit("HEAD is not pushed — the Release must point at a pushed commit (commit Version.swift, push, retry)")
    gh_create = ["gh", "release", "create", f"v{v}", "--title", f"v{v}", "--notes-file", notes_path,
                 "--target", sh(["git", "rev-parse", "HEAD"]).stdout.strip()]
    if not args.live:
        gh_create.append("--draft")
    gh_create.append(dmg)
    plan.append(" ".join(gh_create) + ("   (or, if the draft already exists: gh release edit --draft=false)" if args.live else ""))
    if args.live:
        plan.append(f"README.md 'Latest' heading → v{v} + new download link (the bullets under it are NOT touched), then `git commit` (not pushed)")
    print("Plan:" if not args.yes else "Doing:")
    for p in plan:
        print("  •", p)
    if not args.yes:
        print("\nDry run. Add --yes to do it" + (" (--live publishes it; without --live it is created as a DRAFT)." if not args.live else "."))
        return
    draft = args.live and sh(["gh", "release", "view", f"v{v}", "--json", "isDraft", "--jq", ".isDraft"]).stdout.strip() == "true"
    if draft:       # the draft from the first run: publish it, don't create the release (and upload the DMG) again
        sh(["gh", "release", "edit", f"v{v}", "--draft=false"], check=True, timeout=120)
    else:
        sh(gh_create, check=True, timeout=900)
    print(f"GitHub Release v{v} {'published' if args.live else 'created as a draft — review it, then run again with --live'}")
    if args.live:
        text = read(README)
        heading = f"### 📦 Latest: [v{v}](https://github.com/{REPO_SLUG}/releases/download/v{v}/hdhrVCRplus-{v}.dmg)\n"
        new, n = re.subn(r"### 📦 Latest: \[v[0-9.]+\]\(.*?\)\n", heading, text, count=1)
        if not n:
            sys.exit("could not find README's '### 📦 Latest' heading")
        write(README, new)
        sh(["git", "add", "README.md"], check=True)
        sh(["git", "commit", "-q", "-m", f"docs: README latest release is v{v}"], check=True)
        print("README.md heading + download link updated and committed (push it when you are ready).")
        print(f"! The 3-4 bullets under README's 'Latest' heading still describe the previous release — rewrite them for v{v}.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("preflight", help="read-only readiness report")
    p.add_argument("version"); p.add_argument("--tests", action="store_true", help="also run swift build && swift test")
    p.add_argument("--ui", action="store_true", help="also run the live UI suite (opt-in, ~5 min)")
    p.set_defaults(fn=preflight)
    p = sub.add_parser("stamp", help="CHANGELOG Unreleased → v<version>")
    p.add_argument("version"); p.add_argument("--date", help="release date (default: today)")
    p.set_defaults(fn=stamp)
    p = sub.add_parser("notes", help="write dist/release-<version>/notes.md")
    p.add_argument("version"); p.set_defaults(fn=notes)
    p = sub.add_parser("publish", help="create the GitHub Release (dry run unless --yes)")
    p.add_argument("version"); p.add_argument("--yes", action="store_true", help="actually do it")
    p.add_argument("--live", action="store_true", help="publish (default is a draft) and update README's Latest section")
    p.set_defaults(fn=publish)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
