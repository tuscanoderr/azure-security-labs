# Lab: GenAI Incident Response Playbooks as Sentinel Automation

> Turned the playbooks from my paper on incident response for generative AI systems into working
> SOAR on Azure. Defender for AI and Sentinel detect attacks on an Azure OpenAI deployment, and
> Logic Apps playbooks carry out the response. Every Logic Apps action is named after the playbook
> step it implements (D1, D2, C2 and so on), so a reviewer can trace each action back to the framework.

**Domain:** 4 (Security Posture and Monitoring, SC-500)
**Services:** Azure OpenAI, Prompt Shields, Microsoft Defender for Cloud (Defender for AI services), Microsoft Sentinel, Microsoft Defender XDR, Azure Logic Apps, Microsoft Graph, Terraform
**Status:** Complete (A1 and A6)

---

## Background

The framework comes from my paper:

> D. Tuscano, "A Practical Incident-Response Framework for Generative AI Systems,"
> *Journal of Cybersecurity and Privacy*, vol. 6, no. 1, p. 20, 2026. doi:10.3390/jcp6010020

The paper defines six incident archetypes for generative AI systems and gives a playbook for each,
with detection (D), containment (C) and recovery (R) steps mapped to NIST SP 800-61r3,
NIST AI 600-1, MITRE ATLAS and the OWASP Top 10 for LLM Applications. This lab implements the
archetypes that a cloud platform can detect and contain automatically. Each one has its own folder.

| Archetype | Folder | Detection in Azure | Status |
|---|---|---|---|
| A1 Direct prompt injection and jailbreak | [`a1-jailbreak`](a1-jailbreak) | Defender for AI Prompt Shields alerts | Complete |
| A6 Denial of service and cost drain | [`a6-cost-drain`](a6-cost-drain) | Sentinel scheduled rule on Azure OpenAI token metrics | Complete |
| A2 Indirect prompt injection, A3 data leakage, A4 poisoning, A5 plugin abuse | Not built | Need application context (RAG sources, plugins, training data) that a single model endpoint does not have | Out of scope |

## Shared environment

Both archetypes run on one deployment so they share the detection and response plumbing.

| Item | Value |
|---|---|
| Resource group | `lab-genai-irf` (East US) |
| Azure OpenAI | `aoai-genai-irf-jz8x7`, model `gpt-5-mini` (2025-08-07), GlobalStandard |
| Deployments | `chat` with the default content filter (Prompt Shields blocks jailbreaks); `chat-annotate` with a custom filter that detects jailbreaks without blocking |
| Defender plan | Defender for AI services (`AI`, Standard) with user prompt evidence on |
| Sentinel workspace | `law-genai-irf-jz8x7`, connected to the Defender portal |
| Playbooks | `pb-genai-irf-a1-jailbreak`, `pb-genai-irf-a6-cost-drain` (Logic Apps Consumption, system assigned managed identities) |
| Test identity | `lab-genai-user`, an unlicensed Entra ID user standing in for an application end user |

`gpt-4o-mini` was the first choice, but new deployments of it were refused because the model is
being retired, so the lab uses `gpt-5-mini`.

## Built as code

Everything is defined in [`terraform`](terraform): the Azure OpenAI account, both deployments and
the content filter, the Defender plan, the Sentinel workspace and rules, both playbooks (ARM
templates in [`terraform/playbooks`](terraform/playbooks)), the role assignments, the Graph
application permissions and the automation rules. The test scripts are in
[`terraform/scripts`](terraform/scripts).

```
cd terraform
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
terraform init
terraform plan -out lab.tfplan
terraform apply lab.tfplan
```

Prerequisites: `Microsoft.CognitiveServices`, `Microsoft.OperationalInsights`,
`Microsoft.SecurityInsights`, `Microsoft.Security` and `Microsoft.Logic` registered (the provider
is set not to register them), and an account that can grant Graph application permissions.
State and plan files stay local and are excluded by [`terraform/.gitignore`](terraform/.gitignore).

| Lab piece | Terraform resource |
|---|---|
| Resource group, workspace, name suffix | `azurerm_resource_group`, `azurerm_log_analytics_workspace`, `random_string` |
| Azure OpenAI account, deployments, content filter | `azurerm_cognitive_account`, `azurerm_cognitive_deployment`, `azurerm_cognitive_account_rai_policy` |
| Diagnostics to the workspace | `azurerm_monitor_diagnostic_setting` |
| Defender for AI services plan | `azurerm_security_center_subscription_pricing` |
| Sentinel and the Defender for Cloud connector | `azurerm_sentinel_log_analytics_workspace_onboarding`, `azurerm_sentinel_data_connector_azure_security_center` |
| Detection rules | `azurerm_sentinel_alert_rule_ms_security_incident` (A1), `azurerm_sentinel_alert_rule_scheduled` (A6) |
| Playbooks | `azurerm_resource_group_template_deployment` |
| Playbook permissions | `azurerm_role_assignment`, `azuread_app_role_assignment` |
| Automation rules | `azurerm_sentinel_automation_rule` |
| Test user | `azuread_user`, `random_password` |

## Cleanup

From the `terraform` folder:

```
terraform destroy
```

This removes the resource group, the test user and the Graph permissions, and sets the Defender for
AI services plan back to Free. The provider purges the soft deleted Azure OpenAI account so the name
can be reused. Costs while running: Azure OpenAI tokens (a few cents for the tests), Logic Apps
Consumption runs (fractions of a cent) and Sentinel ingestion (small). The Defender for AI plan
started on its free trial.
