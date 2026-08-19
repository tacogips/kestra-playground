# Per-Category Batch Group CI/CD

This document defines how a single GitHub repository can hold every batch group of one EC site while
still allowing each category team (food, electronics, and so on) to release only its own batches.
It covers the repository layout, the Kestra namespace boundary, the GitHub Actions structure, and
the guardrails that make a single-category release provably unable to affect another category.

## Requirements

- Keep all categories of one EC site in one GitHub repository.
- Let each category be owned, reviewed, and released by a different development team.
- Allow a food-only change to deploy food flows and food batch code without redeploying or
  restarting anything owned by another category.
- Make cross-category impact structurally impossible, not merely conventional.
- Keep CI configuration data-driven so adding a category does not require editing workflow YAML.
- Derive release scope from the trigger rather than from a run-time human selection.
- Keep a single integration branch; do not encode the category boundary in branches.
- Reuse the existing `batch-groups/<group>/` convention and `scripts/deploy-batch-group.sh` entry
  point rather than introducing a second release path.

## Core Principle

One directory equals one Kestra namespace equals one GitHub Actions deploy job equals one owning
team. Path filters, CODEOWNERS, GitHub Environments, concurrency keys, and cloud credentials all
derive from that single alignment. When those four drift apart, category-scoped release stops being
safe, because a change reviewed by one team can be applied to another team's runtime scope.

## Repository Layout

The deploy unit is any directory containing a `group.yaml` marker. Discovery by marker file instead
of by fixed path depth keeps nesting free and lets a new category be added without workflow edits.

```text
batch-groups/
  ec/
    food/
      group.yaml
      flows/                    # namespace: playground.ec.food
      batches/
      config/envs/{local,gcp}.env.example
      tests/
    electronics/
      group.yaml
      flows/                    # namespace: playground.ec.electronics
      batches/
      ...
    _shared/                    # subflows and libraries used by every category
      flows/                    # namespace: playground.ec.shared
      lib/
  affiliate/                    # existing separate batch group, unchanged
```

## Deploy Unit Manifest

`group.yaml` replaces the hardcoded `ec|affiliate` case statement in `scripts/deploy-batch-group.sh`
and becomes the only source of per-group deployment facts.

```yaml
# batch-groups/ec/food/group.yaml
id: ec-food
namespace: playground.ec.food        # deploy scope, enforced by CI lint
owners: "@org/team-food"
kestra:
  tenant: main
  url_var: EC_KESTRA_URL             # GitHub repository or environment variable name
  auth_secret_prefix: kestra-dev-gke
runtime:
  worker_group: ec-food
environments:
  staging: ec-food-staging
  prod: ec-food-prod
  dev: ec-food-dev                   # only under arrangement B (pre-merge dev)
release_tag_prefix: ec-food/         # production release trigger namespace
depends_on:
  - playground.ec.shared
```

The deploy script must accept only a group directory and derive the namespace, target URL, and
credentials from this manifest. It must never accept a namespace as a workflow input, because that
would reopen the cross-category path that the layout is designed to close.

## Kestra Namespace Boundary

Namespaces are hierarchical, so a namespace prefix per category makes namespace-scoped KV entries,
secrets, plugin defaults, and Enterprise namespace RBAC per-team automatically.

| Category | Namespace |
|----------|-----------|
| Food | `playground.ec.food` |
| Electronics | `playground.ec.electronics` |
| Shared subflows | `playground.ec.shared` |

### Declarative Namespace-Scoped Deployment

`scripts/register-flows.sh` currently POSTs each flow file individually. That makes deployment
additive only: a flow deleted from `food/flows/` remains live in Kestra indefinitely. The group
deploy should instead apply a whole directory as the desired state of exactly one namespace, which
is what Kestra's own CI/CD tooling does.

Use the official actions rather than hand-rolled `curl`:

```yaml
- uses: kestra-io/validate-action@<pinned-sha>
  with:
    directory: batch-groups/ec/food/flows
    resource: flow
    server: ${{ vars.EC_KESTRA_URL }}
- uses: kestra-io/deploy-action@<pinned-sha>
  with:
    namespace: playground.ec.food
    directory: batch-groups/ec/food/flows
    resource: flow
    server: ${{ vars.EC_KESTRA_URL }}
    # delete defaults to true: server-side flows absent from the directory are removed
```

Two properties of this tooling matter for the design:

- **Deletion is the default, not an opt-in.** Resources present on the server but absent from the
  directory are removed unless `delete: false` (CLI: `--no-delete`) is passed. The repository
  directory is therefore the source of truth by default, which is exactly the desired semantic. Do
  not disable it; a group that opts out silently accumulates orphaned flows.
- **Exactly one namespace per invocation.** The action deliberately refuses multi-namespace
  deployment, which fits the per-group matrix precisely: one matrix job, one group, one namespace,
  one action call.

The CLI equivalent, for local and script use, is
`kestra flow namespace update <namespace> <directory> --server <url>`, with `--no-delete` to opt out.
The same `resource: namespace_files` form deploys the group's batch code (see below).

This yields the property the whole design rests on: a food deploy can only add, change, or remove
flows inside `playground.ec.food`, and is structurally incapable of touching another namespace.

### Batch Code Delivery

Namespace-scoped flow deployment is not sufficient on its own. If every category's Python lives in
one shared runtime image, a food-only release still rebuilds and rolls the image that all teams
depend on, which reintroduces the coupling. Choose one of:

| Option | When to use | Effect |
|--------|-------------|--------|
| Kestra Namespace Files | Default | Upload `food/batches/` into `playground.ec.food`; flows resolve them through `nsfile:///`. No image rebuild, fully per-category. |
| Per-category image | Divergent OS or system dependencies | Build `batch-ec-food:<sha>` and pin the tag in that category's flows only. |

### Runtime Isolation

Give each category its own worker group so an electronics backfill cannot starve the food nightly
batch. On Enterprise this is the Worker Group feature; on OSS it maps to the routed-worker mechanism
already present under `kestra/flows-worker-routing/`. See
`design-docs/specs/design-kestra-enterprise-worker-group-mechanism.md` and
`design-docs/specs/design-oss-worker-routing-sequence.md`.

## Git Strategy

This section is platform-neutral: it defines which refs exist, what each one means, and which ref is
released where. Nothing here depends on GitHub. How each rule is actually enforced is a separate
concern, covered in `## GitHub Enforcement Mapping`.

### The Branch Is Not The Category Boundary

The tempting design is a long-lived branch per category (`food/main`, `electronics/main`) so each
team "owns" its line. It must be rejected. A branch is a repository-wide construct, but the release
unit here is a directory. Per-category branches therefore fork `_shared/`, `scripts/`, CI
definitions, Terraform, and Kubernetes manifests along a boundary that has nothing to do with those
files, and every shared change turns into a cross-team merge negotiation, which is precisely the
coupling the layout exists to remove.

Category independence must come from the deploy scope (directory to namespace) and from the release
trigger (per-category tag), not from branching. Once those two are in place, a single branch is
sufficient and a second one is a liability.

### Why There Is No `develop` Branch

The familiar `feature` / `develop` / `main` model is GitFlow. In GitFlow, `develop` is the real
integration branch and `main` is a record of what is in production, with releases prepared on
`release/*` branches cut from `develop`. Every one of those roles is already filled here, and by
something better suited to this repository.

`develop` is redundant because **`main` is the integration branch**, and `main` as a
production-record is redundant because **per-category tags already record what is in production**,
more precisely than a branch could.

That last point is the decisive one. The `develop` / `main` split assumes a single release line for
the whole repository, so that "what is in production" is one commit. Here there is no such commit:
food and electronics release independently, so production state is N facts, not one. A `main` branch
cannot represent N independent release points. N tag lines represent them natively.

The concrete harm of adding `develop` to this design:

- **It reintroduces a repository-wide synchronization point.** Every category's release would require
  a `develop` to `main` merge, which is repo-wide by nature. Food releasing would drag electronics'
  unreleased `develop` commits into `main`. A per-directory release model cannot afford a
  whole-repository merge in its release path; that is the same coupling that per-category branches
  were rejected for.
- **It breaks the staged-content gate.** Staging would track `develop` while production tags are cut
  from `main`, separating the content that was staged from the content that ships by a merge that can
  conflict or reorder. The gate would either fail constantly or have to be weakened into a formality.
- **It is what the branching evidence penalizes.** See the DORA nuance below: the objection is not to
  the name, but to the delayed integration that GitFlow's four branch classes and its
  `develop`-to-`main` batch merge institutionalize.

What `develop` is actually wanted for, and what provides it here instead:

| Wanted from `develop` | Provided here by |
|-----------------------|------------------|
| An integration point before production | The staging environment plus the staged-content gate |
| `main` always equal to production | Per-category release tags and deployment records |
| Keeping unfinished work out of production | Feature flags; flows deployed with `disabled: true` |
| Batching changes and deciding when to ship | The standing release pull request per category, which batches per group rather than repository-wide |

#### What DORA Actually Says About `develop`

DORA does not forbid a `develop` branch, and does not mention branch names at all. It defines
trunk-based development through measurable behaviour: three or fewer active branches in the
repository, branches merged to trunk at least daily, branches typically living hours rather than days
or weeks, and no code freezes or integration phases.

A `develop` branch that receives merges daily and releases continuously therefore satisfies DORA
perfectly. It is trunk-based development with the trunk called `develop`. The measured variable is
integration frequency, not nomenclature.

The objection to GitFlow is consequently not the existence of `develop` but the **combination**:
`develop`, `main`, `release/*`, and `hotfix/*` is already at or past the three-active-branch mark
before any feature work exists, and the `develop` to `release/*` to `main` path is a batch
integration phase by construction. That is what the evidence penalizes.

Worth noting: GitFlow's author added a reflection to the original 2010 post on 2020-03-05, scoping it
away from this use case himself. He notes the model was designed for software with explicit
versioning and multiple supported versions, and advises that teams doing continuous delivery "adopt a
much simpler workflow (like GitHub flow) instead of trying to shoehorn git-flow into your team".

#### Honest Adoption Picture

"Modern development does not use `develop`" is too strong a claim. Trunk-based development is the
direction of travel and the DORA-correlated practice, but GitFlow-style workflows retain substantial
real-world share, particularly for versioned, on-premises, and long-supported products. Secondary
reports place GitFlow around 22% in JetBrains' 2023 developer survey, and at least one recent
academic survey found branch-based workflows still outnumbering trunk-based among its respondents.
These figures are cited from secondary summaries rather than primary reads and should be treated as
indicative rather than exact.

Two observations keep this from being an argument for `develop` here. Trunk-based development is
documented as working at scale in highly regulated sectors including healthcare and finance, so
regulatory pressure is not on its own a reason to adopt GitFlow. And adoption share measures what
teams do, not what correlates with delivery performance; the DORA association is with integration
frequency regardless of which camp a team believes it is in.

`develop` is the right choice when `main` must always equal a shipped artifact: versioned products
with scheduled releases and long QA cycles, on-premises or mobile software, or regulated environments
requiring a branch that mirrors production exactly. A continuously deployed internal batch platform
with independent per-category releases is none of those.

### Ref Model

Trunk-based with short-lived branches.

| Ref | Meaning | Lifetime |
|-----|---------|----------|
| `main` | Single integration branch; always releasable | Permanent |
| `<group-id>/<topic>` | Feature or fix work for one category | Short; deleted at merge |
| `release/<group-id>/<line>` | A production line that `main` has moved past | Created on demand from a released tag, deleted when the line retires |
| `<group-id>/v<version>` (tag) | The production release unit for one category | Permanent |

### Ref-To-Stage Policy

| Stage | Ref released |
|-------|--------------|
| Local | The developer's working tree, against a local Kestra |
| Dev (optional, arrangement B only) | A `<group-id>/<topic>` branch, for its own group only, pre-review |
| Staging | Tip of `main`; temporarily a `release/*` branch during a hotfix, as a step inside the release run |
| Production | A `<group-id>/v<version>` tag, cut from `main` or from a `release/*` branch |

A push to a `release/*` branch deploys nothing by itself. Release branches have no push trigger at
all: they reach staging and production only through the tag-triggered release workflow, which stages
and then releases as one gated sequence. This keeps the branch inert between the cherry-pick and the
tag, and keeps every path to production tag-triggered without exception.

Staging releases the tip of `main` and nothing else. Its only job is to answer "would this work in
production," which is meaningful only if it reflects the integrated state production will be cut
from. Fed by a feature branch, a tag, or a per-category branch, it measures a state nobody will
release.

### Why A Shared `main` Is Safe Across Teams

When electronics tags a commit, that commit also contains food's merged changes, but the electronics
release applies only `batch-groups/ec/electronics/` to `playground.ec.electronics`. Food's changes
are inert for that release. Release scope is decided by directory, not by what else happens to be in
the commit. That property is what makes a shared `main` workable.

If food merges a change that fails staging, electronics is not blocked: production is tagged at a
commit of the releasing team's choosing, so electronics tags the last commit that staged cleanly for
its own group. Cross-team decoupling comes from tag selection, not from branch isolation.

### The `_shared/` Leak

One real consequence of a shared `main`: if food merges a `_shared/` change and electronics later
tags a commit that includes it, electronics releases a shared change it did not initiate. At the git
level this implies three policies, whose enforcement is listed in the mapping section:

- `_shared/` changes require review from every owning team.
- Shared changes stay backward compatible for at least one release cycle.
- A releasing team must be shown which shared changes its tag inherits since that group's previous
  release tag.

### Staged-Content Rule

A tag reaches production only if that group's content was previously proven on staging.

Comparing commit SHAs cannot express this, because staging deploys only changed groups, so an
unchanged group has no staging deployment at the tagged SHA. The rule is therefore stated over
content, not history: the group's release inputs at the tagged commit (its own directory,
`_shared/`, and the deploy scripts) must be identical to inputs that already staged successfully.
An unchanged group passes on what it was last staged with, while any un-staged modification,
including one arriving through `_shared/`, fails.

### Rollback

Rollback is a new tag on the last-good commit, for example `ec-food/v2026.08.19-2` pointing at the
commit released by `ec-food/v2026.08.18-1`. It travels the same path with the same gates, so there
is no untested emergency-only mechanism.

### Hotfix Procedure

Production is running `ec-food/v2026.08.18-1`, `main` has since taken further merges, and food
production breaks. Work the decision rule in order and stop at the first path that applies.

| # | Condition | Action | Cost |
|---|-----------|--------|------|
| 1 | A previous release is known good and rolling back is acceptable | Tag the last-good commit and release it | Lowest; no new code |
| 2 | This group's release inputs on `main` are releasable | Fix on a short branch, merge to `main`, tag from `main` | Low; no divergence |
| 3 | This group's release inputs on `main` are not releasable | Cut `release/<group-id>/<line>` from the released tag, fix, tag from the branch | Highest; creates divergence that must be repaid |

Prefer rollback. Time to recovery is the metric that matters, and a rollback introduces no new code
into a system that is already misbehaving. Reach for a hotfix only when rollback is unavailable:
a migration already ran, the batch already wrote bad data, or the previous version is broken too.

#### Path 2 Is Usually Available

The instinct from whole-repository releases is that "`main` has moved on" forces a release branch.
Here it usually does not, and that is a direct payoff of making the release unit a directory.

What blocks releasing from `main` is not activity on `main` in general, but unreleasable changes to
**this group's release inputs**: its own directory, `_shared/`, and the deploy scripts. Merges from
other categories are inert for a food release, because the food deploy applies only
`batch-groups/ec/food/` to `playground.ec.food`. In a repository where several teams merge daily,
most of the movement on `main` is therefore irrelevant to any single category's hotfix.

Decide it mechanically rather than by judgement: run the same release diff report used for normal
releases, comparing the production tag to the tip of `main` across the group directory, `_shared/`,
and the deploy scripts. An empty or reviewable diff means path 2. Only unreleasable work in that
narrow set forces path 3.

#### Path 3 Mechanics

Cut `release/<group-id>/<line>` from the released tag, then follow the trunk-based rule for fix
direction, which is unidirectional and runs **trunk to branch**:

1. Reproduce the bug on `main`.
2. Fix it on `main`, with a regression test, and let CI verify it there.
3. Cherry-pick that commit onto `release/<group-id>/<line>`.
4. Tag the patch increment on that line, for example `ec-food/v2026.08.18-2`, and release.

Nothing in the release path changes, because the production trigger is the tag rather than the
branch.

Fixing directly on the release branch and forward-porting afterwards is the documented anti-pattern:
the backport is forgotten, and the next ordinary release silently reintroduces the bug weeks later.
Originating every fix on `main` removes that failure mode by construction rather than by process.

Enforce it mechanically: a check on the release branch requiring every commit above the branch point
to be a cherry-pick of a commit reachable from `main`. That is a stronger and simpler gate than
chasing a forward-port pull request after the fact, because it fails before the release rather than
after it.

Two further obligations:

- **Tag before deleting.** Release branches are deleted when the line retires, never merged back to
  trunk. Tag the released commits first so the released code is not garbage collected.
- **Never create these branches in advance.** A `release/*` branch without an active hotfix is a
  per-category long-lived branch under another name, and reintroduces exactly the divergence the git
  strategy rejects. Canonical guidance is to branch for release only under an incompatible-release
  policy, late, and instead of a code freeze.

#### The Staged-Content Gate Under Hotfix

A path 3 hotfix has never been staged, because staging tracks `main`. Taken literally, the
staged-content gate would block every hotfix, which is the point at which teams start bypassing
gates. Resolve it explicitly instead.

For a tag derived from a `release/*` branch, the release workflow itself performs the staging step:
it deploys that group from the release branch to staging, records the release-input hash, and only
then proceeds to production. This is the correct rehearsal, because what is staged is exactly what is
about to be released.

Staging is therefore off-`main` for one group for the duration of the hotfix, which must be logged as
a deliberate deviation. **It is not restored on its own.** The fix reaches `main` before the
cherry-pick, so `main`'s ordinary staging deploy has already run by then; nothing later pushes the
group back. The release workflow must therefore re-stage the group from the tip of `main` as a final
step after production succeeds, and that step must run even when the production deploy fails, or a
failed hotfix strands staging on release-branch content indefinitely.

Both staging deploys use the group's ordinary `deploy-<group>-staging` concurrency key, so a hotfix
staging step and a `main`-triggered staging deploy of the same group serialize instead of racing.

If staging must never deviate from `main` at all, the alternative is a per-group ephemeral hotfix
namespace (`playground.ec.food.hotfix`) that the release branch stages into. It removes the restore
step and the deviation window entirely, at the cost of another environment to provision and clean
up.

#### When The Bug Is In `_shared/`

A fix in `_shared/` is not one category's hotfix. Every group running that shared code in production
needs re-release, and each owning team must tag its own line, because no team may cut another
category's tag. Use the release diff report to enumerate which groups actually have the broken
revision in production; groups whose last release predates it need nothing.

This is the most expensive failure mode in the whole design, and it is the concrete argument for
keeping `_shared/` small and its contents backward compatible. Shared code converts a
single-category incident into an N-category coordinated release.

### When To Split The Repository

If a category eventually shares no code with the others and needs a genuinely independent cadence,
split it into its own repository. Do not approximate that with a long-lived branch: a separate repo
gives real isolation, while a long-lived branch gives permanent merge debt and the illusion of it.

#### Does A Per-Category Repository Make `develop` Viable?

Structurally, yes. The objection to `develop` in the monorepo was that `main` as a production record
cannot represent N independent release lines, and that a `develop` to `main` merge is repository-wide
in a model whose release unit is a directory. Give each category its own repository and both problems
disappear: one repository has exactly one release line, so `main` can coherently mean "what food has
in production", and no merge in food's repository touches electronics at all. GitFlow becomes
internally consistent again.

That makes `develop` **possible**, not **advisable**, and the two should not be confused.

DORA's criteria are unchanged by the split, because they apply per repository: three or fewer active
branches, daily merges, branches living hours, no integration phases. Splitting does nothing to
improve integration frequency. If the food team merges to `develop` daily and releases continuously,
they have trunk-based development with the trunk renamed and gained nothing from the ceremony. If
they do not, they have the same delayed-integration problem as before, now in a smaller repository.

What actually justifies `develop` is the **release model**, not the repository topology: explicit
versioning, multiple concurrently supported versions, and scheduled QA cycles that require `main` to
equal a shipped artifact at all times. A category of continuously deployed internal batch flows does
not acquire any of those properties by moving to its own repository.

#### The Cost Of Splitting Lands Elsewhere

Choosing the repository topology in order to justify a branching model is backwards. Decide topology
from how coupled the code actually is, then choose the branching model that fits how the software
ships. For reference, splitting this repository per category would trade:

| Gained | Lost |
|--------|------|
| One release line per repository, so `main` can mirror production | Atomic cross-category changes; a `_shared/` edit becomes publish, then bump in each consumer repository, in sequence |
| Simpler per-repository CI with no `detect` matrix | N copies of the CI workflows, deploy scripts, Terraform, Kubernetes manifests, and `mise` configuration, which will drift |
| Hard access boundaries between teams | Platform changes must be rolled out N times, since every repository still deploys into the same Kestra instance and shared infrastructure |
| Independent cadence by construction | Cross-category discovery and refactoring, which stop being a single search and a single pull request |

The decisive question is `_shared/`. If the categories genuinely share nothing, splitting is correct
and it is correct regardless of what anyone wants to do with `develop`. If they share meaningful
code, the split converts every shared change from one reviewed pull request into a versioned release
plus N dependency bumps, which is a permanent tax paid to obtain a branching model that the delivery
mode does not require.

## GitHub Enforcement Mapping`.

### The Branch Is Not The Category Boundary

The tempting design is a long-lived branch per category (`food/main`, `electronics/main`) so each
team "owns" its line. It must be rejected. A branch is a repository-wide construct, but the release
unit here is a directory. Per-category branches therefore fork `_shared/`, `scripts/`, CI
definitions, Terraform, and Kubernetes manifests along a boundary that has nothing to do with those
files, and every shared change turns into a cross-team merge negotiation, which is precisely the
coupling the layout exists to remove.

Category independence must come from the deploy scope (directory to namespace) and from the release
trigger (per-category tag), not from branching. Once those two are in place, a single branch is
sufficient and a second one is a liability.

### Why There Is No `develop` Branch

The familiar `feature` / `develop` / `main` model is GitFlow. In GitFlow, `develop` is the real
integration branch and `main` is a record of what is in production, with releases prepared on
`release/*` branches cut from `develop`. Every one of those roles is already filled here, and by
something better suited to this repository.

`develop` is redundant because **`main` is the integration branch**, and `main` as a
production-record is redundant because **per-category tags already record what is in production**,
more precisely than a branch could.

That last point is the decisive one. The `develop` / `main` split assumes a single release line for
the whole repository, so that "what is in production" is one commit. Here there is no such commit:
food and electronics release independently, so production state is N facts, not one. A `main` branch
cannot represent N independent release points. N tag lines represent them natively.

The concrete harm of adding `develop` to this design:

- **It reintroduces a repository-wide synchronization point.** Every category's release would require
  a `develop` to `main` merge, which is repo-wide by nature. Food releasing would drag electronics'
  unreleased `develop` commits into `main`. A per-directory release model cannot afford a
  whole-repository merge in its release path; that is the same coupling that per-category branches
  were rejected for.
- **It breaks the staged-content gate.** Staging would track `develop` while production tags are cut
  from `main`, separating the content that was staged from the content that ships by a merge that can
  conflict or reorder. The gate would either fail constantly or have to be weakened into a formality.
- **It is what the branching evidence penalizes.** See the DORA nuance below: the objection is not to
  the name, but to the delayed integration that GitFlow's four branch classes and its
  `develop`-to-`main` batch merge institutionalize.

What `develop` is actually wanted for, and what provides it here instead:

| Wanted from `develop` | Provided here by |
|-----------------------|------------------|
| An integration point before production | The staging environment plus the staged-content gate |
| `main` always equal to production | Per-category release tags and deployment records |
| Keeping unfinished work out of production | Feature flags; flows deployed with `disabled: true` |
| Batching changes and deciding when to ship | The standing release pull request per category, which batches per group rather than repository-wide |

#### What DORA Actually Says About `develop`

DORA does not forbid a `develop` branch, and does not mention branch names at all. It defines
trunk-based development through measurable behaviour: three or fewer active branches in the
repository, branches merged to trunk at least daily, branches typically living hours rather than days
or weeks, and no code freezes or integration phases.

A `develop` branch that receives merges daily and releases continuously therefore satisfies DORA
perfectly. It is trunk-based development with the trunk called `develop`. The measured variable is
integration frequency, not nomenclature.

The objection to GitFlow is consequently not the existence of `develop` but the **combination**:
`develop`, `main`, `release/*`, and `hotfix/*` is already at or past the three-active-branch mark
before any feature work exists, and the `develop` to `release/*` to `main` path is a batch
integration phase by construction. That is what the evidence penalizes.

Worth noting: GitFlow's author added a reflection to the original 2010 post on 2020-03-05, scoping it
away from this use case himself. He notes the model was designed for software with explicit
versioning and multiple supported versions, and advises that teams doing continuous delivery "adopt a
much simpler workflow (like GitHub flow) instead of trying to shoehorn git-flow into your team".

#### Honest Adoption Picture

"Modern development does not use `develop`" is too strong a claim. Trunk-based development is the
direction of travel and the DORA-correlated practice, but GitFlow-style workflows retain substantial
real-world share, particularly for versioned, on-premises, and long-supported products. Secondary
reports place GitFlow around 22% in JetBrains' 2023 developer survey, and at least one recent
academic survey found branch-based workflows still outnumbering trunk-based among its respondents.
These figures are cited from secondary summaries rather than primary reads and should be treated as
indicative rather than exact.

Two observations keep this from being an argument for `develop` here. Trunk-based development is
documented as working at scale in highly regulated sectors including healthcare and finance, so
regulatory pressure is not on its own a reason to adopt GitFlow. And adoption share measures what
teams do, not what correlates with delivery performance; the DORA association is with integration
frequency regardless of which camp a team believes it is in.

`develop` is the right choice when `main` must always equal a shipped artifact: versioned products
with scheduled releases and long QA cycles, on-premises or mobile software, or regulated environments
requiring a branch that mirrors production exactly. A continuously deployed internal batch platform
with independent per-category releases is none of those.

### Ref Model

Trunk-based with short-lived branches.

| Ref | Meaning | Lifetime |
|-----|---------|----------|
| `main` | Single integration branch; always releasable | Permanent |
| `<group-id>/<topic>` | Feature or fix work for one category | Short; deleted at merge |
| `release/<group-id>/<line>` | A production line that `main` has moved past | Created on demand from a released tag, deleted when the line retires |
| `<group-id>/v<version>` (tag) | The production release unit for one category | Permanent |

### Ref-To-Stage Policy

| Stage | Ref released |
|-------|--------------|
| Local | The developer's working tree, against a local Kestra |
| Dev (optional, arrangement B only) | A `<group-id>/<topic>` branch, for its own group only, pre-review |
| Staging | Tip of `main`; temporarily a `release/*` branch during a hotfix, as a step inside the release run |
| Production | A `<group-id>/v<version>` tag, cut from `main` or from a `release/*` branch |

A push to a `release/*` branch deploys nothing by itself. Release branches have no push trigger at
all: they reach staging and production only through the tag-triggered release workflow, which stages
and then releases as one gated sequence. This keeps the branch inert between the cherry-pick and the
tag, and keeps every path to production tag-triggered without exception.

Staging releases the tip of `main` and nothing else. Its only job is to answer "would this work in
production," which is meaningful only if it reflects the integrated state production will be cut
from. Fed by a feature branch, a tag, or a per-category branch, it measures a state nobody will
release.

### Why A Shared `main` Is Safe Across Teams

When electronics tags a commit, that commit also contains food's merged changes, but the electronics
release applies only `batch-groups/ec/electronics/` to `playground.ec.electronics`. Food's changes
are inert for that release. Release scope is decided by directory, not by what else happens to be in
the commit. That property is what makes a shared `main` workable.

If food merges a change that fails staging, electronics is not blocked: production is tagged at a
commit of the releasing team's choosing, so electronics tags the last commit that staged cleanly for
its own group. Cross-team decoupling comes from tag selection, not from branch isolation.

### The `_shared/` Leak

One real consequence of a shared `main`: if food merges a `_shared/` change and electronics later
tags a commit that includes it, electronics releases a shared change it did not initiate. At the git
level this implies three policies, whose enforcement is listed in the mapping section:

- `_shared/` changes require review from every owning team.
- Shared changes stay backward compatible for at least one release cycle.
- A releasing team must be shown which shared changes its tag inherits since that group's previous
  release tag.

### Staged-Content Rule

A tag reaches production only if that group's content was previously proven on staging.

Comparing commit SHAs cannot express this, because staging deploys only changed groups, so an
unchanged group has no staging deployment at the tagged SHA. The rule is therefore stated over
content, not history: the group's release inputs at the tagged commit (its own directory,
`_shared/`, and the deploy scripts) must be identical to inputs that already staged successfully.
An unchanged group passes on what it was last staged with, while any un-staged modification,
including one arriving through `_shared/`, fails.

### Rollback

Rollback is a new tag on the last-good commit, for example `ec-food/v2026.08.19-2` pointing at the
commit released by `ec-food/v2026.08.18-1`. It travels the same path with the same gates, so there
is no untested emergency-only mechanism.

### Hotfix Procedure

Production is running `ec-food/v2026.08.18-1`, `main` has since taken further merges, and food
production breaks. Work the decision rule in order and stop at the first path that applies.

| # | Condition | Action | Cost |
|---|-----------|--------|------|
| 1 | A previous release is known good and rolling back is acceptable | Tag the last-good commit and release it | Lowest; no new code |
| 2 | This group's release inputs on `main` are releasable | Fix on a short branch, merge to `main`, tag from `main` | Low; no divergence |
| 3 | This group's release inputs on `main` are not releasable | Cut `release/<group-id>/<line>` from the released tag, fix, tag from the branch | Highest; creates divergence that must be repaid |

Prefer rollback. Time to recovery is the metric that matters, and a rollback introduces no new code
into a system that is already misbehaving. Reach for a hotfix only when rollback is unavailable:
a migration already ran, the batch already wrote bad data, or the previous version is broken too.

#### Path 2 Is Usually Available

The instinct from whole-repository releases is that "`main` has moved on" forces a release branch.
Here it usually does not, and that is a direct payoff of making the release unit a directory.

What blocks releasing from `main` is not activity on `main` in general, but unreleasable changes to
**this group's release inputs**: its own directory, `_shared/`, and the deploy scripts. Merges from
other categories are inert for a food release, because the food deploy applies only
`batch-groups/ec/food/` to `playground.ec.food`. In a repository where several teams merge daily,
most of the movement on `main` is therefore irrelevant to any single category's hotfix.

Decide it mechanically rather than by judgement: run the same release diff report used for normal
releases, comparing the production tag to the tip of `main` across the group directory, `_shared/`,
and the deploy scripts. An empty or reviewable diff means path 2. Only unreleasable work in that
narrow set forces path 3.

#### Path 3 Mechanics

Cut `release/<group-id>/<line>` from the released tag, then follow the trunk-based rule for fix
direction, which is unidirectional and runs **trunk to branch**:

1. Reproduce the bug on `main`.
2. Fix it on `main`, with a regression test, and let CI verify it there.
3. Cherry-pick that commit onto `release/<group-id>/<line>`.
4. Tag the patch increment on that line, for example `ec-food/v2026.08.18-2`, and release.

Nothing in the release path changes, because the production trigger is the tag rather than the
branch.

Fixing directly on the release branch and forward-porting afterwards is the documented anti-pattern:
the backport is forgotten, and the next ordinary release silently reintroduces the bug weeks later.
Originating every fix on `main` removes that failure mode by construction rather than by process.

Enforce it mechanically: a check on the release branch requiring every commit above the branch point
to be a cherry-pick of a commit reachable from `main`. That is a stronger and simpler gate than
chasing a forward-port pull request after the fact, because it fails before the release rather than
after it.

Two further obligations:

- **Tag before deleting.** Release branches are deleted when the line retires, never merged back to
  trunk. Tag the released commits first so the released code is not garbage collected.
- **Never create these branches in advance.** A `release/*` branch without an active hotfix is a
  per-category long-lived branch under another name, and reintroduces exactly the divergence the git
  strategy rejects. Canonical guidance is to branch for release only under an incompatible-release
  policy, late, and instead of a code freeze.

#### The Staged-Content Gate Under Hotfix

A path 3 hotfix has never been staged, because staging tracks `main`. Taken literally, the
staged-content gate would block every hotfix, which is the point at which teams start bypassing
gates. Resolve it explicitly instead.

For a tag derived from a `release/*` branch, the release workflow itself performs the staging step:
it deploys that group from the release branch to staging, records the release-input hash, and only
then proceeds to production. This is the correct rehearsal, because what is staged is exactly what is
about to be released.

Staging is therefore off-`main` for one group for the duration of the hotfix, which must be logged as
a deliberate deviation. **It is not restored on its own.** The fix reaches `main` before the
cherry-pick, so `main`'s ordinary staging deploy has already run by then; nothing later pushes the
group back. The release workflow must therefore re-stage the group from the tip of `main` as a final
step after production succeeds, and that step must run even when the production deploy fails, or a
failed hotfix strands staging on release-branch content indefinitely.

Both staging deploys use the group's ordinary `deploy-<group>-staging` concurrency key, so a hotfix
staging step and a `main`-triggered staging deploy of the same group serialize instead of racing.

If staging must never deviate from `main` at all, the alternative is a per-group ephemeral hotfix
namespace (`playground.ec.food.hotfix`) that the release branch stages into. It removes the restore
step and the deviation window entirely, at the cost of another environment to provision and clean
up.

#### When The Bug Is In `_shared/`

A fix in `_shared/` is not one category's hotfix. Every group running that shared code in production
needs re-release, and each owning team must tag its own line, because no team may cut another
category's tag. Use the release diff report to enumerate which groups actually have the broken
revision in production; groups whose last release predates it need nothing.

This is the most expensive failure mode in the whole design, and it is the concrete argument for
keeping `_shared/` small and its contents backward compatible. Shared code converts a
single-category incident into an N-category coordinated release.

### When To Split The Repository

If a category eventually shares no code with the others and needs a genuinely independent cadence,
split it into its own repository. Do not approximate that with a long-lived branch: a separate repo
gives real isolation, while a long-lived branch gives permanent merge debt and the illusion of it.

## GitHub Enforcement Mapping

The git strategy above is a set of rules. Rules that are not mechanically enforced are conventions,
and conventions across teams with different priorities decay. This table binds each rule to the
GitHub mechanism that enforces it, and states what is lost without it.

| Git-level rule | GitHub mechanism | Without it |
|----------------|------------------|------------|
| Only the owning team changes a group directory | `CODEOWNERS` per directory plus required review in branch protection | Convention only; any team can merge into another team's directory |
| `_shared/` changes are reviewed by every owning team | `CODEOWNERS` listing all group teams on `_shared/` | Silent shared regressions land for teams that never saw them |
| `main` stays releasable | Branch protection with required status checks on the pull request | Staging tracks a broken tip and blocks every team's rehearsal |
| Only the owning team cuts a category's production tag | Tag ruleset restricting `<group-id>/v*` to that team | Any team can release any category |
| Production releases are approved by a human | Required reviewers on the `<group>-prod` GitHub Environment | Unreviewed production release |
| A tag reaches production only if its content was staged | Staging job records the release-input content hash on the `<group>-staging` deployment; the release job recomputes it at the tag and requires a match | Un-staged code, including changes inherited through `_shared/`, reaches production |
| A release-branch hotfix originates on `main` | Check on `release/*` requiring every commit above the branch point to be a cherry-pick of a commit reachable from `main` | The fix exists only on the release branch and the next ordinary release silently regresses it |
| Staging returns to `main` after a hotfix | Final re-stage step in the release workflow, running on failure as well as success | Staging silently keeps serving release-branch content for that group |
| A hotfix is rehearsed before production | For a `release/*`-derived tag, the release workflow stages that group from the release branch and records its hash before proceeding | The hotfix reaches production unstaged, or teams learn to bypass the gate |
| A shared change is proven for every group before anyone tags | `detect` fan-out expands a `_shared/` change to all groups on staging | Only the changing group is staged; other groups discover the breakage in production |
| A non-`main` push deploys only its own category | Branch-prefix check in `detect`: on non-`main` refs, skip any group whose id does not match the branch prefix | A feature branch deploys unreviewed code into another category's dev namespace |
| The releasing team sees the shared changes its tag inherits | Release diff report step comparing the tag to the group's previous tag across the group directory and `_shared/` | Blind inheritance of another team's shared changes |
| One category's deploy cannot queue behind another's | Per-group-per-stage `concurrency` keys | Repository-global serialization; teams are parallel in name only |
| One category's failure does not cancel another's deploy | `fail-fast: false` on the deploy matrix | A food failure cancels an in-flight electronics deploy |

```text
# .github/CODEOWNERS
/batch-groups/ec/food/          @org/team-food
/batch-groups/ec/electronics/   @org/team-electronics
/batch-groups/ec/_shared/       @org/team-food @org/team-electronics @org/platform
/.github/workflows/             @org/platform
/scripts/                       @org/platform
```

If the repository ever moves off GitHub, only this table is rewritten. The git strategy, the
directory-to-namespace boundary, and the tag-based release unit are unchanged, because none of them
depend on the hosting platform.

## Promotion And Release Triggers

Each stage uses a different trigger, and the scope of a release is derived from the trigger rather
than chosen by a human at run time.

| Stage | Trigger | Scope selection | Approval |
|-------|---------|-----------------|----------|
| Dev (optional) | `push` to a `<group-id>/<topic>` branch | The one group matching the branch prefix | None |
| Staging | `push` to `main` touching `batch-groups/**` | Groups whose files changed, computed by `detect` | None |
| Production | `push` of a tag matching `<group-id>/v*`, cut from `main` or a `release/*` branch | Exactly the one group named by the tag prefix | Staged-content gate plus GitHub Environment reviewers on `<group>-prod` |

### Environments Must Differ By What They Receive

An earlier draft of this design deployed dev and then staging from the same push, with the same
changed set, from the same commit, in the same workflow run. That is not two environments. It is one
environment deployed twice, at double the wall-clock, producing no signal the first deploy did not
already produce. If the deploy path is broken it fails in both; if the flow is broken it fails in
both.

The rule that avoids this: **two environments are only distinct if they differ in what ref they
receive, in how much they are trusted, or in what substrate they run on.** Sharing all three makes
them the same environment.

That leaves two defensible arrangements.

| Arrangement | Dev receives | Staging receives | Use when |
|-------------|--------------|------------------|----------|
| A. Two deployed environments (default) | Nothing; developers iterate on a local Kestra | Tip of `main`, changed groups | Local runtimes are good enough for pre-merge iteration |
| B. Dev is pre-merge | Pushes to `<group-id>/<topic>` branches, that group only | Tip of `main`, changed groups | A shared, production-adjacent sandbox is genuinely needed before review |

### Arrangement A: Staging And Production Only (Default)

Deploy `main` to staging and tags to production. Pre-merge iteration happens on the local Kestra
runtimes this repository already provides (`local/docker`, `local/apple-container`, and the per-group
`config/envs/local.env`), against the same flows and the same batch code.

This is the recommended default because it removes an environment that had no distinct job, halves
the post-merge deploy time, and eliminates one more surface that can drift from production. It also
dissolves a structural problem the dev-then-staging chain created: with staging gated on the whole
dev matrix, one category's dev failure blocked staging for every category in that run. With a single
post-merge environment, each group's staging deploy is independent by construction.

### Arrangement B: Dev As A Pre-Merge Environment

If a shared sandbox is genuinely needed, make dev differ in **trust level and ref** rather than in
name: dev receives pushes to `<group-id>/<topic>` branches, before review. It is explicitly allowed
to be broken, holds unreviewed code, and is never a gate for anything.

The branch-prefix rule is what makes this safe: on a non-`main` push, only the group whose id matches
the branch prefix may deploy, so a food branch cannot push unreviewed code into the electronics dev
namespace. Collisions between two developers on the same category are accepted; that is what the
environment is for.

Under this arrangement staging still receives only `main`, and dev is never in the promotion path.
Nothing is promoted dev to staging, because dev holds content that was never reviewed.

### Staging

Under either arrangement, staging deploys the tip of `main` automatically, for the groups the push
changed, and it is the only pre-production gate.

Staging exists to prove the runtime topology continuously, so it must track `main` without human
action, and it must run the substrate production actually uses rather than a cheaper approximation.
If staging differs from production in topology, it stops answering the only question it exists to
answer. A staging environment that is merely a second copy of dev is worth removing; a staging
environment that mirrors production is worth paying for.

### Production

Production is triggered by pushing a per-category git tag, for example `ec-food/v2026.08.19-1`. The
tag prefix must equal a `group.yaml` `id`; the workflow resolves the prefix to the group directory
and fails on an unknown prefix.

The category is therefore selected by the tag, not by a `workflow_dispatch` dropdown. This matters
for four reasons:

- The release scope is immutable and recorded in git history, so "which category was released, from
  which commit, by whom" is answerable without reading Actions logs.
- A mis-selected dropdown value is a plausible human error that would release the wrong team's code.
  A mistyped tag prefix simply fails to resolve.
- GitHub tag protection rulesets can restrict `ec-food/v*` to the food team, so a team cannot cut
  another category's production release even accidentally.
- Rollback is a normal operation on the same mechanism rather than a special path.

Production must **not** use change detection. Change detection is a staging convenience.
A production release deploys the full desired state of one named group at one immutable ref, so that
the deployed result depends on the tag's content rather than on git history. Diff-based production
scope would make a re-deploy after a rollback, an unchanged-but-must-be-reapplied group, or a
recovery after partial failure impossible to express.

Consistent with the existing promotion contract in `design-docs/specs/architecture.md`, the tag
should point at a commit whose artifacts were already built and verified during the push-triggered
run. Production resolves the image tag or namespace-file bundle from that commit SHA rather than
rebuilding at release time.

A `workflow_dispatch` path is retained as break-glass only, taking a group id and a ref, and gated by
the same production Environment reviewers.

### Tag Generation

Tags are generated, not hand-typed. Manifest-mode `release-please` with per-component tags is the
widely used implementation of exactly this release unit: each group is a component in the manifest,
Conventional Commits determine the version bump, and a standing release pull request per group
accumulates the changelog until an owner merges it. Merging that pull request creates the tag, which
fires the production workflow described below.

This keeps the release human-initiated and per-category while removing the hand-typed tag as a
failure surface, and it produces a per-group `CHANGELOG` as a side effect. The tag-triggered
production workflow is unchanged, because release-please's output is an ordinary git tag.

### Decoupling Deploy From Enable

Deploying a flow and activating it are separate acts. A flow can be deployed with `disabled: true`,
or with its trigger disabled, and enabled in a later, much smaller change. This is the orchestration
analogue of a feature flag, and it is what keeps `main` releasable while a category's batch is still
being built: incomplete work reaches production inert rather than being held on a branch.

As with feature flags generally, the commonly skipped half of the practice is removal. A flow left
disabled indefinitely is dead code that still deploys; retire it or enable it.

## GitHub Actions Structure

Two workflows, matching the two trigger classes.

### Push Workflow: Staging

`detect` computes which groups changed; `deploy-staging` fans out one independent job per changed
group. There is no second deploy stage in this workflow, because under arrangement A staging is the
only post-merge environment.

```yaml
name: Deploy Batch Groups

on:
  push:
    branches: [main]
    paths: ["batch-groups/**"]
  pull_request:
    paths: ["batch-groups/**"]

permissions:
  contents: read

jobs:
  detect:
    runs-on: ubuntu-24.04
    outputs:
      matrix: ${{ steps.detect.outputs.matrix }}
      any: ${{ steps.detect.outputs.any }}
    steps:
      - uses: actions/checkout@<pinned-sha> # v7.0.0
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: jdx/mise-action@<pinned-sha> # v4.2.4
      - id: detect
        env:
          BASE_SHA: ${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}
        run: mise exec -- scripts/detect-changed-batch-groups.sh >>"$GITHUB_OUTPUT"

  deploy-staging:
    name: Staging ${{ matrix.group.id }}
    needs: detect
    if: github.event_name == 'push' && needs.detect.outputs.any == 'true'
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        group: ${{ fromJSON(needs.detect.outputs.matrix) }}
    concurrency:
      group: deploy-${{ matrix.group.id }}-staging
      cancel-in-progress: false
    environment: ${{ matrix.group.environments.staging }}
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@<pinned-sha> # v7.0.0
        with: { persist-credentials: false }
      - uses: jdx/mise-action@<pinned-sha> # v4.2.4
      - uses: google-github-actions/auth@<pinned-sha> # v3
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
      - name: Deploy group
        env:
          GROUP_DIR: ${{ matrix.group.dir }}
          BATCH_GROUP_STAGE: staging
        run: mise exec -- scripts/deploy-batch-group.sh "$GROUP_DIR"
      - name: Record staged-content hash
        env:
          GROUP_DIR: ${{ matrix.group.dir }}
        run: mise exec -- scripts/record-staged-content-hash.sh "$GROUP_DIR"
```

Every group's staging deploy is independent: its own matrix job, its own concurrency key, its own
Environment, and `fail-fast: false` so one category's failure cannot cancel another's. Nothing in
this workflow serializes the teams.

Under arrangement B, add a separate `deploy-dev` job triggered on `push` to non-`main` branches,
whose matrix is filtered to the single group matching the branch prefix. It is not a dependency of
`deploy-staging` and is never in the promotion path.

### Tag Workflow: Production

```yaml
name: Release Batch Group

on:
  push:
    tags: ["*/v*"]
  workflow_dispatch:
    inputs:
      group:
        description: "Group id (break-glass only)"
        required: true
        type: string
      ref:
        description: "Git ref to release"
        required: true
        type: string

permissions:
  contents: read

jobs:
  resolve:
    runs-on: ubuntu-24.04
    outputs:
      group: ${{ steps.resolve.outputs.group }}   # JSON manifest of exactly one group
    steps:
      - uses: actions/checkout@<pinned-sha> # v7.0.0
        with: { persist-credentials: false }
      - uses: jdx/mise-action@<pinned-sha> # v4.2.4
      - id: resolve
        env:
          RELEASE_REF: ${{ github.ref }}
          DISPATCH_GROUP: ${{ inputs.group }}
        run: mise exec -- scripts/resolve-release-group.sh >>"$GITHUB_OUTPUT"

  release:
    needs: resolve
    runs-on: ubuntu-24.04
    concurrency:
      group: deploy-${{ fromJSON(needs.resolve.outputs.group).id }}-prod
      cancel-in-progress: false
    environment: ${{ fromJSON(needs.resolve.outputs.group).environments.prod }}
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@<pinned-sha> # v7.0.0
        with: { persist-credentials: false }
      - uses: jdx/mise-action@<pinned-sha> # v4.2.4
      - uses: google-github-actions/auth@<pinned-sha> # v3
        with:
          workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
      - name: Release group
        env:
          GROUP_DIR: ${{ fromJSON(needs.resolve.outputs.group).dir }}
          BATCH_GROUP_STAGE: prod
        run: mise exec -- scripts/deploy-batch-group.sh "$GROUP_DIR"
```

`scripts/resolve-release-group.sh` splits the tag at the first `/`, matches the prefix against every
`group.yaml` `id`, and fails when the prefix is unknown or matches more than one group. It never
falls back to "all groups", because a production release with an ambiguous scope must not proceed.

All action references must stay pinned by commit SHA, as the existing `.github/workflows/deploy.yml`
already does. Workflow inputs must reach `run:` blocks through `env:` rather than direct expression
interpolation, to keep untrusted input out of the generated shell script.

### Change Detection Rules

`scripts/detect-changed-batch-groups.sh`, used by the push workflow only:

1. Diff `"$BASE_SHA"...HEAD` for changed paths.
2. Resolve each changed path to its nearest ancestor `group.yaml`.
3. Expand to all groups when a change touches `_shared/`, `scripts/`, workflow files, or any path
   outside every group. A shared change is a fleet change; treating it as scoped is how a broken
   subflow reaches production.
4. Fall back to all groups when `BASE_SHA` is the all-zero SHA or is unreachable, so a first push or
   a force-push does not silently deploy nothing.
5. Emit `matrix=<JSON array of manifests>` and `any=true|false`.

### Workflow Details That Matter

Each mechanism in these workflows exists to enforce a specific git-level rule; see
`## GitHub Enforcement Mapping` for the full binding. The one repository-specific note: the current
`.github/workflows/deploy.yml` uses a single repository-global concurrency group
(`kestra-playground-deploy`), which would queue every category behind every other. Replacing it with
per-group-per-stage keys is what turns nominal parallelism into actual team independence.

## Deployment Guardrails

These are runtime and deploy-path controls, distinct from the repository-level enforcement above.

| Risk | Control |
|------|---------|
| A group's flow declares a namespace belonging to another group | CI lint: every YAML under `<group>/flows/` must declare a `namespace` equal to, or a child of, the `group.yaml` namespace. This is the cheapest and most important check. |
| A deleted flow lingers in Kestra | Namespace-scoped deploy with deletion left at its default, so the directory is the source of truth. |
| A deploy job reaches another namespace | The deploy script takes only `GROUP_DIR` and derives everything from `group.yaml`. |
| Credential blast radius | One GCP service account and Workload Identity binding per category; Kestra Basic Auth or API tokens scoped per GitHub Environment. |

`playground.ec.shared` is a published interface, not a common dumping ground. Because a change there
fans out to every category, it requires review from all owning teams and must stay backward
compatible for at least one release cycle.

## Pull Request CI

The same `detect` job drives pull-request checks. Lint, type-check, and tests run only for changed
groups, for example `uv run pytest batch-groups/ec/food/tests`. A repository-wide static gate always
runs regardless of which group changed: `ruff check`, `ruff format --check`, `ty check`,
`shellcheck`, the namespace-prefix lint, and flow validation through the Kestra
`/api/v1/{tenant}/flows/validate` endpoint. This keeps per-team feedback fast without letting a
category skip shared correctness checks.

## Operations Runbook

The developer-facing summary of the whole design. Placed here rather than in
`design-docs/specs/command.md` so the procedure stays adjacent to the rules that justify it; move it
there if it becomes the primary reference for the teams.

```text
feature branch ──PR──> main ──auto──> staging
                        │
                        └──release PR merge──> tag ──> production (approval)
```

Three invariants: branch only from `main`, merging to `main` deploys staging automatically, and
production happens by merging a release pull request rather than by running a deploy.

### Normal Change

```bash
git switch main && git pull
git switch -c food/add-seasonal-report

# edit batch-groups/ec/food/ ...
git commit -m "feat(ec-food): add seasonal sales report"
git push -u origin food/add-seasonal-report
gh pr create
```

Pull-request CI runs that group's tests plus the repository-wide static gate. `CODEOWNERS` requests
review from the owning team. The Conventional Commit prefix determines the version bump: `feat:`
minor, `fix:` patch, `feat!:` major. After merge, staging deploys that group automatically and no
other category is touched.

### Production Release

`release-please` keeps one release pull request open per category, for example
`chore(ec-food): release 2026.08.20`. Merging it creates the tag `ec-food/v2026.08.20`, which fires
the production workflow and waits for Environment approval. No tag is typed by hand and no category
is chosen from a dropdown.

### Production Incident

Work the list in order and stop at the first applicable path.

```bash
# a. Roll back: re-release the previous tag (fastest, no new code)
gh workflow run release-batch-group.yml -f group=ec-food -f ref=ec-food/v2026.08.19

# b. Fix forward: the normal change flow above, then merge the release pull request.
#    Usually available, because other categories' merges to main do not block this group.

# c. Release branch: only when main holds unreleasable work for THIS group.
#    Fix on main first, through the normal flow, then:
git switch -c release/ec-food/2026.08 ec-food/v2026.08.19
git cherry-pick <sha-of-the-fix-on-main>
git tag ec-food/v2026.08.19-1
git push origin release/ec-food/2026.08 ec-food/v2026.08.19-1
```

The ordering in (c) is the step most often got wrong: the fix originates on `main` and is
cherry-picked into the release branch, never the reverse.

### Prohibited

- Creating a long-lived per-category branch such as `food/main`.
- Fixing directly on a `release/*` branch.
- Hand-cutting a production tag.
- Changing another category's directory without its owners' review.

## Deltas From The Current Repository

| # | Current state | Required change |
|---|---------------|-----------------|
| 1 | `scripts/deploy-batch-group.sh` takes a hardcoded `ec` / `affiliate` enum | Take a group directory and read `group.yaml` |
| 2 | `scripts/register-flows.sh` POSTs each flow file | Official `kestra-io/validate-action` and `kestra-io/deploy-action`, one namespace per call, deletion left at its default |
| 3 | Global `concurrency: kestra-playground-deploy` | Per-group-per-stage `deploy-<group id>-<stage>` |
| 4 | One runtime image contains `batch-groups/ec/batches` | Per-category Namespace Files or per-category images |
| 5 | No per-group metadata or ownership enforcement | Add `group.yaml`, `scripts/detect-changed-batch-groups.sh`, namespace-prefix lint, `CODEOWNERS`, per-category GitHub Environments |
| 6 | One `workflow_dispatch` release path with an environment dropdown | Push-triggered staging by changed paths; tag-triggered production through `<group-id>/v*` plus `scripts/resolve-release-group.sh` |
| 7 | No repository-level enforcement of the git strategy | Add per-directory `CODEOWNERS`, branch protection with required checks on `main`, tag rulesets per `<group-id>/v*`, and the staged-content gate on release-input hashes |

Items 2 and the namespace-prefix lint are the highest-leverage pair. Together they make a food deploy
provably incapable of affecting electronics, which is the property every other item assumes.

## References

See `design-docs/references/README.md`.

See also `design-docs/specs/design-monorepo-release-methodology-survey.md` for the industry survey
that validated this design and produced the hotfix-direction, Kestra-tooling, release-automation, and
deploy/enable corrections recorded above.
