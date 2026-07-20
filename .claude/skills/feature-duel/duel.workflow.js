export const meta = {
  name: 'feature-duel',
  description: 'Two agents implement one feature in parallel isolated worktrees, each opens a PR; a judge picks the winner and grafts the loser\'s salvageable bits onto it. Stops at graft — a human merges.',
  phases: [
    { title: 'Plan', detail: 'two lenses plan the same task independently' },
    { title: 'Build', detail: 'each implements in its own worktree, runs tests, opens a PR' },
    { title: 'Judge', detail: 'compare both PRs, pick winner, list salvage items' },
    { title: 'Graft', detail: 'apply salvage onto the winner PR; leave both open' },
  ],
}

const task = args && args.task
const base = (args && args.base) || 'dev'
if (!task) throw new Error('feature-duel: args.task is required (the feature to implement)')

// Two deliberately different lenses so the duel is meaningful, not two identical diffs.
const LENSES = [
  { key: 'minimal', branch: 'duel/minimal', hint: 'Smallest correct diff. Touch as few files as possible, match existing patterns exactly, no refactors.' },
  { key: 'clean', branch: 'duel/clean', hint: 'Cleanest design given how the repo actually works. Refactor where it makes the change clearer; prefer clarity over diff size.' },
]

const PLAN_SCHEMA = {
  type: 'object',
  required: ['approach', 'files', 'tests'],
  properties: {
    approach: { type: 'string', description: 'The chosen approach in a few sentences' },
    files: { type: 'array', items: { type: 'string' }, description: 'Files to create/modify' },
    tests: { type: 'string', description: 'What tests to add and why they cover the fix' },
    risks: { type: 'string' },
  },
}

const BUILD_SCHEMA = {
  type: 'object',
  required: ['branch', 'opened', 'summary'],
  properties: {
    branch: { type: 'string' },
    prNumber: { type: ['integer', 'null'] },
    prUrl: { type: ['string', 'null'] },
    opened: { type: 'boolean', description: 'true if a PR was opened' },
    testsPassed: { type: 'boolean' },
    summary: { type: 'string', description: 'What was implemented + test result' },
  },
}

const JUDGE_SCHEMA = {
  type: 'object',
  required: ['winner', 'reasons', 'salvage'],
  properties: {
    winner: { type: 'string', enum: ['minimal', 'clean'], description: 'Which lens won' },
    reasons: { type: 'string', description: 'Why the winner is superior (gaps/bugs/coverage/cleanliness/perf)' },
    salvage: {
      type: 'array',
      description: 'Concrete things the LOSER did better, worth grafting onto the winner',
      items: {
        type: 'object',
        required: ['what', 'where'],
        properties: {
          what: { type: 'string', description: 'The specific improvement to bring over' },
          where: { type: 'string', description: 'File(s) / area in the loser PR it lives in' },
        },
      },
    },
  },
}

// ---- Phase 1: Plan (two independent lenses) ----
phase('Plan')
const plans = await parallel(LENSES.map(l => () =>
  agent(
    `You are planning an implementation, optimizing for the "${l.key}" lens: ${l.hint}\n\n` +
    `TASK:\n${task}\n\n` +
    `Read the repo's CLAUDE.md and the relevant code first. Produce a concrete step-by-step plan: ` +
    `files to touch, the approach, and which tests to add. Do NOT write code — plan only.`,
    { label: `plan:${l.key}`, phase: 'Plan', schema: PLAN_SCHEMA },
  ).then(p => ({ lens: l, plan: p }))
))

// ---- Phase 2: Build (each in an isolated worktree, opens a real PR) ----
phase('Build')
const builds = await parallel(plans.filter(Boolean).map(({ lens, plan }) => () =>
  agent(
    `Implement this feature on a fresh branch, in this isolated worktree, following the plan below.\n\n` +
    `LENS: ${lens.key} — ${lens.hint}\n\n` +
    `TASK:\n${task}\n\n` +
    `PLAN:\n${JSON.stringify(plan, null, 2)}\n\n` +
    `Steps, in order:\n` +
    `1. Create branch "${lens.branch}" from "${base}" (git checkout -b ${lens.branch} ${base}; if it exists, reset it to ${base}).\n` +
    `2. Implement the change. Add the tests from the plan. Follow the repo's CLAUDE.md conventions.\n` +
    `3. Run the suite with \`make test\` and make it pass. Record the result.\n` +
    `4. Commit (no self-signing, no personal info per repo rules). Push: git push -u origin ${lens.branch}.\n` +
    `5. Open a PR with gh: base "${base}", head "${lens.branch}", title prefixed with the lens, ` +
    `body summarizing the approach. Do NOT merge — opening only (repo CONTRIBUTING forbids AI merges).\n` +
    `Return the branch, PR number+url, whether tests passed, and a short summary.`,
    { label: `build:${lens.key}`, phase: 'Build', isolation: 'worktree', schema: BUILD_SCHEMA },
  ).then(b => ({ lens: lens.key, ...b }))
))

const opened = builds.filter(Boolean).filter(b => b.opened)
if (opened.length < 2) {
  log(`Only ${opened.length}/2 PRs opened — skipping judge/graft. Inspect the build results.`)
  return { builds, judged: null }
}

// ---- Phase 3: Judge ----
phase('Judge')
const prRefs = opened.map(b => `${b.lens}: PR #${b.prNumber} (${b.branch})`).join('\n')
const judged = await agent(
  `Two PRs implement the SAME task. Compare them and pick the superior one.\n\n` +
  `TASK:\n${task}\n\n` +
  `PRs:\n${prRefs}\n\n` +
  `Read both PRs with gh (gh pr view / gh pr diff). Judge on: implementation gaps, bugs introduced, ` +
  `test coverage of what it fixes, cleanliness vs the repo's conventions, and performance. ` +
  `Pick the winner. Then list the concrete things the LOSER did better that are worth grafting onto the winner. ` +
  `Do not merge anything.`,
  { label: 'judge', phase: 'Judge', schema: JUDGE_SCHEMA },
)

// ---- Phase 4: Graft (apply salvage onto the winner; stop — human merges) ----
phase('Graft')
const winner = opened.find(b => b.lens === judged.winner)
const loser = opened.find(b => b.lens !== judged.winner)
let graftSummary = 'No salvage items — winner left as-is.'
if (judged.salvage && judged.salvage.length && winner) {
  const grafted = await agent(
    `Graft the loser's good bits onto the WINNER branch, then update its PR. Do NOT merge either PR.\n\n` +
    `WINNER branch: ${winner.branch} (PR #${winner.prNumber})\n` +
    `LOSER branch: ${loser.branch} (PR #${loser.prNumber})\n\n` +
    `Salvage items to bring over:\n${JSON.stringify(judged.salvage, null, 2)}\n\n` +
    `Steps: check out ${winner.branch}, apply each salvage item (cherry-pick or re-implement from ${loser.branch} — ` +
    `never \`git merge\`), run \`make test\` green, commit, and push to update PR #${winner.prNumber}. ` +
    `Add a PR comment noting what was grafted from the loser. Return a short summary of what you grafted.`,
    { label: 'graft', phase: 'Graft' },
  )
  graftSummary = grafted
}

return {
  base,
  winner: { lens: judged.winner, ...winner },
  loser: loser ? { lens: loser.lens, prNumber: loser.prNumber } : null,
  reasons: judged.reasons,
  salvage: judged.salvage,
  graftSummary,
  note: 'Both PRs left open. Human merges the winner (AI merge forbidden by CONTRIBUTING.md).',
}
