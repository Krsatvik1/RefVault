# CLAUDE.md — Working notes for RefVault

This file is for me (the human) and Claude Code to think out loud together. It's not a spec. INSTRUCTIONS.md is the spec. This is the conversation around the spec.

---

## How to use this file

- When I'm stuck on a decision, I open this file with Claude and we talk it through here.
- When something in INSTRUCTIONS.md turns out to be wrong, we update INSTRUCTIONS.md and write a short note here about why.
- Every "I'm not sure about X" gets logged here. We come back to them.

---

## About me / how I work

- I'm a designer who codes. Communication design background, UI/UX focus now.
- Most of my work happens in Claude Code. I prefer to drive the agent rather than write code line-by-line.
- Visual design happens in **Paper (paper.design)** first, then translates to SwiftUI. **Paper outputs HTML, not Swift** — the export won't drop straight into the project. I use it as a visual reference, then rebuild in SwiftUI manually. Build that translation step into the workflow; don't expect the export to be useful as code.
- I think in components and visual hierarchy before I think in data models. If we're stuck, do a Paper sketch first.

---

## Open questions to revisit

These are things we deferred. Don't forget them.

1. **Hex code accuracy.** How wrong is Gemma on colors? Test on day 3 with a screenshot whose palette I know. If it's off by more than ~15% perceptually, decide: live with it, or do a post-process step that reads actual pixel values from the image with native Swift APIs and uses Gemma only for *naming* the palette.

2. **Relevance classifier bias.** First time we run the agent on real screenshots, count how many false positives we get (Slack windows tagged as "design"). If high, add explicit negative examples to the prompt.

3. **Search behavior.** Do I want exact tag match, partial match, or true semantic search? Start with `LIKE %term%` against the tags JSON. Try it for a day. If "minimal pricing serif" doesn't return obvious matches, escalate to FTS5 or embeddings.

4. **Folder watching debounce.** macOS fires file events twice (write + close). Decide on debounce window — start with 500ms, tune from there.

5. **What happens if Ollama is down?** Queue the screenshot for re-indexing later. Don't crash, don't block the UI. Build this on day 5.

6. **Multiple monitors / Retina screenshots.** They're huge. Downscale before sending to Gemma — 1024px on the long edge should be fine for tagging. Test that smaller images don't degrade tag quality before committing.

---

## Decisions we already made (and why)

- **Native Swift, not Electron / Tauri.** Better Mac feel, faster, and I prefer it.
- **Gemma 4 26B MoE, not E4B.** E4B is too shallow on visual semantics. 26B MoE runs fine on M4 Air.
- **Agentic loop with separate tools, not one mega-prompt.** Better isolation, easier to debug, makes for a better dev.to writeup.
- **Single shippable app, not three separate things.** All workflow integration happens inside the same app.
- **Ollama assumed running for the demo.** Bundling is a v2 problem.

---

## Design approach

When designing a new screen or component:

1. Sketch in Paper first. Don't open Xcode until the visual idea is clear.
2. Paper → screenshot the design → annotate spacing, colors, typography in writing.
3. Rebuild in SwiftUI. Treat the Paper file as a reference image, not source code.
4. The Paper HTML export is for me to look at, not for the app. Don't try to convert it.

Visual principles for this app:
- It's a designer's tool, so it has to look right or I won't use it
- Restraint over decoration — let the screenshots be the visual focus
- Color swatches and tags are the only chrome that matters
- Mac native: respect the system font, the system spacing, dark mode

---

## When to brainstorm vs. when to ship

This project has a hard deadline (May 24). Brainstorming is welcome during the **build order phases 1-3** in INSTRUCTIONS.md. Once we're in phase 4 (polish), brainstorming new features is off the table — only edge case fixes and demo prep.

If I bring up a new idea after day 9, the answer is "v2 — log it in this file."

---

## v2 ideas parking lot

Things I want to remember but won't build for the competition:

- Drag-and-drop import from outside the watched folder
- Cloud sync via iCloud
- Browser extension that captures + uploads to RefVault
- Quick-search via global hotkey (Cmd+Shift+R or similar)
- "Find similar" — given one screenshot, surface the 5 closest visually
- Tag editing UI
- Export a moodboard (selected screenshots → PDF or Figma frame)
- Share a reference set with a collaborator (read-only link)
- Bundle Ollama, ship as a one-click installer to non-technical designers
- Fine-tune Gemma 4 on my own taggings to get the model better at *my* visual vocabulary

---

## Things I keep forgetting / lessons as we go

(Empty for now. Fill in as we build.)

---

## Sanity checks before each work session

When I sit down to work on this with Claude Code, do this first:

1. Is Ollama running? (`curl localhost:11434/api/tags`)
2. Is the Gemma 4 26B model loaded? (`ollama list`)
3. What day are we on? Are we still on schedule per the build order?
4. What's the next task in INSTRUCTIONS.md section 7?
5. Is there an unanswered question in this file's "Open questions" section that's blocking it?

---

## Communication style I want from Claude in this project

- Skip preambles. Don't tell me what you're about to do, just do it.
- No compliments. "Great question" is wasted tokens.
- When I'm wrong, say so directly with the reasoning. Don't soften.
- Short answers by default. Expand only when I ask.
- When proposing code, propose the smallest version that works. We can grow it.
- If I'm about to make a scope mistake, push back before writing the code.
