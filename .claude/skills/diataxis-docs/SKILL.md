---
name: diataxis-docs
description: Write, review, restructure or move paw's documentation by the Diátaxis framework (tutorials, how-to guides, reference, explanation). Use whenever a task writes or changes anything under docs/, a README (top level, crates/*, extensions/*), the tutor's lessons, :help pages or docs/api.md's generator, or asks where a piece of documentation belongs, why a page reads badly, or to "document", "write up", "add docs for" a feature — even when it only says "update the README" or "add a section".
---

# Documentation with Diátaxis

Diátaxis (diataxis.fr, by Daniele Procida) says there are four kinds of
documentation, because a user's need sits on two axes:

| | **acquisition** (study) | **application** (work) |
| --- | --- | --- |
| **action** (doing) | **tutorial**: learning-oriented, a lesson | **how-to guide**: goal-oriented, directions |
| **cognition** (knowing) | **explanation**: understanding-oriented, discussion | **reference**: information-oriented, description |

"There are four and only four types": the two axes cover the whole
territory. Almost every documentation problem is a page that crosses or
blurs these boundaries.

## The compass: use it on every piece you write or read

Ask two questions, of a page, a section, a paragraph or a sentence:

1. Does it inform **action** (what the user does) or **cognition** (what the user knows)?
2. Does it serve the **acquisition** of skill (study) or its **application** (work)?

| action + acquisition | action + application | cognition + application | cognition + acquisition |
| --- | --- | --- | --- |
| tutorial | how-to guide | reference | explanation |
| "Can you teach me to…?" | "How do I…?" | "What is…?" | "Why…?" / "Tell me about…" |
| a lesson | a series of steps | dry description | discursive explanation |
| teaching a child to cook | a recipe | the label on a food packet | a book on food's social history |

Use it most when you feel doubt: "intuition provides an immediate answer that
is also wrong" surprisingly often. Rules of thumb: boring, listy, tabular → reference;
something you could read in the bath → explanation; the reader has their
hands on paw and a goal → how-to; the reader is learning paw and we lead → tutorial.

## Tutorials (docs/tutorials/, and the tutor's lessons)

A lesson. Its purpose is that the learner acquires skill and confidence, not
that something gets done. "The instructor is condemned to be absent", so the
tutorial must work for every user, every time.

- **Don't teach: give things to do.** The learner learns from what they do.
- **Say where we are going**, never what they will learn: "In this tutorial
  we will make a four-bar loop and mix it." Not "you will learn…".
- **A visible result at every step**, early and often; show the exact
  expected output ("The status line now says `recording take 1`").
- **Narrate the expected**: "You will notice that…", "After a moment, …".
  Flag the likely slip: "If the clip stays grey, you probably pressed `r`
  before `I`."
- **Point things out in passing** ("Notice the `[+]` beside the name").
- **One path, no choices or alternatives**, no options, no "you could also".
- **Minimal explanation**: one clause and a link ("We use `V` because the
  whole track should move; see [About visual mode](…)").
- **Concrete and particular**: this project, these notes, this key.
- **Repeatable and safe**: a practice project the learner can reopen;
  undo always gets them back.
- **Usefully complete**: every action, concept and tool the lesson needs is met in it.
- Language: "We…", "First, do x. Now do y.", "The output should look like…",
  "Notice that…", and at the end a mild admiring summary of what was made.
- Test it: drive the lesson with real keys (the tutor's tests do), and fix
  every place a learner could get lost.

## How-to guides (docs/how-to/)

Directions for an already-competent user with a real goal. Work, not study.

- **Title says exactly what it shows: "How to …"** ("How to record a MIDI
  take over a loop"). Not "Recording" (whether? what?).
- **Goals of the user, not operations of the machinery.** "How to keep the
  drums out of a pitch operator", not "The `:drums.map` command".
  A guide may cut across many commands and views.
- Open with one line: "This guide shows you how to…" and what it assumes.
- **Action and only action**: no teaching, no digressions, no full option
  lists ("See [`:render`](…) for every option").
- **Real-world forks**: conditional imperatives — "If the track has no
  input, press `I` first. To record several takes, …".
- **Omit the unnecessary**; start and end at sensible points the reader
  joins to their own work. Order steps by necessity and by the user's flow.
- A how-to can be basic; a tutorial can be advanced. The difference is study vs work.

## Reference (docs/reference/, generated docs/reference/api.md, extension READMEs' tables)

Technical description of the machinery, consulted while working.

- **Describe and only describe**: austere, neutral, authoritative, no
  opinions, no instructions to reach a goal, no history.
- **Mirror the structure of the machinery**: the Lua API by module, keys by
  view and mode, commands alphabetically or by area, options in one table,
  the protocol by message. Not by user journey.
- **Consistent patterns**: every command, key and option entry has the same
  shape (name, arguments/default, one-sentence effect, limits). Same words for same things.
- **Short examples are welcome** to illustrate usage, never to teach.
- Warnings as plain facts: "`:w!` overwrites without asking. Never…".
- Limits are reference too: what is not done (docs/reference/limits.md).
- Generated reference stays generated (tools/apidoc.lua → api.md, types);
  never edit generated output by hand. Generated alone is not enough: the
  hand-written reference covers what the generator cannot.

## Explanation (docs/explanation/)

Discussion that builds understanding, read away from the work.

- **Title takes an implicit "About"**: "About the kernel and the Lua
  runtime", "About scenes: one view, two frontends", "About why MIDI is the truth".
- **Context and connections**: design decisions, history, constraints,
  alternatives considered ("REAPER does x; paw does y because…"), how the
  parts interact ("A turn ends with hooks, then scenes are sent…").
- **Opinions and perspective are allowed** and expected; weigh alternatives.
- **Bounded**: start from a real or imagined "why" question; no steps, no
  option tables. Link to the reference and how-tos instead.

## Common collapses to fix

- Tutorial ↔ how-to (the most common): a lesson that offers choices, or a
  guide that teaches. Split: lesson in tutorials, task in how-to.
- How-to written from the machinery ("The X command does…") → that's reference;
  write the guide from the goal, link the reference.
- Reference that grows into explanation (why, history, what-if) → move the
  discussion to an explanation page, keep the facts.
- Explanation absorbing instructions or option lists → move them out.
- Explanation sprinkled through every page → collect it into "About …" pages.

## paw's layout

```
README.md                    landing: what paw is, try it (a tiny tutorial), links into each kind
docs/README.md               the manual's contents, four sections by kind, one line per page
docs/tutorials/              lessons; the course is docs/tutorials/course/, GENERATED from
                             extensions/tutor/lua/tutor/lessons/*.lua by extensions/tutor/make-docs.lua
docs/how-to/                 one task per page, file named after the task: record-a-take.md
docs/reference/              keys, commands, options, views, devices, protocol, file formats,
                             api.md (GENERATED by tools/apidoc.lua), limits.md
docs/explanation/            about-*.md: architecture, scenes, MIDI as truth, the key rule, ...
crates/*/README.md           the crate's landing page, same rules in small
extensions/<name>/README.md  the extension's landing page: one-paragraph what, then sections
                             by kind in this order — Try it (a 5-step tutorial), How to …
                             (goals), Reference (keys, commands, options tables), About (why)
```

Each page is one kind. A landing/contents page only introduces and links;
it is the one place where kinds sit side by side, each under its heading.

Rules specific to paw:

- **:help reads these files** (runtime/lua/paw/help.lua): docs/**.md,
  extensions' README.md and doc/*.md. Tags come from headings and from code
  spans at their first description, so keep each key, command (`:s`),
  option (`'timebind'`) and Lua name described once, in reference, in the
  first column of a table or at the start of a list item. Other pages
  mention it as code and link to it.
- **Tests read the docs**: a test checks every command and key an extension
  registers appears in its README; tutor tests check the course matches
  the lessons; tests/apidoc.lua checks api.md is current. Run
  `nix develop -c tests/tools/suite.sh` after any move.
- **Links**: relative Markdown links; after moving a page, grep the whole
  repo (code comments, manifests, READMEs, tests, flake.nix) for the old
  path and fix every one. Code comments point at reference or explanation, never tutorials.
- **Style** (the house voice): plain, short sentences; terminal first, the
  window second; British spelling as already used; no marketing words; no
  emoji; never name the owner's unpublished projects or home paths.
- **Pictures** belong to tutorials (what you will see) and to landing pages
  (what paw is). Reference may have a screenshot of a view's layout with
  labels. Keep their make scripts (docs/images/make, extensions' images/make).

## Workflow

Diátaxis is a guide, not a plan: structure "develops from within" by improving pieces.

1. **Choose** a piece: a page, a section, a paragraph.
2. **Assess** it with the compass: what need does it serve, how well? Does
   its language fit its kind? What should be added, moved, removed?
3. **Decide** the single next change that improves it now: split a mixed
   section, move a paragraph to its kind's page, retitle a guide "How to…",
   cut an option list from a how-to and link the reference.
4. **Do it and commit** (with its links and tests fixed). Repeat.

Never create empty quadrant folders or placeholder pages ("It's horrible");
a folder appears when the first real page moves into it. Documentation is
never finished but should always be complete: useful, accurate, and in a
healthy structural state after every commit.

Quality: functional quality (accurate, complete, consistent, precise) is
the craft's job and comes first — check every fact against the code and
by running paw. Diátaxis then gives the conditions for deep quality: flow,
fit to the user's need, anticipating the reader.

## Checklist before calling a docs change done

- [ ] Every page (and every section of a landing page) is one kind, by the compass.
- [ ] Tutorials: "we", one path, results shown at each step, no choices, minimal explanation linked.
- [ ] How-tos: titled "How to …", goal-first, conditional imperatives, no teaching, links to reference.
- [ ] Reference: neutral, structured like the machinery, consistent entries, each name described once.
- [ ] Explanation: "About …", why/context/alternatives, no steps or option tables.
- [ ] docs/README.md and the README landing pages link the new or moved pages.
- [ ] No stale path anywhere (`grep -rn "docs/<old>"`), `:help <tag>` still lands, suite green.
