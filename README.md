# auto-github-runner

Automatisch een GitHub Actions self-hosted runner deployen op een Proxmox host via een GitHub Actions workflow. Je triggert de workflow handmatig, geeft een doelrepo op, en de runner wordt geïnstalleerd, geconfigureerd en gestart — zonder dat je zelf op de server hoeft in te loggen.

## Hoe het werkt

```
GitHub Actions workflow
        │
        │  draait op een bestaande self-hosted runner op Proxmox
        ▼
1. Genereer een registratietoken via de GitHub API (met jouw GH_PAT)
2. Download de nieuwste runner binary van GitHub
3. Installeer naar /opt/actions-runner-<naam>
4. Maak een dedicated systeemgebruiker aan (runner)
5. Configureer de runner (config.sh --url ... --token ... --name ...)
6. Registreer en start een systemd service (actions-runner-<naam>)
```

Elke runner krijgt een eigen map en service op de host, zodat je meerdere runners naast elkaar kunt draaien zonder conflict.

## Vereisten

- Een Proxmox host met minimaal één bestaande self-hosted GitHub Actions runner (met label `proxmox`) — zie stap 1 hieronder
- De Proxmox host draait een Debian/Ubuntu-gebaseerd OS

## Configuratie

### 1. Bootstrap runner aanmaken

De workflow heeft een bestaande runner nodig om op te draaien. Voer dit script uit op de Proxmox host — het maakt een LXC container aan, installeert de runner erin en configureert alles automatisch.

**Unattended:**
```bash
REPO_URL=https://github.com/<org>/<repo> TOKEN=<token> sudo bash create-bootstrap-runner.sh
```

**Interactief (het script vraagt om de ontbrekende waarden):**
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/devpijnenburg/proxmox-runner-deploy/main/scripts/create-bootstrap-runner.sh)"
```

Haal het registratietoken op via: repo → **Settings → Actions → Runners → New self-hosted runner**.

De runner krijgt automatisch het label `proxmox` en de juiste sudoers-regel. Controleer daarna via **Settings → Actions → Runners** of hij online staat.

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

De workflow verwacht dat de bestaande Proxmox runner het label `proxmox` heeft. Controleer dit via **Settings → Actions → Runners** in jouw repo of organisatie. Pas het label aan in de workflow als het anders is:

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
| `runner_name` | Nee | Naam van de runner. Wordt leeg gelaten: automatisch een UUID gegenereerd, bijv. `runner-4a7f3c12-...` |
| `runner_repo` | Ja | URL van de repo of org waarvoor de runner geregistreerd wordt, bijv. `https://github.com/jouw-org/jouw-repo` |

4. Klik **Run workflow**

Na afloop zie je de runner verschijnen onder **Settings → Actions → Runners** van de opgegeven repo of org.

## Wat er op de host aangemaakt wordt

Per deployment worden de volgende bestanden aangemaakt op de Proxmox host:

```
/opt/actions-runner-<naam>/          # runner binaries en configuratie
/etc/systemd/system/actions-runner-<naam>.service  # systemd service
```

De systemd service start automatisch na een herstart van de host en herstart de runner automatisch bij een crash.

## Structuur

```
.
├── .github/
│   └── workflows/
│       └── deploy-runner.yml          # GitHub Actions workflow (handmatig te triggeren)
└── scripts/
    ├── create-bootstrap-runner.sh     # Eenmalige setup: maakt LXC aan met runner erin (draai op de Proxmox host)
    ├── setup-lxc-sudo.sh              # Alternatief: sudoers instellen in een bestaande LXC
    ├── setup-sudo.sh                  # Alternatief: sudoers instellen op de host zelf (zonder LXC)
    └── deploy-runner.sh               # Deployment script dat via de workflow op de host draait
```
