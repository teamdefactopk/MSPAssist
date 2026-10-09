# Roles and permissions

All rules below are enforced by the API (`app/Policies`, `Ticket::scopeVisibleTo`,
controller checks). The Flutter app only *mirrors* them using the `abilities`
returned by `GET /me`, to avoid showing actions that would be rejected.

## Roles

| Role | Belongs to | Summary |
| --- | --- | --- |
| CyberCraft Administrator (`admin`) | CyberCraft | Everything, including inviting administrators, deleting clients and reading the audit log |
| Support Manager (`support_manager`) | CyberCraft | Runs the queue: all clients, assign/reassign, all ticket actions, SLA/category settings, invite technicians and client users |
| Technician (`technician`) | CyberCraft | Sees all tickets; works only on tickets assigned to them; may self-assign unassigned tickets; records equipment |
| Client Administrator (`client_admin`) | One organization | All sites of their organization; manages its departments, contacts, equipment and client users; client reports |
| Client User (`client_user`) | One organization | Only their assigned sites, plus tickets they raised |

## Visibility boundaries

| Data | Staff | Client admin | Client user |
| --- | --- | --- | --- |
| Organizations | all | own | own |
| Sites | all | all of own org | assigned sites |
| Tickets | all | own org | assigned sites + own requests |
| Equipment | all | own org | assigned sites |
| Departments / contacts | all | own org | own org (read) |
| Internal notes, internal attachments, SLA events | ✔ | ✘ | ✘ |
| Users | all | own org | ✘ |

Anything outside the boundary responds **404** (not 403), including ticket
messages, polling, history, attachment downloads and work-log confirmation.

## Actions

| Action | Admin | Manager | Technician | Client admin | Client user |
| --- | --- | --- | --- | --- | --- |
| Create ticket | any client | any client | any client | own org, any site | own assigned sites |
| Assign / reassign | ✔ | ✔ | self only, unassigned tickets | ✘ | ✘ |
| Change status / priority / edit | ✔ | ✔ | assigned tickets | ✘ | ✘ |
| Resolve (requires notes) | ✔ | ✔ | assigned tickets | ✘ | ✘ |
| Close a resolved ticket | ✔ | ✔ | assigned | ✔ (own org) | own requests |
| Reopen | ✔ | ✔ | assigned | ✔ (closed ≤ 14 days) | own requests (≤ 14 days) |
| Public message | ✔ | ✔ | ✔ | ✔ | ✔ |
| Internal note | ✔ | ✔ | ✔ | ✘ | ✘ |
| Log work / photos | ✔ | ✔ | assigned tickets | ✘ | ✘ |
| Confirm work | ✘ | ✘ | ✘ | ✔ | ✔ (visible tickets) |
| Create/edit clients & sites | ✔ | ✔ | ✘ | ✘ | ✘ |
| Departments & contacts | ✔ | ✔ | ✘ | own org | ✘ |
| Equipment | ✔ | ✔ | ✔ | own org | ✘ |
| Invite users | any role | technician + client roles | ✘ | client roles, own org | ✘ |
| Edit users / deactivate | all | all except admins | ✘ | own org | ✘ |
| Reports | all | all | all types; technician activity limited to self | ticket history, SLA, monthly (own org) | ✘ |
| SLA policies, categories | ✔ | ✔ | read | ✘ | ✘ |
| Audit log | ✔ | ✘ | ✘ | ✘ | ✘ |

Other safeguards: users cannot change their own role or deactivate
themselves; staff and client roles cannot be swapped on an existing account;
deactivation and password resets revoke API tokens; every login (success and
failure), invitation, user change, ticket change, upload and report export is
written to `audit_logs`.
