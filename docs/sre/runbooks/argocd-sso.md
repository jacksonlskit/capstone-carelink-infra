# Runbook: Argo CD sign-in with GitHub

Design and reasons: [ADR 0010](../../adr/0010-argocd-github-sso.md). Code: `infra/argocd.tf` (switch `argocd_sso_enabled`, roles `argocd_team_roles`) and `oicd-bootstrap/main.tf` (certificates, GitHub teams).

## Where everything lives

| What | Where |
|---|---|
| URL | `https://carelink-<env>-argocd.sctp-sandbox.com` |
| Who may sign in | Members of the GitHub organization `carelink-group03`, managed as code in `oicd-bootstrap/main.tf` (`org_team_members`) |
| Roles | `argocd_team_roles` in `infra/argocd.tf`: team `devops` is admin everywhere; team `team` is admin in staging and **read-only** in production |
| OAuth App (one per environment) | Created by hand **from the organization's page**: `github.com/organizations/carelink-group03/settings/applications` (not your personal Developer settings, see the troubleshooting row on org data). Callback URL `https://carelink-<env>-argocd.sctp-sandbox.com/api/dex/callback` |
| Client ID and secret | Secrets Manager `carelink-<env>-argocd-github-oauth` (`{"clientID": "...", "clientSecret": "..."}`), created empty by Terraform, value stored by a person with `scripts/set-argocd-oauth-secret.sh` |
| Copy in the cluster | Kubernetes Secret `argocd-dex-github` (namespace `argocd`), made by External Secrets every 5 minutes |
| TLS certificate | ACM, `oicd-bootstrap/main.tf` (`aws_acm_certificate.argocd`) |
| Local `admin` login | **Off** wherever `argocd_sso_enabled` is true |

## Switch it on in an environment

Order matters: the certificate and the teams first, then the value, then the switch.

1. **Bootstrap**, from `origin/main` after the pull request with the bootstrap changes is merged. It needs a GitHub token with the `admin:org` scope, once:
   ```bash
   gh auth refresh -h github.com -s admin:org
   ```
   Then the usual bootstrap apply in `oicd-bootstrap/`. Expect the two Argo CD certificates (with their validation records), the two teams and the invitations on the first run. Each invited member must **accept the e-mail invitation** before they can sign in.
2. **Store the OAuth App's client ID and secret.** Terraform creates the empty secret on the first infra deploy that includes `argocd.tf`'s `aws_secretsmanager_secret.argocd_github_oauth` (in every environment, even before the switch is on):
   ```bash
   scripts/set-argocd-oauth-secret.sh staging
   ```
   It prompts for both values and does not show the secret. Never paste the secret into chat, a ticket or a file in the repository.
3. **Copy it into the cluster now** instead of waiting up to 5 minutes:
   ```bash
   kubectl -n argocd annotate externalsecret argocd-dex-github force-sync="$(date +%s)" --overwrite
   kubectl -n argocd get externalsecret argocd-dex-github
   ```
   Expect `SecretSynced` and `READY True`. The ExternalSecret only exists once the switch is on in that environment; before that, step 3 waits until after step 4.
4. **The switch** is `TF_VAR_argocd_sso_enabled: "true"` in that environment's jobs of `.github/workflows/ci.yaml` and `cd.yaml`, merged through a pull request.

If the switch was merged before step 2, sign-in fails until the value is stored. Run steps 2 and 3 then. If sign-in still fails a minute later, restart Dex so it reads the new value: `kubectl -n argocd rollout restart deploy/argocd-dex-server`.

## Sign in

- **Browser:** open the URL, choose **Log in via GitHub**, and approve the OAuth App the first time. **User Info** (left menu) shows your groups, for example `carelink-group03:team`.
- **CLI:** `argocd login carelink-<env>-argocd.sctp-sandbox.com --sso --grpc-web` (the ALB serves HTTP/1 only, hence `--grpc-web`).

## Check it works

| Check | Expected |
|---|---|
| `kubectl -n argocd get ingress argocd-server` | an ALB address |
| `dig +short carelink-<env>-argocd.sctp-sandbox.com` | the ALB's IP addresses (external-dns can take a minute or two) |
| `curl -sI https://carelink-<env>-argocd.sctp-sandbox.com/ \| head -1` | `HTTP/2 200` |
| `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://carelink-<env>-argocd.sctp-sandbox.com/api/webhook` | `404` (blocked at the ALB) |
| `argocd login <host> --username admin --password x --grpc-web` | refused: the local admin is disabled |
| DevOps owner signs in (any environment) | can sync |
| Teammate signs in (production) | sees apps, diffs and logs; **Sync** shows *permission denied* |
| Teammate signs in (staging) | can sync |

## Add or remove a person

Edit `org_team_members` in `oicd-bootstrap/main.tf`, open a pull request, and after the merge run the bootstrap apply from `origin/main`. Removing someone from the map removes them from the teams and the organization, so they cannot sign in again. A session they already have open keeps its role until its token expires (24 hours by default); restarting Dex (`kubectl -n argocd rollout restart deploy/argocd-dex-server`) ends every open session, because Dex keeps its signing keys in memory.

## Rotate the client secret

1. In the environment's OAuth App, **Generate a new client secret** (the old one keeps working).
2. `scripts/set-argocd-oauth-secret.sh <env>`, then step 3 above.
3. Restart Dex (`kubectl -n argocd rollout restart deploy/argocd-dex-server`), sign in to check, then delete the old secret in the OAuth App.

## When the sign-in itself is broken (break-glass)

Deployments are not affected: the app pipeline and the recovery only use `kubectl`. The DevOps owner is cluster admin, so without the UI:

```bash
kubectl -n argocd get applications
argocd login --core                    # talks to the Kubernetes API with your kubeconfig, no UI login
argocd app get carelink-production
```

Common causes:

| Symptom | Look at |
|---|---|
| "Log in via GitHub" missing or erroring | `kubectl -n argocd logs deploy/argocd-dex-server`; is the ExternalSecret `SecretSynced`? Does the Secret carry the label `app.kubernetes.io/part-of: argocd`? |
| GitHub says "redirect_uri is not associated with this application" | The OAuth App's callback URL must be exactly `https://carelink-<env>-argocd.sctp-sandbox.com/api/dex/callback` |
| Sign-in fails; the Dex log says `user not in org or application not authorized to read org data` | The organization blocks OAuth Apps it has not approved (on by default for new organizations), so GitHub hides the membership even from the owner. Seen on staging on 25 Nov and fixed this way. An organization owner opens `https://github.com/settings/connections/applications/<client ID>` and clicks **Grant** next to `carelink-group03`; that approves the app for every member. Apps created from the organization's own page are approved automatically |
| Signed in, but no apps visible | **User Info** groups: the person is not (yet) in a team listed in `argocd_team_roles`, or has not accepted the invitation |
| No ALB, or the Ingress shows a certificate error | `kubectl -n argocd describe ingress argocd-server` events; the certificate comes from the bootstrap apply (step 1) |
