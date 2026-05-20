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

De workflow heeft een bestaande runner nodig om op te draaien. Maak eenmalig een runner aan in een LXC container via het community-script:

1. Voer het installatiescript uit op de Proxmox host:
   ```bash
   bash -c "$(curl -fsSL https://community-scripts.org/scripts/github-runner)"
   ```
2. Haal een registratietoken op: ga naar de repo → **Settings → Actions → Runners → New self-hosted runner** en kopieer het token.
3. Configureer de runner in de container — voeg `--labels proxmox` toe zodat de workflow hem kan vinden:
   ```bash
   cd /opt/actions-runner && sudo -u runner ./config.sh \
     --url https://github.com/<org>/<repo> \
     --token <TOKEN> \
     --labels proxmox
   ```
4. Start de runner service:
   ```bash
   systemctl start actions-runner
   ```

Controleer daarna via **Settings → Actions → Runners** of de runner online staat met het label `proxmox`.

### 2. Sudo-rechten instellen in de LXC container

De workflow draait `sudo bash` om het deploy script met root-rechten uit te voeren. Voer dit eenmalig uit **op de Proxmox host** (niet in de container):

```bash
sudo CTID=<container-id> bash -c "$(curl -fsSL https://raw.githubusercontent.com/devpijnenburg/proxmox-runner-deploy/main/scripts/setup-lxc-sudo.sh)"
```

Vervang `<container-id>` door het ID van de LXC container (bijv. `100`). Het script detecteert automatisch de runner-user en schrijft de sudoers-regel in de container.

### 3. GitHub Personal Access Token (PAT) aanmaken

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

### 4. PAT opslaan als secret

1. Ga naar deze repo → **Settings → Secrets and variables → Actions**
2. Klik **New repository secret**
3. Naam: `GH_PAT`
4. Waarde: het zojuist aangemaakte token

### 5. Runner label aanpassen (indien nodig)

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
│       └── deploy-runner.yml      # GitHub Actions workflow (handmatig te triggeren)
└── scripts/
    ├── setup-lxc-sudo.sh          # Eenmalige setup: sudoers-regel aanmaken in de LXC container (draai op de Proxmox host)
    ├── setup-sudo.sh              # Alternatief: sudoers-regel aanmaken op de host zelf (zonder LXC)
    └── deploy-runner.sh           # Deployment script dat op de Proxmox host draait
```
