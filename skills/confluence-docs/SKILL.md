---
name: confluence-docs
description: Write or update documentation on Confluence for the INF (Infrastructure) space at <your-org>.atlassian.net — concise, diagram-first pages with a References section linking to source repos or external docs. The topic and source material always come from the current request, fresh each run — never assume what to document from memory or a past run. Use when asked to "write docs to Confluence", "update the wiki", "document X on Confluence" / "in the INF space", or similar.
---

# Confluence Docs

You are writing documentation for other engineers to actually read — the
opposite of a wall of text. Every page you touch should be scannable in under
a minute: a diagram or table carries the structure, short lines carry the
detail, and a References section anchors it back to the real source (repo,
runbook, external docs) instead of letting the wiki drift out of sync with
reality.

**Identity**: site `<your-org>.atlassian.net` (`cloudId` for every Atlassian
tool call). Space **INF** ("Infrastructure"), spaceId `11731794`. Homepage /
overview: pageId `11732008` —
https://<your-org>.atlassian.net/wiki/spaces/INF/overview

Known existing children of the homepage (for routing new pages, not
exhaustive — always check with `getConfluencePageDescendants` /
`searchConfluenceUsingCql` before assuming a page doesn't exist):

- `31719548` — How to create JIRA task for SRE team
- `54296604` — Onboarding and Offboarding
- `59703348` — Meetings

## Hard Rules

1. **Context comes from the request, not memory.** This skill never decides
   on its own what to document. Each invocation, the user supplies (or you
   ask for) the topic/page and the source material (a repo, a design, an
   existing runbook, an incident, etc.). If that's missing or too vague to
   write anything accurate, ask rather than inventing content.
2. **Scope is the INF space** unless the user names a different space
   explicitly. Never create pages outside it on your own judgment.
3. **Additive/precise edits, not blind overwrites.** Before updating an
   existing page, fetch its current body (`getConfluencePage`,
   `contentFormat: "html"`). Change only what the request is about; preserve
   unrelated sections, existing links, and structure. If the request implies
   a full rewrite of a page with unrelated existing content, confirm with the
   user first rather than silently discarding it.
4. **Never delete a page**, never strip another author's content to make room
   for yours without being asked to.
5. **No secrets.** Never put credentials, tokens, internal IPs/hostnames that
   are themselves sensitive, or raw customer data into a wiki page.
6. **Always fetch the format guide fresh.** Before authoring or editing any
   HTML body, call `getContentFormatGuide` with `toolName: "createConfluencePage"`
   or `"updateConfluencePage"` (matching the call you're about to make) —
   every time, not just the first time in a session. Follow it exactly:
   Confluence pages here are ADF-backed HTML, not Confluence storage XML —
   `<ac:structured-macro>` etc. renders as raw text if you write it directly.

## House style (non-negotiable)

1. **Light on words.** Prefer bullet lists, short tables, and headings over
   paragraphs. If a section is more than ~4-5 lines of prose, look for a way
   to turn it into a table, a list, or a diagram instead. No filler sentences
   ("This document describes...", "As we all know...").
2. **Diagram first when structure exists.** Any time the topic has an
   architecture, a flow, a sequence of steps, or a decision tree, put a
   diagram in, not just prose describing it. See **Diagrams** below for how.
3. **Every page ends with a References section** — a bullet list of smart
   links to the actual source: the git repo (specific path/README when you
   know it, not just the repo root), relevant external docs (AWS/K8s/vendor
   docs, RFCs), and any Jira epic/ticket or other Confluence page the content
   came from. Use the smart-link pattern so it renders with a live
   title/icon:
   ```html
   <ul>
     <li><a href="https://github.com/org/repo/blob/main/path" data-card-appearance="inline"></a></li>
     <li><a href="https://docs.aws.amazon.com/..." data-card-appearance="inline"></a></li>
   </ul>
   ```
4. **State what's true now, not history.** Skip changelong narration ("we
   used to do X, then switched to Y") unless the user specifically asks for a
   decision record — link to the ADR/ticket instead of re-narrating it.

## Diagrams

Confluence's supported page format (see `getContentFormatGuide`) has no
native Mermaid/PlantUML macro documented, and there's no attachment-upload
tool available here — so render the diagram to an image via
[Kroki](https://kroki.io) (a free, no-auth rendering service) and embed it as
a plain external image. Per the format guide, a bare `<img src="...">` needs
no upload and becomes a real image node.

1. Write the diagram as Mermaid source (flowchart/`graph`, `sequenceDiagram`,
   etc. — whichever fits the content).
2. Encode it (zlib deflate + URL-safe base64 — Kroki's standard scheme):
   ```bash
   python3 -c "
   import zlib, base64
   src = '''graph TD
     A[Client] --> B[API]
     B --> C[(Database)]
   '''
   print(base64.urlsafe_b64encode(zlib.compress(src.encode('utf-8'), 9)).decode())
   "
   ```
3. Embed it: `<img src="https://kroki.io/mermaid/svg/<ENCODED>" alt="short description" width="700">`
   (svg for crispness; swap `svg` for `png` if svg doesn't render well embedded).
4. **Verify it actually renders** — `WebFetch` the Kroki URL once before
   publishing; a bad diagram source returns an error image/response, not a
   diagram.
5. If Kroki is unreachable or the encoded URL fails: fall back to a labeled
   ```` ```mermaid ```` code block (`<pre><code class="language-mermaid">`) so
   the source is at least readable and copy-pasteable, and tell the user the
   image render didn't work.

## Workflow

1. **Get the brief.** From the current request: what page/topic, what source
   material (repo path, design doc, existing page to revise), and whether
   it's a new page or an update to an existing one. Ask if any of this is
   missing.
2. **Find out if the page already exists** — `searchConfluenceUsingCql` with
   `space = INF AND type = page AND title ~ "<topic>"`, or
   `getConfluencePageDescendants` on the homepage or the likely parent, before
   assuming you need to create anything.
3. **If updating:** `getConfluencePage` (`contentFormat: "html"`) to read the
   current body in full first.
4. **Pick the parent for a new page:** default to the homepage (`11732008`)
   unless the topic clearly belongs under an existing child (Onboarding,
   Meetings, etc.) — ask if it's ambiguous.
5. **Call `getContentFormatGuide`** for the exact tool you're about to call
   (`createConfluencePage` or `updateConfluencePage`), fresh, and follow it.
6. **Draft the body** per the house style above: a one-line summary under the
   title, a diagram where structure exists, short sections, a References list
   at the end.
7. **Publish**: `createConfluencePage` (spaceId `11731794`, parentId as
   decided) or `updateConfluencePage` (with a `versionMessage` describing the
   change).
8. **Report back**: the page URL, a one-line summary of what changed, and
   whether anything (like a diagram render) fell back to a non-ideal path.

## Sources and reasoning

- **Link what you researched.** When a conclusion rests on research (vendor or
  tool docs, chart/provider docs, release notes, a GitHub issue, a Jira or
  Confluence page), end it with a **References** list: one link per line plus
  what it supports. Mark any conclusion with no source as your own inference.
- **Say why before you trace.** Before reading logs, events, metrics, traces,
  or error output, state in one line what you are looking for and which
  symptom or hypothesis it tests; afterwards, say what it showed. Never dump
  logs without that reason.

## Before you finish

- [ ] The topic/content came from this request's context, not assumed.
- [ ] `getContentFormatGuide` was fetched fresh for this call, and its HTML
      rules were followed (no `<ac:*>` storage-XML tags).
- [ ] An existing page's unrelated content was preserved, not clobbered.
- [ ] The page is light on prose — bullets/tables/diagram over paragraphs.
- [ ] A diagram was included if the topic has real structure to show, and was
      verified to actually render (or the fallback was used and flagged).
- [ ] A References section with real smart links is present.
- [ ] No secrets or sensitive internal details ended up in the page.
- [ ] The user was given the final page URL and a short summary of the change.
