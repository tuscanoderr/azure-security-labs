# Lab: Custom Least-Privilege RBAC Role (Azure)

> Design and assign a **custom Azure RBAC role** that grants only the specific actions a
> job needs — nothing more — instead of a broad built-in role. Least-privilege on the
> resource plane, defined as code and scoped to a single resource group.

**Domain:** SC-500 — Manage identity, access, and governance
**Services:** Azure RBAC (role definitions and assignments), Azure CLI
**Status:** Completed — custom role created, assigned, and verified via CLI.

---

## Objective

Show that least privilege on the Azure plane often means going beyond built-in roles.
Built-in roles like Contributor are broad; a **custom role** grants exactly the actions
required for a task and can be restricted to where it may be used via `AssignableScopes`.

## The problem (insecure default)

Granting a built-in role such as **Contributor** just to let someone start and stop VMs
massively over-provisions them — Contributor can create, modify, and delete almost any
resource in scope. Least privilege means granting only the specific actions needed; built-in
roles rarely match a real job function exactly.

## What I built

A custom role, **"Lab VM Operator,"** granting only VM power operations plus read access,
scoped to a single resource group, then assigned to a standard user (Rocket).

| Element | Value |
|---|---|
| Role name | `Lab VM Operator` (roleType: CustomRole) |
| Allowed actions | VM start / restart / deallocate; VM read; resource group read |
| NotActions / DataActions | none |
| Assignable scope | Resource group `lab-az-pim` only |
| Assigned to | Rocket (standard user) |
| Method | Azure CLI |

Role definition file: [`vmoperator.json`](./vmoperator.json) (subscription ID placeholdered).

### Design decisions (the "why")

- **Custom over built-in.** No built-in role matches "operate VMs, change nothing else," so
  a custom role expresses true least privilege.
- **Only power + read actions.** The role cannot create, delete, or reconfigure resources —
  the minimum for a VM operator.
- **`AssignableScopes` locked to one resource group.** The role can only ever be assigned
  within `lab-az-pim`, limiting where this permission set can spread.
- **Defined as code (JSON).** Reviewable, version-controlled, reproducible — IaC applied to
  authorization.

## Steps & output

**1. Create the custom role**

```bash
az role definition create --role-definition vmoperator.json
```

```json
{
  "roleName": "Lab VM Operator",
  "roleType": "CustomRole",
  "id": ".../roleDefinitions/<ROLE_DEFINITION_ID>",
  "assignableScopes": [
    "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/lab-az-pim"
  ],
  "permissions": [
    {
      "actions": [
        "Microsoft.Compute/virtualMachines/start/action",
        "Microsoft.Compute/virtualMachines/restart/action",
        "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Compute/virtualMachines/read",
        "Microsoft.Resources/subscriptions/resourceGroups/read"
      ],
      "notActions": [],
      "dataActions": [],
      "notDataActions": []
    }
  ]
}
```

**2. Assign the role to a standard user**

```bash
az role assignment create \
  --assignee <user>@<tenant>.onmicrosoft.com \
  --role "Lab VM Operator" \
  --scope /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/lab-az-pim
```

**3. Verify the assignment**

```bash
az role assignment list --resource-group lab-az-pim --output table
```

```
Principal      Role             Scope
-------------  ---------------  -------------------------------------------------
Rocket@...     Lab VM Operator  .../resourceGroups/lab-az-pim
```

## SC-500 concepts demonstrated

- **Custom vs built-in roles** — when and why to build a custom role for least privilege.
- **Role definition anatomy** — `Actions`, `NotActions`, `DataActions`, `NotDataActions`,
  and `AssignableScopes`.
- **AssignableScopes** — constraining *where* a role can be assigned, not just what it does.
- **Azure RBAC** as the resource-plane permission system (distinct from Entra directory
  roles).
- **Authorization as code** — defining and applying roles via JSON and the CLI.

## How I'd extend this

- Add **`NotActions`** to subtract specific operations from an otherwise-broad set.
- Explore **DataActions** for data-plane permissions (e.g. Storage blob read).
- Deliver the role via Bicep/Terraform for full IaC.
- Combine with PIM so even this custom role is granted just-in-time rather than standing.

## Cleanup

```bash
az role assignment delete --assignee <user> --role "Lab VM Operator" --scope <scope>
az role definition delete --name "Lab VM Operator"
```
Custom roles and assignments incur no cost; no billable resources were deployed.
