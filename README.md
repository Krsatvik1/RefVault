# RefVault

A native macOS app that watches your screenshots folder, indexes design references using **Gemma 4** running locally via Ollama, and lets you search them semantically.

Built for the dev.to Gemma 4 Challenge. See [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md) for the full plan and [`CLAUDE.md`](CLAUDE.md) for working notes.

## Status

Phase 1 — agentic pipeline + bare-min UI. Pick an image, run it through the four-tool Gemma pipeline, watch each step stream into a log, and inspect the merged record as JSON. No watcher, no DB, no search yet — that's next.

## Prerequisites

1. **macOS 13+** (Ventura or later) and Swift 5.9+
2. **Ollama** running locally:
   ```sh
   brew install ollama
   ollama serve            # leave running
   ollama pull gemma4:26b  # ~16 GB
   ```
3. Verify:
   ```sh
   curl http://localhost:11434/api/tags
   ```

## Run

```sh
swift run RefVault
```

A window opens. Click **Pick image…** to choose a screenshot, then **Index with Gemma**. The right pane streams the agent's progress: relevance verdict → metadata → palette → visible URL → final merged record.

## Pipeline

```
on_new_screenshot(url):
    1. classify_image_relevance      → is_design? exit if false
    2. parallel:
         extract_design_metadata
         extract_color_palette
         extract_visible_url         (only if image looks like a browser)
    3. merge → ScreenshotRecord
```

Prompts live as plain text in [`Sources/RefVault/Resources/prompts/`](Sources/RefVault/Resources/prompts/).

## Repo layout

```
reference-helper/
├── Package.swift
├── Sources/RefVault/
│   ├── RefVaultApp.swift         # @main SwiftUI App
│   ├── Core/
│   │   ├── Models.swift          # Codable structs
│   │   ├── OllamaClient.swift    # POST /api/generate (vision + format=json)
│   │   ├── PromptStore.swift     # loads prompt .txt files
│   │   ├── ImageEncoder.swift    # downscale + base64
│   │   └── GemmaAgent.swift      # the agentic loop
│   ├── UI/
│   │   └── MainWindow.swift      # bare-min UI
│   └── Resources/prompts/        # the four tool prompts
├── docs/INSTRUCTIONS.md          # full project plan
├── CLAUDE.md                     # working notes
└── .gitignore
```

## Roadmap (next)

- Screenshot folder watcher (DispatchSource on `~/Desktop` and `~/Pictures/Screenshots`)
- SQLite via GRDB.swift
- Search bar + result grid
- Detail view with color swatches and click-through to URL
