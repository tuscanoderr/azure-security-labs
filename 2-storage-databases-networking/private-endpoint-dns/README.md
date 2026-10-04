# Lab: Private Endpoint & Private DNS vs Service Endpoint (Private PaaS Connectivity)

> Reach a PaaS resource (blob storage) privately in two ways: a **service endpoint** (the subnet
> is trusted over the Azure backbone, but the resource keeps its public IP) and a **private
> endpoint** (the resource gets a **private IP inside the VNet**, resolved by **private DNS**).
> Then **disable public network access** so the account is reachable *only* through the private
> endpoint. Completes the "public access disabled" ending of the Storage and SQL labs.

**Domain:** SC-500 (Secure storage, databases, and networking)
**Services:** Azure Private Link / Private Endpoint, Private DNS, VNet service endpoints, Azure Storage, Azure CLI + Portal, Terraform. Private endpoint ~$0.01/hr; service endpoint / VNet / private DNS are free. **No VM.**
**Status:** Completed. Service endpoint and private endpoint are both configured, the private DNS A record resolves the storage FQDN to the private IP, and public network access is disabled.

---

## Objective

Demonstrate the two ways to keep PaaS traffic off the public internet, and the distinction
SC-500 tests between them, ending in a storage account that is reachable **only** privately.
The centrepiece is DNS: proving that the storage FQDN resolves to a **private IP inside the
VNet** rather than the public endpoint.

## The problem (insecure default)

PaaS resources (storage, SQL, Key Vault) are created with **public endpoints reachable from
anywhere on the internet**, protected only by keys or identity. Even with authentication fully
locked down (as in the Storage and SQL labs), the data plane still sits on a public IP exposed
to the internet's attack surface. Private networking removes that exposure: the resource is
reached over the Azure backbone or a private IP, and the public endpoint can be switched off
entirely.

## Lab environment

| Element | Value | Part in this lab |
|---|---|---|
| Storage account | `stpelab11230`, RG `lab-az-pe`, East US, StandardV2 / LRS | The PaaS resource secured (stand-in for any PaaS) |
| VNet / subnet | `vnet-pe-lab` (10.20.0.0/16) / `snet-workload` (10.20.1.0/24) | Where the workload lives; hosts the endpoints |
| Service endpoint | `Microsoft.Storage` on `snet-workload` | Approach 1: trust the subnet |
| Private endpoint | `pe-blob` → blob, private IP **10.20.1.4** | Approach 2: the resource gets a VNet IP |
| Private DNS zone | `privatelink.blob.core.windows.net` (+ VNet link) | Resolves the FQDN to the private IP |

## What I built

Two private-access approaches on one storage account, ending with the public endpoint off.

| Step | Result |
|---|---|
| Service endpoint | `Microsoft.Storage` on `snet-workload` + storage firewall allowing that subnet; `defaultAction = Deny` → "Enabled from selected networks" |
| Private endpoint | `pe-blob` (group-id `blob`), **Approved**, private IP **10.20.1.4** in `snet-workload` |
| Private DNS | zone `privatelink.blob.core.windows.net`, VNet-linked; DNS zone group auto-created A record **`stpelab11230 → 10.20.1.4`** |
| Finale | `public-network-access = Disabled`, so the account is reachable only via the private endpoint (private endpoint connections: 1) |

### Design decisions (the "why")

- **Both approaches, to teach the distinction.** Service endpoint and private endpoint both keep
  traffic off the public internet, but a service endpoint only **trusts a subnet** (the resource
  keeps its public IP), while a private endpoint gives the resource a **private IP in the VNet**.
  Building both makes the exam contrast concrete rather than theoretical.
- **Private endpoint is the stronger default.** Only the private-endpoint path lets you disable
  the public endpoint entirely and reach the resource from on-premises (over VPN/ExpressRoute).
  The lab ends there.
- **DNS is the crux, and it is provable without a VM.** A private endpoint alone doesn't change
  name resolution; the storage FQDN still resolves to the public IP until a **private DNS zone**
  with the right A record overrides it. The DNS zone group **auto-creates** that record. Listing
  the record (`stpelab11230 → 10.20.1.4`) is exactly what an in-VNet `nslookup` would return, so
  the resolution is proven deterministically with no VM to spin up.
- **`registration-enabled false` on the VNet link.** The zone is for *resolution* of the private
  endpoint, not for auto-registering VM hostnames, so registration stays off.
- **Dedicated resource group.** `lab-az-pe` keeps this lab isolated and makes teardown a single
  command; it's also outside the Domain 1 "East US only" policy scope.
- **Completes the Storage and SQL labs.** Both ended by disabling public access and pointed to
  "reach it privately via a private endpoint." This lab is that private endpoint: the missing
  half of that story.

## Steps & output

*Azure CLI (Cloud Shell). Outputs summarised; only private IPs and resource names appear.*

**1. Storage + VNet**

```bash
az group create -n lab-az-pe -l eastus
az storage account create -n stpelab11230 -g lab-az-pe -l eastus \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false
az network vnet create -g lab-az-pe -n vnet-pe-lab \
  --address-prefix 10.20.0.0/16 --subnet-name snet-workload --subnet-prefix 10.20.1.0/24
```

**2. Approach 1: service endpoint + storage firewall**

```bash
az network vnet subnet update -g lab-az-pe --vnet-name vnet-pe-lab -n snet-workload \
  --service-endpoints Microsoft.Storage
az storage account network-rule add -g lab-az-pe --account-name stpelab11230 \
  --vnet-name vnet-pe-lab --subnet snet-workload
az storage account update -g lab-az-pe -n stpelab11230 --default-action Deny --bypass AzureServices
```

Result (Evidence `01`): the subnet's service-endpoint status is **Enabled**, and the storage
firewall now reads **"Enabled from selected networks."** The account is restricted to the
trusted subnet, but it still has a public IP/FQDN. That's the service-endpoint limitation the
private endpoint fixes.

**3. Approach 2: private endpoint for blob**

```bash
STORAGE_ID=$(az storage account show -g lab-az-pe -n stpelab11230 --query id -o tsv)
az network private-endpoint create -g lab-az-pe -n pe-blob \
  --vnet-name vnet-pe-lab --subnet snet-workload \
  --private-connection-resource-id $STORAGE_ID --group-id blob \
  --connection-name blob-connection
```

Result (Evidence `02`): the endpoint is **Approved (Auto-Approved)** with a NIC holding private
IP **10.20.1.4** from `snet-workload`. The resource now has an address *inside the VNet*, which
is the fundamental difference from a service endpoint.

**4. Private DNS: resolve the FQDN to the private IP**

```bash
az network private-dns zone create -g lab-az-pe -n privatelink.blob.core.windows.net
az network private-dns link vnet create -g lab-az-pe \
  -z privatelink.blob.core.windows.net -n link-pe-vnet \
  --virtual-network vnet-pe-lab --registration-enabled false
az network private-endpoint dns-zone-group create -g lab-az-pe \
  --endpoint-name pe-blob -n default \
  --private-dns-zone privatelink.blob.core.windows.net --zone-name blob

az network private-dns record-set a list -g lab-az-pe \
  -z privatelink.blob.core.windows.net \
  --query "[].{Record:name, IP:aRecords[0].ipv4Address}" -o table
```

```text
Record        IP
------------  ---------
stpelab11230  10.20.1.4
```

Result (Evidence `03`): the DNS zone group auto-created the A record. The resolution chain is
now `stpelab11230.blob.core.windows.net` → **CNAME** → `stpelab11230.privatelink.blob.core.windows.net`
→ **A** → `10.20.1.4`. Any client in the VNet resolving the storage FQDN lands on the private IP.

**5. Finale: disable public network access**

```bash
az storage account update -g lab-az-pe -n stpelab11230 --public-network-access Disabled
```

Result (Evidence `04`): storage properties show **Public network access: Disabled** and
**Private endpoint connections: 1**. The public path (including the service-endpoint route) is
severed; the account is reachable only through `pe-blob`. This is the fully-private end state
the Storage and SQL labs pointed to.

## Built as code

The lab was first built with the Azure CLI and portal as documented above. The same end state is
now reproducible from [`terraform/main.tf`](terraform/main.tf) (azurerm 4.x), which passes
`terraform validate`. The evidence images below come from that original CLI build, not from a
Terraform apply.

Run it from the lab's `terraform` folder:

```
cd terraform
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

To look at the service endpoint path on its own, with the public endpoint still enabled, apply
again with the variable switched on:

```
terraform apply -var "public_network_access_enabled=true"
```

| Lab piece | Terraform resource |
|---|---|
| Resource group `lab-az-pe` | `azurerm_resource_group` |
| VNet `vnet-pe-lab` | `azurerm_virtual_network` |
| Subnet `snet-workload` with the `Microsoft.Storage` service endpoint | `azurerm_subnet` |
| Storage account, its firewall rule (`Deny`, `AzureServices` bypass, subnet allowed) and public network access setting | `azurerm_storage_account` (name suffix from `random_string`) |
| Private DNS zone `privatelink.blob.core.windows.net` | `azurerm_private_dns_zone` |
| VNet link `link-pe-vnet` (registration off) | `azurerm_private_dns_zone_virtual_network_link` |
| Private endpoint `pe-blob` and its DNS zone group `default` | `azurerm_private_endpoint` |

Differences from the CLI build:

- The storage account name gets a random five character suffix (`stpelab<suffix>`) because
  storage account names are global. `stpelab11230` in the evidence is the name from the
  original build.
- Public network access is a variable (`public_network_access_enabled`) that defaults to
  `false`. A plain apply therefore lands directly on the lab's final, fully private state. Set
  it to `true` to look at the service endpoint path on its own.
- The service endpoint, the storage firewall rule, the private endpoint, the zone and the VNet
  link are all declared together. As in the CLI build, the DNS zone group writes the A record.
- The outputs show the private endpoint IP and the A record set, which is the same proof as
  Evidence `03`.

State, plans and logs stay on the local machine and are excluded by
[`terraform/.gitignore`](terraform/.gitignore).

## Evidence

*No sensitive identifiers appear in these captures. The subscription ID is blurred where shown; otherwise only private IPs and resource names appear.*

**Approach 1 (service endpoint): subnet `snet-workload` trusted (Endpoint Status Enabled)**
![Storage networking virtual networks list showing vnet-pe-lab / snet-workload with Microsoft.Storage service endpoint status Enabled](images/01-service-endpoint.png)

**Approach 2 (private endpoint `pe-blob`): Approved connection to the blob sub-resource**
![Private endpoint pe-blob overview showing connection status Approved, private link resource stpelab11230, target sub-resource blob](images/02-private-endpoint.png)

**Private DNS: the storage FQDN resolves to the private IP (headline)**
![Private DNS zone privatelink.blob.core.windows.net recordsets showing an A record stpelab11230 pointing to 10.20.1.4](images/03-private-dns-arecord.png)

**Finale: public network access disabled, so the account is reachable only via the private endpoint**
![Storage account properties showing Public network access Disabled and Private endpoint connections 1](images/04-storage-public-disabled.png)

## Configuration & identifiers (redacted)

Portal + CLI driven, so the evidence is the screenshots and CLI output above. The key artifact
is the private DNS A record (`stpelab11230 → 10.20.1.4`), because it *is* the proof of private
resolution. The full build definition for reproducing the lab is in
[`terraform/main.tf`](terraform/main.tf). Redaction follows the repo convention: subscription ID
is placeholdered in captures; storage / VNet / endpoint / zone names and private IPs (10.20.x.x,
not routable) are kept.

## SC-500 concepts demonstrated

- **Service endpoint vs private endpoint**, the core exam distinction:

  | | Service endpoint | Private endpoint |
  |---|---|---|
  | What | Extends **subnet identity** to the service over the backbone | Gives the service a **private IP in the VNet** |
  | Resource public IP | Retained (firewall-restricted) | Can be **disabled** |
  | DNS | Public FQDN / public IP | **Private DNS** → private IP |
  | Scope | The **subnet** | The **resource**, VNet-wide + on-prem |
  | On-prem access | No | Yes (VPN / ExpressRoute) |

- **Azure Private Link / Private Endpoint:** a NIC with a private IP that projects a PaaS
  resource into your VNet, plus connection approval states (auto-approved when you own the
  resource).
- **Private DNS zones:** `privatelink.blob.core.windows.net`, VNet links, and the DNS zone
  group that auto-manages the A record; the **CNAME → privatelink → private IP** resolution chain.
- **Storage firewall:** `defaultAction = Deny`, virtual-network rules, and the `AzureServices`
  bypass.
- **Public network access = Disabled:** the fully-private end state, and how it composes with
  the identity controls from the Storage and SQL labs (defence in depth: private network *and*
  identity-based auth).

## How I'd extend this

- **Live in-VNet resolution.** From a VM in `snet-workload`, `nslookup stpelab11230.blob.core.windows.net`
  returns `10.20.1.4` (the A record proves this deterministically here; a VM would show it live).
- **On-premises resolution.** An Azure DNS Private Resolver + conditional forwarder so on-prem
  clients over VPN/ExpressRoute also resolve to the private IP.
- **Private endpoints for the other services.** Add `pe-sql`, `pe-vault` and disable their
  public access too, extending this pattern to the SQL and Key Vault labs.
- **Combine with network segmentation.** Place these endpoints in a subnet governed by the
  NSG/ASG rules from the segmentation lab, so they are private *and* segmented.
- **Azure Policy enforcement.** Deny creation of PaaS resources with public network access
  enabled, org-wide (cross-ref the Domain 1 Policy lab).
- **AI extension.** AI training data in blob, model endpoints, and the vector store are all
  reached over private endpoints from the AI workload's subnet, with no PaaS data plane on the
  public internet. (Ties to Domain 3.)

## Cleanup

For the Terraform build, run this from the lab's `terraform` folder (running it from the repo
root does nothing):

```
terraform destroy
```

For the CLI build:

```bash
az group delete --name lab-az-pe --yes --no-wait
```

Removes the storage account, VNet, private endpoint, private DNS zone, and links in one step.
The private endpoint (the only metered resource, ~$0.01/hr) is deleted; everything else was
free. Other resource groups are untouched.
