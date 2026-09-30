# Mobbin references and the decisions they settle (06)

Status: applied in the 2.0.x follow-up. Pulled 2026-09-29 with the Mobbin MCP (`search_screens`, deep mode). Mobbin only indexes iOS and web, so these are web-app pattern references, not macOS screens. Each pattern below was read from the returned image, not from metadata. Supersedes the "what to pull" list in `05-reference-gaps.md` for the rows covered here (rows 3, 4, 8, 11, 12, 13, 17, 18, 22, 23).

## 1. Command palette (screen 4)
Refs: [Vapi](https://mobbin.com/screens/593d7acd-2e16-4365-bcd6-02ce52f48f3b), [Magnific](https://mobbin.com/screens/14ceb943-f04a-460f-b4f5-2ebd78d74aff), [Juicebox](https://mobbin.com/screens/2af813bf-0129-45d1-81ed-069edee76e16), [Navattic](https://mobbin.com/screens/c65971cf-c4ea-45e9-99a5-555930cb5d73).
- Empty query shows **Recent** first, then grouped sections (Actions, All). Section headers are small, muted, not uppercase-shouting.
- Rows carry a trailing muted context label ("Metrics - Observe") and, for actions, a keycap group on the right in rounded boxes.
- A **footer bar** always shows the live key hints: up/down navigate, return select, esc close; Juicebox adds `Tab` to jump sections.
- Selected row: soft fill; Juicebox adds a 2pt accent bar on the leading edge.

## 2. Settings (screen 8)
Refs: [Linear](https://mobbin.com/screens/9ac66835-aa7f-469f-ace3-a915c2cf2dfd), [Featurebase](https://mobbin.com/screens/32b42868-60b6-460b-80f8-c9fb51fca937), [Fireflies](https://mobbin.com/screens/6e50a822-69c1-447c-95cf-29bdb47fae80), [Superlist](https://mobbin.com/screens/99f1615e-cc2b-43cc-b2f1-b2a274545e0f).
- Sidebar is **grouped with small section labels** (Personal / Products / Workspace); `NEW` pill badges mark fresh panes.
- Content is a single centered column (about 600pt); each setting is a row inside a card, hairline-divided: title plus secondary description on the left, control on the right. Dependent sub-options are indented under their parent.
- Search sits at the top of the sidebar.

## 3. Onboarding (screen 13)
Refs: [Maze](https://mobbin.com/screens/8cf9682a-28ba-4659-9c3c-3424ed51af2e), [Pin](https://mobbin.com/screens/cbe8001f-b673-4fca-8d98-7e37f333e610), [Perplexity](https://mobbin.com/screens/0d40ad02-9b96-49cb-b345-dfcf08584ee2), [Deputy](https://mobbin.com/screens/93381f72-a4e3-4bb9-8f92-8a7f887ea02e).
- A vertical **stepper** with the current step highlighted and future steps dimmed; permissions listed as rows inside the step.
- Header shows "Step N/M" (Pin); progress dots (Perplexity); a quiet text action to continue without granting ("Continue Without Connecting Accounts").
- A "what you'll get" checklist under the permission ask. Back is ghost, forward is primary.

## 4. AI assistant tool activity and approval (screen 9)
Refs: [Lindy](https://mobbin.com/screens/9f4affd5-f387-4149-860e-95c83f9bbba5), [Claude](https://mobbin.com/screens/34aa9592-2138-4be6-95f6-4aa7410e9bb9), [Cohere](https://mobbin.com/screens/b9bb02db-9d0c-4f40-a420-f4298276fb92).
- Tool steps render as **collapsed step cards** with a status glyph (check / spinner) and a chevron to expand; a multi-step run is a checklist with the active step marked "Processing...".
- A finished tool call collapses to a one-line summary chip ("Connector search - 10 connectors").
- Decisions are a **numbered option card** (1-4) with keyboard hints and a Skip action, not a modal.
- A side tools panel lists each tool with a description and its own toggle (Cohere): use for per-tool permissions.

## 5. Masked and sensitive values (screens 1 and 12)
Refs: [Google AI Studio](https://mobbin.com/screens/079dbdb6-3074-498c-ac61-40865462c541), [Supabase](https://mobbin.com/screens/8d3f5333-785a-4908-87cd-d3c20fdcdd39), [Cursor](https://mobbin.com/screens/ea6ec2b1-958b-4c11-bc01-a8288f02668c).
- Masked value with the **reveal eye inside the field's trailing edge**; copy and delete are separate icon buttons after it. Masked type is labeled ("Redacted Secret").

## 6. Empty states (all screens)
Refs: [HubSpot](https://mobbin.com/screens/1f61dd9a-ad64-47ed-bdef-f840c67cdfbc), [Klarna](https://mobbin.com/screens/ab5556c1-f9bd-4e69-92fb-2c9e0b2edda3), [GetYourGuide](https://mobbin.com/screens/e31b236f-f666-4422-be9b-4af520cacd67).
- Small spot illustration or glyph, a bold one-line title ("Nothing saved"), one sentence saying what will appear and how, and at most one primary action.

## 7. Sidebar and list grouping (screen 3, screen 1)
Refs: [Linear](https://mobbin.com/screens/46088879-314c-405c-88b5-eb7820c05efb), [Supabase](https://mobbin.com/screens/aaecbeeb-5370-4ae4-9bd7-30e0c3d06448), [Twenty](https://mobbin.com/screens/4c690377-c1a0-4f68-a668-8ece2212ad35).
- Collapsible groups whose headers show the **count** and a trailing add button; selected row is a soft gray fill; workspace switcher on top.
- Grouped lists use a full-width header band per group with a count (Linear "In Progress 5").

## 8. Toasts (04-interaction section 7)
Refs: [Pinterest](https://mobbin.com/screens/70234394-ca14-4def-8aa4-e9784fdccae1), [Asana](https://mobbin.com/screens/36cb9092-004d-4cfa-abc7-930e4a7ff931), [Fibery](https://mobbin.com/screens/762eacbd-2fb7-452d-a5c5-f631a55cc564), [Klarna](https://mobbin.com/screens/ab5556c1-f9bd-4e69-92fb-2c9e0b2edda3).
- Compact dark pill, bottom-center, message plus **one inline action** (Undo or View), auto-dismiss, optional close. Destructive actions offer Undo instead of a confirm dialog.

## 9. Not adopted
- Version-history side list ([Substack](https://mobbin.com/screens/d1d0d099-5452-4842-bbb7-681486136291), [1Password](https://mobbin.com/screens/b73a0791-59c5-4846-8dfa-d7e46f26fd67)): would need clip revision storage that does not exist. Lead for a future item.
- Rows 1, 2, 5-7, 9-10, 14-16, 19-21 of `05` remain unpulled (Paste, Raycast, Alfred, Pastebot are native macOS apps, not in Mobbin).
