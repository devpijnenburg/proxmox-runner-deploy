# proxmox-runner-deploy

Automatisch een GitHub Actions self-hosted runner deployen als nieuwe LXC container op een Proxmox host via een GitHub Actions workflow. Je triggert de workflow handmatig, geeft een doelrepo op, en de runner wordt in een eigen LXC geïnstalleerd, geconfigureerd en gestart.

## Hoe het werkt

```
GitHub Actions workflow
        │
        │  draait op de bootstrap runner (direct op de Proxmox host)
        ▼
1. Reserveer een nieuw LXC container ID (pvesh get /cluster/nextid)
2. Genereer een registratietoken via de GitHub API (met jouw GH_PAT)
3. Maak een nieuwe LXC aan via community-scripts/ProxmoxVE (unattended)
4. Configureer de runner in de nieuwe container (config.sh --labels proxmox)
5. Start de runner service (systemctl start actions-runner)
```

Elke runner draait in zijn eigen LXC container. De bootstrap runner draait direct op de Proxmox host zodat hij `pct create` kan aanroepen.

## Vereisten

- Een Proxmox host met de bootstrap runner geïnstalleerd (zie stap 1)
- De Proxmox host draait een Debian/Ubuntu-gebaseerd OS

## Configuratie

### 1. Bootstrap runner installeren op de Proxmox host

De bootstrap runner draait **direct op de Proxmox host** (niet in een LXC), zodat hij nieuwe LXC containers kan aanmaken voor elke gedeployde runner.

**Interactief:**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/devpijnenburg/proxmox-runner-deploy/main/scripts/create-bootstrap-runner.sh)"
```

**Unattended:**
```bash
REPO_URL=https://github.com/<org>/<repo> TOKEN=<token> bash -c "$(curl -fsSL https://raw.githubusercontent.com/devpijnenburg/proxmox-runner-deploy/main/scripts/create-bootstrap-runner.sh)"
```

Haal het registratietoken op via: repo → **Settings → Actions → Runners → New self-hosted runner**.

Controleer daarna via **Settings → Actions → Runners** of de runner online staat met het label `proxmox`.

### 2. GitHub Personal Access Token (PAT) aanmaken

De workflow heeft een PAT nodig om automatisch een runner registratietoken op te halen via de GitHub API. Maak een **fine-grained PAT** aan:

1. Ga naar **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Klik **Generate new token**
3. Stel in:
   - **Resource owner**: jouw account of de organisatie
   - **Repository access**: alleen de repo's waar je runners voor wil deployen
   - **Permissions:**

| Situatie | Permissie |
|---|---|
| Runner voor een specifieke repo | `Administration: Read & write` |
| Runner voor een organisatie | `Organization self-hosted runners: Read & write` |

> **Opmerking:** voor organisaties moet de org-eigenaar fine-grained PATs toestaan via **Org Settings → Personal access tokens → Allow fine-grained personal access tokens**.

### 3. PAT opslaan als secret

1. Ga naar deze repo → **Settings → Secrets and variables → Actions**
2. Klik **New repository secret**
3. Naam: `GH_PAT`
4. Waarde: het zojuist aangemaakte token

### 4. Runner label aanpassen (indien nodig)

De workflow verwacht dat de bootstrap runner het label `proxmox` heeft. Controleer dit via **Settings → Actions → Runners** in jouw repo of organisatie. Pas het label aan in de workflow als het anders is:

```yaml
# .github/workflows/deploy-runner.yml
runs-on: [self-hosted, proxmox]  # ← pas 'proxmox' aan naar jouw label
```

## Gebruik

1. Ga naar **Actions → Deploy GitHub Actions Runner on Proxmox**
2. Klik **Run workflow**
3. Vul in:

| Veld | Verplicht | Beschrijving |
|---|---|---|
| `runner_name` | Nee | Naam van de runner. Leeg laten: automatisch een UUID gegenereerd, bijv. `runner-4a7f3c12-...` |
| `runner_repo` | Ja | URL van de repo of org waarvoor de runner geregistreerd wordt, bijv. `https://github.com/jouw-org/jouw-repo` |

4. Klik **Run workflow**

Na afloop verschijnt de nieuwe runner onder **Settings → Actions → Runners** van de opgegeven repo of org, en draait hij in zijn eigen LXC container op de Proxmox host.

## Wat er aangemaakt wordt per deployment

```
LXC container <auto-ID>      # aangemaakt via community-scripts/ProxmoxVE
  /opt/actions-runner/       # runner binary en configuratie
  actions-runner.service     # systemd service
```

De LXC container start automatisch na een herstart van de host. De runner service herstart automatisch bij een crash.

## Structuur

```
.
├── .github/
│   └── workflows/
│       └── deploy-runner.yml          # GitHub Actions workflow (handmatig te triggeren)
└── scripts/
    ├── create-bootstrap-runner.sh     # Eenmalige setup: bootstrap runner op de Proxmox host
    ├── deploy-runner.sh               # Maakt LXC via community-scripts en configureert runner erin
    ├── setup-lxc-sudo.sh              # Hulpscript: sudoers instellen in een bestaande LXC
    └── setup-sudo.sh                  # Hulpscript: sudoers instellen op de host
```
