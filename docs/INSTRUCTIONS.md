# RefVault — Implementation Plan

A native macOS app that watches your screenshots folder, indexes design references using Gemma 4 (running locally via Ollama), and lets you search them semantically.

Built for the dev.to Gemma 4 Challenge. Submission deadline: **May 24, 2026**.

---

## 1. What we're building

A single, shippable native Mac app that:

1. Watches `~/Desktop` and `~/Pictures/Screenshots` (Mac defaults) for new screenshots
2. Sends each new image through a local Gemma 4 agentic pipeline that decides whether it's a design reference, and if so, extracts structured metadata (style, typography, layout, colors, mood, URL)
3. Stores results in a local SQLite database
4. Provides a SwiftUI search interface where the user can find references semantically — e.g. "minimal pricing pages with serif type" — and see clustered visual neighbors

Everything runs offline. No data leaves the machine.

---

## 2. Why Gemma 4 (the "why local" pitch for judges)

- **Privacy:** the screenshot archive contains client work and private design exploration — sending it to a cloud API isn't an option
- **Cost:** indexing runs continuously on every new screenshot, often hundreds per week — API costs would be prohibitive
- **Latency:** background indexing should not block the user; local inference removes the network round trip
- **Multimodal reasoning:** the whole product is image understanding, which is what Gemma 4 was built for

**Model choice:** Gemma 4 26B MoE (Q4 quantized, ~16GB).
On an M4 MacBook Air it activates ~3.8B params per token, so it's fast enough for background indexing while still strong enough for nuanced visual reasoning. The smaller E2B/E4B variants tag images too shallowly for design semantics — we tested this assumption early and confirmed it. The 26B MoE is the sweet spot.

---

## 3. Tech stack

| Layer | Choice | Notes |
|---|---|---|
| UI | SwiftUI (macOS 14+) | Native feel, leverages Mac design system |
| Inference | Ollama running Gemma 4 26B MoE | Local HTTP API at `localhost:11434` |
| Storage | SQLite via GRDB.swift | File-based, embedded |
| File watching | `DispatchSource` on folder | Native, no dependencies |
| Image handling | `NSImage` + base64 encoding for Ollama | |
| Vector search (optional, v2) | sqlite-vec extension | Only if we want true semantic search beyond tag match |

**Note on shipping:** for the demo we assume Ollama is already running locally — the judges won't penalize this since it's how every Gemma 4 local app works. If we want to ship to non-technical users post-competition, we bundle the Ollama binary and pull the model on first launch. That's a v2 problem.

---

## 4. The agentic Gemma pipeline

This is the core of the app. When a new screenshot is detected, we run an **agentic loop** rather than a single prompt. The agent decides what tools to call based on what the image needs.

### 4.1 Why agentic, not single-shot

A single mega-prompt that asks Gemma to "extract everything" tends to:
- Miss color hex codes (Gemma's color reasoning is approximate; better with a focused prompt)
- Hallucinate URLs when none are visible
- Skip the relevance check entirely (everything gets tagged as design even if it's a Slack screenshot)

An agentic loop gives Gemma a clear job at each step and lets it skip work that isn't needed. It also documents nicely for the writeup.

### 4.2 Tools available to the agent

```
tools:
  - classify_image_relevance(image)
      → returns: { is_design: bool, confidence: float, reason: string }
      Filter pass: is this actually a design reference, or a random screenshot
      of a chat / error message / receipt?

  - extract_design_metadata(image)
      → returns: { style, typography, layout, mood, tags[] }
      Only called if is_design == true.
      The "what is this" step. Style, typography family, layout type,
      mood, free-form tags.

  - extract_color_palette(image)
      → returns: { primary: hex, secondary: hex, accent: hex, all: [hex...] }
      Focused color extraction. Documented limitation:
      Gemma's hex codes are approximate within ~5-10%. Good enough for
      "find me references with green accents" but not pixel-perfect.

  - extract_visible_url(image)
      → returns: { url: string | null }
      Only fires if the image looks like a browser screenshot
      (header bar, address bar visible). Returns null if no URL is found.
      We explicitly tell the model: "Only return a URL if you can clearly
      read it. Do not guess."

  - generate_embedding(metadata)
      → returns: float vector
      Optional v2: takes the structured metadata and produces a vector
      for semantic search beyond keyword matching.
```

### 4.3 Agent control flow

```
on_new_screenshot(image_path):
    1. Load image, encode as base64
    2. Call classify_image_relevance(image)
       - If is_design == false: store minimal record { path, is_design: false }, exit
       - If is_design == true: continue
    3. In parallel, call:
       - extract_design_metadata(image)
       - extract_color_palette(image)
       - extract_visible_url(image)   # only if browser-like UI detected in step 2
    4. Merge results into a single record
    5. Insert into SQLite
    6. Notify UI to refresh
```

We run the three extraction tools in parallel because they're independent and Ollama can handle concurrent requests on the M4. This keeps total indexing time per screenshot at roughly 5-8 seconds rather than 15-20 sequential.

### 4.4 Prompt templates

**Tool 1: classify_image_relevance**

```
You are looking at a screenshot from a designer's screen captures folder.

Your only job is to decide: is this a design reference (a website, app UI, 
poster, typography sample, color palette, illustration, or anything a 
designer would save for inspiration)?

Or is it something else (chat conversation, error message, receipt, 
random photo, code editor, document, spreadsheet)?

Respond ONLY with JSON:
{
  "is_design": boolean,
  "confidence": 0.0 to 1.0,
  "reason": "one short sentence"
}
```

**Tool 2: extract_design_metadata**

```
You are analyzing a design reference image. Extract structured metadata.

Return ONLY this JSON, no other text:
{
  "style": "one of: minimal, maximalist, brutalist, neo-brutalist, editorial, 
            corporate, playful, retro, futuristic, glassmorphic, skeuomorphic, 
            other",
  "typography": "one of: serif, sans-serif, mono, display, mixed, none-visible",
  "layout": "one of: hero, pricing, dashboard, landing, portfolio, blog, 
             product-detail, navigation, form, modal, mobile-screen, poster, 
             illustration, other",
  "mood": "2-3 adjectives, comma-separated, e.g. 'calm, professional, 
           trustworthy'",
  "tags": ["array", "of", "5-10", "specific", "tags", "in", "design", "vocabulary"]
}

Use the actual visual evidence. Do not guess if you cannot see something clearly.
```

**Tool 3: extract_color_palette**

```
Identify the dominant colors in this design.

Return ONLY this JSON:
{
  "primary": "#RRGGBB",
  "secondary": "#RRGGBB",
  "accent": "#RRGGBB",
  "all": ["#RRGGBB", "#RRGGBB", ...]
}

Primary: the most-used color (often background or main surface).
Secondary: the next most-used color (often text or contrasting surface).
Accent: a color used sparingly for emphasis (buttons, links, highlights).
All: up to 6 hex codes representing the full palette in order of dominance.

Approximate hex codes are acceptable. Be honest about what you see.
```

**Tool 4: extract_visible_url**

```
Look ONLY at this image's header area, address bar, or any visible URL text.

Is there a clearly readable website URL visible in the image?

Respond ONLY with JSON:
{
  "url": "the.url.com/path" or null,
  "found_in": "address-bar" | "header-text" | "footer" | null
}

Rules:
- Only return a URL if you can clearly read it character by character
- Do NOT guess based on the visual style of the site
- Do NOT infer the URL from a logo
- If unsure, return null
```

---

## 5. SQLite schema

```sql
CREATE TABLE screenshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path TEXT UNIQUE NOT NULL,
    file_name TEXT NOT NULL,
    captured_at DATETIME NOT NULL,
    indexed_at DATETIME NOT NULL,
    
    -- relevance
    is_design BOOLEAN NOT NULL,
    relevance_confidence REAL,
    relevance_reason TEXT,
    
    -- metadata (null if is_design = false)
    style TEXT,
    typography TEXT,
    layout TEXT,
    mood TEXT,
    tags TEXT,              -- JSON array as string
    
    -- colors
    color_primary TEXT,     -- hex
    color_secondary TEXT,
    color_accent TEXT,
    colors_all TEXT,        -- JSON array of hex
    
    -- source
    visible_url TEXT,
    url_location TEXT,
    
    -- raw model output for debugging / re-processing
    raw_response TEXT
);

CREATE INDEX idx_is_design ON screenshots(is_design);
CREATE INDEX idx_style ON screenshots(style);
CREATE INDEX idx_layout ON screenshots(layout);
CREATE INDEX idx_indexed_at ON screenshots(indexed_at);

-- For tag search, we use a simple LIKE query on the JSON string in v1.
-- In v2, consider a tags_fts FTS5 virtual table for full-text search.
```

---

## 6. Swift app structure

```
RefVault/
├── RefVaultApp.swift           # @main entry, MenuBarExtra setup
├── Core/
│   ├── ScreenshotWatcher.swift # DispatchSource folder watching
│   ├── OllamaClient.swift      # HTTP client for localhost:11434
│   ├── GemmaAgent.swift        # The agentic loop, tool dispatch
│   ├── Database.swift          # GRDB setup, queries
│   └── Models.swift            # Screenshot, Metadata structs
├── UI/
│   ├── MainWindow.swift        # Search + grid
│   ├── SearchBar.swift
│   ├── ResultGrid.swift
│   ├── ScreenshotCard.swift    # Tile with image, tags, color swatches
│   └── DetailView.swift        # Full screenshot, full metadata, click-through to URL
└── Resources/
    └── prompts/                # Prompt templates as .txt files
```

The UI lives in the menu bar (always accessible while designing) and opens a main window when clicked. Cmd+Space-style quick search is a nice-to-have for v2.

---

## 7. Build order (2.5 weeks)

Working backwards from May 24:

**Days 1-2 — Foundation**
- Set up Xcode project, SwiftUI shell
- Install Ollama, pull `gemma4:26b`, verify it responds to vision prompts via `curl`
- Build `OllamaClient.swift` — minimal HTTP wrapper, send image + prompt, get JSON back
- Test end-to-end: send one screenshot, get tags. Don't worry about UI yet.

**Days 3-5 — Agent + database**
- Implement the four tool prompts as separate functions
- Build the agent control flow (relevance check → parallel extraction → merge)
- SQLite schema + GRDB integration
- Run on a folder of 50 mixed screenshots manually, verify the relevance filter actually filters and the metadata is sensible

**Days 6-9 — UI**
- Folder watcher running in background, indexing live
- Search bar + result grid
- Screenshot detail view with color swatches, tags, click-through to URL
- Keyboard shortcuts for fast nav
- This is where Paper prototypes drive the visual direction (see CLAUDE.md)

**Days 10-13 — Polish + edge cases**
- Handle re-indexing if a screenshot is moved or deleted
- Empty states, loading states, error states
- Speed tune: parallel calls, image downscaling before sending to Gemma
- Fix the inevitable prompt issues we discover by running against real screenshots

**Days 14-15 — Demo materials**
- Record demo video (the dev.to writeup needs an embedded walkthrough)
- Write the dev.to post: what I built, why Gemma 26B MoE specifically, code repo link, demo
- Polish the README

**Day 16-17 — Buffer**
- Things will break. Leave time.

---

## 8. Demo video — what it needs to show

The video is what judges actually watch. Plan it now.

1. **The hook (10s):** "I'm a designer. I take 200 screenshots a week. I can never find anything." Cut to a chaotic Screenshots folder.
2. **The setup (15s):** "RefVault watches my screenshots folder and indexes everything with Gemma 4 running locally on my Mac. Nothing leaves the machine."
3. **The magic moment (30s):** Take a screenshot of a real website live. Cut to RefVault — the screenshot appears, gets tagged, color palette extracted, URL pulled. All in a few seconds.
4. **The search (30s):** Type "minimal pricing serif" — five real references appear. Type "warm earthy palette" — different set. Click through to one of them.
5. **The why (15s):** "Gemma 4 26B MoE was the right model — strong enough to understand design semantics, light enough to run on an M4 Air. Apache 2.0, fully offline."

Total: ~90 seconds. Don't go longer.

---

## 9. dev.to writeup structure

The submission template asks for: What I Built, Demo, Code, How I Used Gemma 4.

Use those headers. Under "How I Used Gemma 4," explicitly call out:
- The 26B MoE choice and why E4B wasn't enough
- The agentic pipeline and why we split into four tools
- The Apache 2.0 license + privacy story
- One concrete example of a tag the model got right that surprised us

Judges said they're rewarding "intentional model selection" — make this section sing.

---

## 10. Known unknowns / things to figure out as we go

- How accurate are Gemma's hex codes really? Test on a known palette early.
- Does the relevance classifier have a bias toward calling everything design? May need to add negative examples in the prompt.
- Folder watching on Mac sometimes triggers twice for one file (write + close). Debounce.
- macOS sandboxing: the app needs read access to `~/Desktop` and `~/Pictures/Screenshots`. Will require user permission on first launch.
- What does "search" actually mean — exact tag match, fuzzy, vector? Start with tag match (LIKE queries on the tags JSON), upgrade if it feels weak.

These all go in CLAUDE.md as open questions to revisit.

---

## 11. What this is NOT (scope discipline)

To survive 2.5 weeks, we are NOT building:

- A way to import screenshots from outside the watched folder (drag-drop is v2)
- Cloud sync between machines
- Sharing references with collaborators
- Bundled Ollama installer — judges run their own, that's fine
- A Chrome extension companion
- Vector embeddings + true semantic search — keyword/tag search is enough for the demo
- An "edit tags" UI — tags are what Gemma says they are, take it or leave it for v1

If any of these creep in, push back to v2.
