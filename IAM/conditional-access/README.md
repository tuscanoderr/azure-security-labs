# Lab: Require MFA for Administrators (Conditional Access)

> Enforce multi-factor authentication on a privileged directory role using a Microsoft
> Entra Conditional Access policy, deployed safely with report-only mode, a break-glass
> exclusion, and What-If validation.

**Domain:** SC-500 — Manage identity, access, and governance
**Services:** Microsoft Entra ID (Conditional Access). Policy requires Entra ID P1; tenant is on P2.
**Status:** Built and validated in report-only. Enablement deferred (see note under Safe rollout).

---

## Objective

Demonstrate how Conditional Access replaces "a correct password is enough" with a
contextual access decision — specifically, requiring MFA for accounts holding a
privileged directory role, which are the highest-value targets in a tenant.

## The problem (insecure default)

By default, an administrator can sign in with only a username and password. If those
credentials are phished or reused, an attacker gains privileged access with no second
barrier. Privileged roles need a stronger control than standard users.

## Lab environment

| Account | Role | Part in this lab |
|---|---|---|
| PDFMerge Administrator | Global Administrator | Break-glass / excluded from policy |
| Derrisa Tuscano | User Administrator | Target admin — policy applies |
| Groot | Reader | Non-admin control — policy should not apply |
| Rocket | Reader | Non-admin control — policy should not apply |

## What I built

A Conditional Access policy that requires MFA whenever a user holding the User
Administrator role accesses any cloud resource, while exempting the break-glass account.

| Setting | Value |
|---|---|
| Policy name | `CA001 - Require MFA for admins` |
| Include | Directory role: **User Administrator** |
| Exclude | Directory role: **Global Administrator** (break-glass) |
| Target resources | All cloud apps / all resources |
| Conditions | None (`clientAppTypes` = all, the default) |
| Grant control | Grant access — **Require multifactor authentication** |
| Session controls | None |
| State | Report-only |

### Design decisions (the "why")

- **Targeted a role, not a user.** Scoping to the User Administrator role means the
  policy keeps protecting whoever holds that role as membership changes — this is why
  Derrisa was assigned the role first rather than being named directly in the policy.
- **Excluded a break-glass identity.** A misconfigured policy can lock every admin out
  of the tenant, so an exempt account is the safety valve. Here the sole Global
  Administrator (PDFMerge Administrator) is the break-glass account, excluded via the
  Global Administrator role.
- **Grant, not block.** The goal is to strengthen access with a second factor, not
  deny it.
- **Least privilege in the setup.** Derrisa was demoted from Global Administrator to
  User Administrator so the tenant keeps a single standing Global Admin — reflecting
  Microsoft's guidance to minimise permanent Global Admins.

## Safe rollout

1. Assigned roles first (User Administrator to the target; kept one Global Admin).
2. Created the policy in **report-only** mode — evaluated in sign-in logs but not enforced.
3. **Verified the saved policy against its JSON export** (see gotcha below).
4. Used the **What-If** tool to simulate the target admin and a non-admin, confirming
   the policy applies to the admin and not to standard users.

**Enablement note:** turning this policy **On** requires **disabling security defaults**
first — Conditional Access and security defaults are mutually exclusive. This lab keeps
the policy in report-only to preserve a safe, non-enforcing demonstration; enabling is a
deliberate follow-up once break-glass access is confirmed.

## Gotcha (operational note)

After the first save, the policy summary reported unintended settings — risk levels,
device platforms, and an empty exclusion list — that did **not** match what the editor
showed. Re-editing and re-saving, then confirming against the **Download JSON** export,
resolved it. Lesson: treat the exported policy definition as the source of truth and
verify the saved state rather than trusting the editor blades alone.

## Evidence

*(Screenshots redacted — domain names and object IDs removed.)*

- `images/01-policy-report-only.png` — policy summary: state = report-only, 1 role
  included, 1 role excluded, require MFA.
- `images/02-whatif-admin.png` — What-If for the User Administrator: CA001 applies,
  control = require MFA.
- `images/03-whatif-nonadmin.png` — What-If for a Reader account: no policies apply,        proving role scoping..

## Policy definition (redacted)

Exported via Microsoft Graph: `GET /identity/conditionalAccess/policies`.
See [`policy.json`](./policy.json). The policy object ID is placeholdered; the role
GUIDs are Microsoft's public, well-known role template IDs (identical in every tenant)
and are left intact:

| Field | GUID | Meaning |
|---|---|---|
| `includeRoles` | `fe930be7-5e62-47db-91af-98c3a49a38b1` | User Administrator |
| `excludeRoles` | `62e90394-69f5-4237-9190-012177145e10` | Global Administrator (break-glass) |

Key fields: `state = enabledForReportingButNotEnforced` (report-only),
`builtInControls = ["mfa"]`, and empty `userRiskLevels` / `signInRiskLevels` / `platforms`
(a clean policy with no extra conditions).

## SC-500 concepts demonstrated

- **Assignments vs access controls** — the policy's two halves: who/what it applies to,
  and what it enforces.
- **Grant vs session controls** — this uses a grant control (require MFA).
- **Report-only vs On vs Off** — the three policy states, and why report-only comes first.
- **Role-based targeting** — scoping to a directory role instead of named users.
- **Break-glass exclusion** — avoiding tenant lockout.
- **Security defaults vs Conditional Access** — mutually exclusive; CA is the granular,
  licensed replacement.
- **Licensing** — Conditional Access requires Entra ID P1; risk-based conditions require P2.

## How I'd extend this

- Add a companion policy to **block legacy authentication** (legacy protocols can't do
  MFA, so they bypass it).
- Add a **sign-in risk** condition (P2 / Identity Protection) to step up MFA only on
  risky sign-ins.
- Require a **compliant or Hybrid-joined device** for admin access.
- **In production**, exclude a *dedicated* cloud-only emergency-access account (or a small
  break-glass group) rather than the entire Global Administrator role — excluding the whole
  role exempts every global admin, which is too broad in a multi-GA tenant.
- **AI extension:** apply Conditional Access to **Entra Agent ID** identities to govern
  AI agents the same way (preview) — see related lab.

## Cleanup

Conditional Access policies incur no cost and can be left in report-only or deleted.
No billable resources were created by this lab.
