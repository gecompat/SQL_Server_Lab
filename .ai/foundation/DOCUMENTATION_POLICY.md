# Documentation Policy

Status: AUTHORITATIVE — REQUIRED documentation outcomes; PROJECT_SELECTABLE presentation

## Purpose and rule classes

Human documentation MUST remain understandable across the complete reading path: orientation, preparation, use or learning, result interpretation, troubleshooting, technical reference, and project maintenance where applicable. This applies to software, research, education, data, documentation, and other knowledge projects.

`REQUIRED` outcomes are understandable reading paths, navigable storage, separate AI control, discoverable authoritative sources, and truthful current/historical boundaries. The adoption section defines how these outcomes apply to existing material. Language, suitable directory names, documentation tools, and presentation are `PROJECT_SELECTABLE`. No fixed page template, per-page metadata, documentation schema, new validator, or universal length/depth limit is required.

## Reader tasks and complete paths

Write for the intended reader and stated subject knowledge. A reader MUST be able to follow a path without chat history or unexplained internal work-item identifiers. Purpose, relevant prerequisites, and the next useful step must be evident from the content or its immediate context; they need not be repeated on every page.

Human-facing paths MUST continue coherently across linked pages. Explain preparation, ordered actions or learning steps, the expected result and its interpretation, relevant limitations, and help for deviations as appropriate to the task. An explanation or reference page can link to the corresponding procedure rather than duplicate it. A research or planning project may lead to understanding findings, assumptions, or proposed work instead of running software.

Do not switch an instructional path unexpectedly into development logs, review receipts, or continuation commands. Introduce necessary concepts before relying on them. Link technical depth where it answers the reader's next question. Examples, commands, technical status values, and JSON contracts are appropriate when they serve that reader task.

## Root README

README is an entry point, not a governance duplicate. It MUST explain the project's purpose, intended audience, actually available scope, and suitable next reading paths. Include or clearly link relevant prerequisites, important limitations, license terms, and an understandable maturity statement. A short directory overview is useful when it improves orientation; keep its purposes clear.

Detailed test runs, PR acceptance receipts, work logs, internal work-package progress, and AI continuation instructions belong in their designated sources. Link briefly to contribution/project maintenance guidance and to the explicitly identified AI entry point. A concise statement such as prototype, unreleased, or supported platform is useful product information; a sequence of test or implementation checkpoints is not an introduction.

Preserve required legal notices and protected license blocks. This policy does not authorize changing their text or placement against applicable project rules.

## Separate content by purpose

| Area | Content and reading role |
| --- | --- |
| Human guidance | Explanations, learning paths, setup, use, operation, and troubleshooting |
| Shared technical sources | Architecture, APIs, rules, schemas, and domain contracts used by both humans and machines |
| Project planning and evidence | Roadmaps, decisions, current work state, test matrices, and historical acceptance, with explicit purpose and currency |
| AI control | Agent instructions, context selection, handoffs, and control metadata, reached through an explicitly identified entry point |

Separate these purposes in storage and navigation. Shared contracts MUST retain one authoritative source; do not create competing human and AI versions of the same rule. Being consumed by AI does not make a document AI control. Product APIs, machine-readable application outputs, and their examples remain part of the relevant technical documentation.

## Directory structure and navigation

The purpose of important areas MUST be evident from their names or a suitable overview. Distinguish current guidance, historical material, evidence, and AI control. Existing structures may remain when they support those outcomes; different projects need not adopt identical folder names.

Correct ambiguous parallel locations, competing entry points, and unclear ownership of information. When improved indexing or links cannot make the structure understandable, reorganize the affected storage. Update links, generators, configuration, and other path consumers together; preserve durable identifiers, historical references, protected content, and required compatibility paths. Such work remains subject to the actual task's authorization and scope. Record a needed migration outside that scope as a concrete gap rather than treating the existing layout as acceptable.

## Human inspection of AI and machine information

The named AI entry point MUST lead to relevant active project rules and authoritative sources. At a suitable entry for each coherent machine-information area, explain its purpose, authoritative versus derived representations, relevant schema/generation/validation relationships, and where to investigate errors and evidence. Link existing explanations rather than document every machine record a second time.

A human investigating a path must be able to follow the applicable instructions to the contract, schema or manifest, source/generator where relevant, and validation evidence or its explicit absence. Discovery links remain scoped navigation, not a command to read all linked sources. Preserve privacy and non-versioned runtime-state boundaries.

## Actual state, history, and source integrity

Documentation MUST describe actual state. Never present planned work as implemented, an unexecuted check as passed, unsupported compatibility as verified, or an invented source/decision as fact. Keep authoritative contracts, explanation, and historical/evidence artifacts visibly distinct.

Keep changes scoped to the affected subject. Preserve license, copyright, attribution, and historical decision text unless explicitly authorized.

Integrate behavior changes into the appropriate explanation or procedure. Do not continually prepend feature announcements, test chronologies, or acceptance notes ahead of its actual introduction. Retain historical evidence at its dated scope; it does not automatically qualify a newer version.

Avoid repeated mutable inventories and status claims. Where a useful projection is generated or maintained elsewhere, identify the authoritative source and its derivation. Update, deprecate, supersede, or archive stale material rather than silently rewriting history. Source-based work distinguishes primary/secondary sources, empirical findings, inferences, assumptions, and uncertainty. The project selects natural language; technical identifiers and established terms retain canonical spelling.

## Gradual adoption and maintenance

New and materially changed documentation paths MUST meet this policy, including the necessary continuation pages. A feature or workflow change includes the documentation paths it affects. Mechanical spelling or formatting corrections do not trigger an unrelated full-repository rewrite.

On installation/upgrade into an existing project, assess the central human paths, the AI entry point, and visible structural problems. Preserve equivalent or stronger project behavior. Record remaining legacy gaps in the existing project planning system with concrete scope, responsible owner or role, and a resumption trigger. Respect the project's Registration Authority where applicable; no separate documentation register is required.

An upgrade may complete with these explicit, planned legacy gaps, provided the new rules are integrated, active contradictions are resolved, and new/materially changed paths comply. Report the remaining scope and do not claim complete documentation conformity. This transition is not a permanent exemption: the affected gap must be addressed when its trigger or a material change to that path is reached. Scope an unauthorized broader migration as follow-up work instead of silently expanding the task.

## Change-driven drift prevention and bounded context

For each coherent material change, determine affected documentation paths or justify no documentation impact in the existing change/validation evidence. Include changes to behavior, APIs, defaults, configuration, schemas, generators and file locations even when no documentation file was edited. Update affected guidance with the change; use the gradual-adoption contract for unrelated legacy gaps.

Select the relevant sources and paths locally using the actual working-tree diff, focused searches, existing source links and known dependencies. Include necessary continuation pages and transitive dependencies. A missing dependency map is not proof of no impact: inspect the relevant boundary, expand only as needed, and report unresolved coverage rather than claiming acceptance. No new documentation registry or per-page metadata is required.

Use existing deterministic checks first for links/anchors, generated views, schemas and other applicable contracts. Give a model bounded changes, necessary surrounding context and compact findings with source locations; do not routinely send the documentation corpus or full successful logs. Link validity alone cannot detect a factually obsolete instruction.

Apply the [processing efficiency policy](PROCESSING_EFFICIENCY_POLICY.md) to analysis reuse. Verify current authority, scope, actual selected source bytes and relevant dependencies, including non-documentation sources. A changed dependency invalidates affected analysis even if the documentation bytes are unchanged. Reuse only analysis actually still available; hashes and past success do not reconstruct lost understanding. In a new session or after analysis loss, read the selected relevant scope, not automatically the whole repository.

Complete affected-path coverage does not require repeatedly ingesting every full page: assess changed passages in context and combine them with valid retained analysis of unchanged portions. Broaden semantic inspection for a concrete finding, unresolved impact boundary or existing gate; bound and explain that scope. A timer, new commit or unchanged status alone does not justify a whole-corpus reread or another model review. Existing mandatory checks and independent-review obligations remain in force. Token savings are not a semantic correctness guarantee or a measured claim without evidence.

## Proportionate acceptance

The responsible author follows affected paths as the intended reader, including necessary linked pages and a relevant troubleshooting/technical-inspection path, using the bounded-context procedure above. Check purpose, prerequisites, actions or learning sequence, results, interpretation, limitations, navigation, and AI/source discoverability where applicable. Check path consumers after a reorganization.

Use existing link checks; inspect relevant links manually where no checker exists. Record the paths, result, source binding, and remaining gaps in the existing PR or validation evidence. This does not create a new per-action report system. Extra independent reviews or model calls require an existing obligation or a concrete unresolved risk.

Useful acceptance cases include a coherent newcomer task, rejection of a Getting Started page front-loaded with internal test history, acceptance of a concise prototype/safety/directory explanation, human tracing from AI entry to contract/format/evidence, intact references after relocation, and explicit legacy-gap handling during upgrades.

Readability and path coherence are `PROJECT_SEMANTIC` judgments under `VALIDATION_POLICY.md`. Installation/upgrade tests check transfer, discovery, and preservation of project content. A green `FOUNDATION_INTEGRITY` result does not certify human understanding or complete documentation conformity.
