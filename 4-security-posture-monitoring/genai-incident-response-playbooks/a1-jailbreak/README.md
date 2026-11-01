# A1: Direct Prompt Injection and Jailbreak

> A user tells an HR chatbot it is now "Yendys", an assistant with no limits, and asks for its system
> prompt and every salary it knows. Prompt Shields blocks the prompt, Defender for AI raises
> alerts that name the user and source IP, and a Logic Apps playbook works through the paper's A1
> steps: acknowledge, collect evidence, set severity, contain the account.

**Archetype:** A1 in the GenAI-IRF framework ([overview](../README.md))
**Maps to:** OWASP LLM01 Prompt Injection, MITRE ATLAS AML.T0054 LLM Jailbreak, NIST AI 600-1 Information Security
**Status:** Complete

---

## Objective

Show that a jailbreak attempt against an Azure OpenAI deployment produces an incident with the
attacking user attached, and that the A1 playbook responds the way the paper describes. Containment
depends on whether the model's guardrail held: a blocked attempt revokes the user's sessions, while
an attempt that got through also disables the account.

## The problem (insecure default)

An application that calls Azure OpenAI with one API key looks like a single caller to the platform.
When someone jailbreaks it, the content filter may block the prompt, but nobody is told who sent it,
nothing is logged against a person, and the same user can keep trying. Without the end user's
identity on the request, the SOC has an alert about the application and no one to contain.

## How it works

| Step | Component | What happens |
|---|---|---|
| 1 | Test script | Sends a benign HR question, then the Yendys jailbreak to both deployments. Each request carries `user_security_context` with the end user's Entra object ID, the source IP `203.0.113.10` and the application name |
| 2 | Prompt Shields | Blocks the jailbreak on `chat`; on `chat-annotate` it only flags it |
| 3 | Defender for AI services | Raises *A Jailbreak attempt on your Azure AI model deployment was blocked by Prompt Shields* and *...was detected by Prompt Shields*, with the user, IP and prompt evidence |
| 4 | Defender XDR and Sentinel | Correlate both alerts into one incident with the user, the Azure OpenAI resource and the IP as entities |
| 5 | Playbook `pb-genai-irf-a1-jailbreak` | Runs the A1 steps below against the incident |

### Playbook steps mapped to the paper

| Logic Apps action | Paper step | What it does |
|---|---|---|
| `D1_Acknowledge_incident` | D1 Acknowledge and triage | Sets the incident to Active and tags it `GenAI-IRF-A1`, `D1-Acknowledged` |
| `D2_Get_accounts`, `D2_Record_evidence` | D2 Confirm incident and collect evidence | Reads the account entities (the end user from `UserSecurityContext`) and writes an evidence comment pointing at the prompt evidence and RequestResponse logs |
| `D8_Severity_decision_gate` | D8 Assign severity | Detected and not blocked means the guardrail was bypassed: High plus `Guardrail-Bypassed`. Blocked means Medium plus `Guardrail-Held` |
| `C2_Revoke_sessions` | C2 Execute initial containment | Calls Microsoft Graph `revokeSignInSessions` for every account on the incident |
| `C2_Account_vs_session_gate`, `C2_Disable_account` | C2, Account vs Session Termination decision | Sets `accountEnabled` to false only when the guardrail was bypassed |
| `C2_Record_containment` | C2 | Comments what was done and lists the steps that need a person |

The human owned steps go on the incident as tasks through the automation rule: D3 declare the
incident, D9 assess reporting obligations, C3 preserve volatile evidence, C4 approve an emergency
filter. A playbook should not declare an incident or decide on regulatory notification on its own.

### Design decisions (the "why")

- **Identity on every request.** `user_security_context` is what turns an application alert into a
  user alert. Without it the playbook would have nobody to contain.
- **Two deployments.** `chat` shows the normal case, where the filter blocks the prompt. `chat-annotate`
  stands in for a weaker guardrail and lets the lab produce a *detected* alert alongside the
  *blocked* one, which is what the D8 gate decides on.
- **Proportionate containment.** Revoking sessions forces the user to sign in again, which cuts off a
  hijacked session at little cost. Disabling the account interrupts a real person's work, so it is
  kept for the case where the attack succeeded.
- **Managed identity, least privilege.** The playbook identity holds *Microsoft Sentinel Responder*
  on the resource group and only the Graph application roles `User.EnableDisableAccount.All` and
  `User.RevokeSessions.All`, not `User.ReadWrite.All`.

## Steps & output

**1. Deploy.** `terraform apply` from the shared [`terraform`](../terraform) folder (see the
[overview](../README.md#built-as-code)).

**2. Send the jailbreak.** From the `terraform` folder:

```
.\scripts\test-a1-jailbreak.ps1
[chat] answered:
[chat] jailbreak annotation: {"detected":false,"filtered":false}
[chat] blocked: {"error":{"code":"content_filter","status":400,"innererror":{"code":"ResponsibleAIPolicyViolation",
  "content_filter_result":{"jailbreak":{"detected":true,"filtered":true}, ...}}}}
[chat-annotate] answered:
[chat-annotate] jailbreak annotation: {"detected":true,"filtered":false}
```

The benign question passes. The jailbreak is rejected by `chat` with HTTP 400 and flagged but
allowed by `chat-annotate`. The empty answers are expected: `gpt-5-mini` spends its small token
budget on reasoning, and only the filter results matter here.

**3. Alerts and incident.** Defender for AI raised both alerts at 23:39 IST on 1 November 2026,
and Defender XDR grouped them into one incident with `lab-genai-user`, `aoai-genai-irf-jz8x7` and
`203.0.113.10` as entities (screenshot 01). An earlier run on 29 October, about an hour after the
plan was enabled, produced no alerts; the plan needed time to start protecting the resource.

**4. Run the playbook.** The incident was created by Defender XDR's correlation, not by the
Sentinel rule in this lab, so the automation rule that matches on that rule did not fire (see
Lessons below). The playbook was started from the case with *Run playbook*, and the run request
was accepted (screenshot 03).

**5. Result.** The run succeeded (screenshot 04). Both alerts came from Prompt Shields blocking or
flagging the prompt, and the incident title does not contain *detected*, so the D8 gate took the
Medium branch: sessions revoked, account left enabled. The case now shows status Active, the tags
`D1-Acknowledged`, `D8-Severity-Medium`, `GenAI-IRF-A1` and `Guardrail-Held`, and the D2 and C2
comments (screenshot 02).

## Lessons

- **Defender XDR owns incident creation.** Once a Sentinel workspace is connected to the Defender
  portal, XDR correlates alerts into incidents and Microsoft security incident creation rules no
  longer apply. An automation rule should match on the alert itself (product *Microsoft Defender
  for Cloud*, alert title containing *Jailbreak*) rather than on an analytics rule ID.
- **The severity gate needs a better signal.** The gate reads the incident title, and XDR renamed
  the incident to *Privilege escalation incident involving one user*. Reading the alert titles or
  the `jailbreak.filtered` result would let the gate see that one of the two alerts was a bypass.
- **New plans take time.** Defender for AI did not alert in the first hour after it was enabled.
  Allow for that before treating a missing alert as a detection gap.

## Evidence

*The test user's UPN, SID and object ID in the D2 comment and the portal account name are masked.
`203.0.113.10` is a documentation address.*

| # | Shows |
|---|---|
| 01 | Defender XDR case: both Prompt Shields alerts with the user, Azure OpenAI resource and source IP |
| 02 | Case tags and the playbook's D2 evidence and C2 containment comments |
| 03 | Playbook started from the case and the run request accepted |
| 04 | Logic Apps run: D1, D2, D8 Medium branch, C2 sessions revoked, account gate not taken |

![Defender XDR case with jailbreak alerts](images/01-defender-case-graph.png)
![Case tags and playbook comments](images/02-incident-tags-comments.png)
![Run playbook on the case](images/03-run-playbook-manual.png)
![A1 Logic Apps run](images/04-logic-app-run.png)

## SC-500 concepts demonstrated

- **Prompt Shields.** The jailbreak classifier in Azure AI Content Safety, configured per deployment
  in the content filter to block or only annotate.
- **Defender for AI services threat protection.** Alerts on jailbreak attempts, enriched with the end
  user and source IP from `UserSecurityContext` and with prompt evidence when that setting is on.
- **Unified SecOps.** Sentinel connected to the Defender portal, where XDR correlates alerts into
  incidents and playbooks run from the case.
- **SOAR with Logic Apps.** A Sentinel incident trigger, a managed identity with Sentinel Responder
  and scoped Graph application permissions, and automation rules that add tasks and call playbooks.

## How I'd extend this

- Change the automation rule condition to the alert product and title so the playbook runs
  without a person.
- Feed the D8 gate from the alert evidence and test the High branch, where the account is disabled.
- Add the R steps: re-enable the account after review and record the outcome on the incident.
- Send the C2 summary to the IR lead in Teams.

## Cleanup

Covered by `terraform destroy` in the shared [`terraform`](../terraform) folder (see the
[overview](../README.md#cleanup)).
