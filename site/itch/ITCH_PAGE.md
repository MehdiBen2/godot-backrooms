# itch.io page: The Backrooms

Everything to paste into https://itch.io/game/new, using the site's palette, font and copy.

## Basic fields

| Field | Value |
|---|---|
| Title | The Backrooms |
| Project URL | `the-backrooms` (if it's taken: `backrooms-archive` or `tsra-backrooms`) |
| Short description or tagline | First-person horror in the yellow halls. Go alone or bring up to seven other people. |
| Classification | Games |
| Kind of project | Downloadable |
| Release status | In development |
| Pricing | Your call (the site doesn't say. Free or "No payments" until the launcher ships.) |
| Uploads | `backrooms-windows.zip` from the latest GitHub release, marked **Windows** |
| Genre | Survival (or Adventure) |
| Tags | horror, backrooms, first-person, multiplayer, co-op, liminal-space, atmospheric, psychological-horror, 3d, godot |
| AI generation disclosure | Answer honestly for your assets |
| Community | Comments |
| Visibility | **Draft** until you've checked the page |

Under **Metadata → More details** (after the first save):
- Made with: Godot
- Inputs: Keyboard, Mouse
- Multiplayer: Server-based networked multiplayer (or Ad-hoc), Player count 1–8, Voice chat
- Average session: About a half-hour
- Languages: English

## Images

- **Cover image**: `cover_630x500.png`
- **Screenshots**: use `tools/shot_level.gd` captures (itch wants 3–5)

## Description

Paste this in the description editor's HTML/source view:

```html
<p><strong>The Backrooms</strong> is a first-person horror game about walking through the wrong parts of a building. You can go alone or bring up to seven other people.</p>
<p>The yellow halls are the quiet part. Nothing attacks you there right away. The longer you stay, the more you start to notice the hum.</p>
<p><strong>Your torch runs down.</strong> Your camcorder lets you read signs from far away. Most of what hunts you, you can't fight, so you mostly have to get away.</p>

<hr>

<h2>WHO YOU'LL MEET</h2>
<p><strong>EMPTY ROOMS</strong>: Wallpaper, carpet, lights that buzz. Nothing will hurt you in here at first. It's the thing you keep noticing that you should listen to.</p>
<p><strong>MIMICS OF PEOPLE</strong>: Bodies stitched back together by a bacteria that keeps them moving. They copy voices. A call for help from the next room is usually a trap.</p>
<p><strong>COPIES</strong>: Copies of people and everyday objects, made by the place itself. They don't blink. They can flip a light switch while you are standing right next to it.</p>
<p><strong>GAPS</strong>: Spots in the floor you can't see. People walk into them and keep walking. The ones who come back are usually late, sometimes by months.</p>

<hr>

<h2>CATCH IT. LOG IT. GET OUT.</h2>
<ol>
<li><strong>Catch</strong>: Something in the halls is wrong: a room that doesn't match the last one, a sound with no source, a face that is a little too still.</li>
<li><strong>Scan</strong>: Hold the field scanner on it to log its details. The log can disagree with what you see. Trust the mismatch.</li>
<li><strong>Report</strong>: File each anomaly in the field terminal for the Threshold Spatial Research Agency, and so your crew knows which halls to avoid.</li>
<li><strong>Survive</strong>: Most anomalies can't be fought. Keep your torch lit, keep moving.</li>
<li><strong>Find the way out</strong>: Every run ends with an exit, and it is never where the last hall pointed.</li>
</ol>

<hr>

<h2>WHAT YOU CARRY</h2>
<ul>
<li><strong>[F] Flashlight</strong>: drains as you use it. Battery packs refill about 45% each.</li>
<li><strong>[R] AA battery pack</strong>: found on the floor. Loads into the flashlight.</li>
<li><strong>[X] Camcorder</strong>: hold and scroll to zoom up to 4x. Both hands are on it.</li>
<li><strong>[G] Camera flash</strong>: two per run. A direct hit blinds the Bacteria for a few seconds. A miss is loud.</li>
<li><strong>[T] Hazard tape</strong>: mark the corridors you've already walked.</li>
<li><strong>[Q] Field scanner</strong>: log an entity. The log doesn't always match what's in front of you.</li>
<li><strong>[B] Marker</strong>: draw on walls, floors and ceilings. N changes the colour, H rubs it out.</li>
<li><strong>[Tab] Field terminal</strong>: items, dossier, entries, papers, clearance and crew (F1–F6).</li>
</ul>

<hr>

<h2>UP TO EIGHT PEOPLE</h2>
<p>One player hosts and shares a room code. Everyone else types it in. Voice is proximity-based, so you hear the people near you and lose the rest around corners.</p>
<p>The Mimic copies where someone walked a few minutes ago, step for step, and wears their face. It never looks like you. The field scanner is the only way to tell them apart.</p>

<hr>

<h2>RECOVERED TAPES</h2>
<blockquote><p><em>TAPE 03 / DAY THREE:</em> The door at the end of the hall was shut when I walked past it, and I'm sure I left it open. I counted the doors. There's one more than yesterday.</p></blockquote>
<blockquote><p><em>TAPE 31 / MOSTLY CORRUPTED:</em> If you find this, don't follow the hum.</p></blockquote>

<hr>

<h2>INSTALL</h2>
<ol>
<li>Download the zip and put it in its own folder.</li>
<li>Unzip it and run the game.</li>
</ol>
<p>Windows 10 or 11, 64-bit.</p>
<p><em>T.S.R.A., Threshold Spatial Research Agency. Fiction. Nothing on this page is an official document.</em></p>
```

## Theme ("Edit theme" on the page after saving)

| Setting | Value | From the site |
|---|---|---|
| Background color | `#050504` | page background |
| Background image | `page_background_1920x1080.jpg`, no repeat, centered | `.backdrop` + `.veil` |
| Inner/page color | `#0b0b09` | `--panel` |
| Text color | `#e6e1cd` | `--cream` |
| Link color | `#e0453b` | `--red-hi` |
| Button color | `#c4271f` | `--red` |
| Font (headers and body) | VT323 if itch lists it, otherwise Share Tech Mono or Space Mono | VCR isn't an itch font |
| Banner image | `banner_960x200.png` (it replaces the plain title) | `.title` |
| Layout | Wide, with screenshots on the right | |

(Custom CSS is only for accounts itch has approved, so scanlines and flicker can't carry over. The banner and background carry the look.)
