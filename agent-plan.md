# Plan: AI Agent voor automatisch deployen van GitHub Actions runners op Proxmox

## Context

We hebben een repo `devpijnenburg/auto-github-runner` met een GitHub Actions workflow en bash-scripts die een self-hosted runner deployen op een Proxmox host. Nu willen we een Claude AI-agent bouwen die hetzelfde kan via een conversatie-interface.

De bestaande scripts staan in:
- `scripts/deploy-runner.sh` — installeert, configureert en start de runner op de Proxmox host
- `scripts/setup-sudo.sh` — eenmalige sudoers setup op de host

---

## Wat de agent moet kunnen

De gebruiker typt iets als: *"Deploy een nieuwe runner voor https://github.com/mijn-org/mijn-repo"* en de agent:
1. Haalt automatisch een runner registratietoken op via de GitHub API
2. SSH't naar de Proxmox host en voert `deploy-runner.sh` uit
3. Bevestigt dat de runner actief is

---

## Branch

Maak een nieuwe branch aan vanaf `main`:
```bash
git checkout main
git pull origin main
git checkout -b feature/ai-runner-agent
```

---

## Tech stack

- Python 3.11+
- `anthropic` SDK (Claude API met tool use)
- `paramiko` (SSH naar Proxmox)
- `httpx` (GitHub API calls)
- `python-dotenv` (env vars)

---

## Projectstructuur

```
agent/
├── main.py              # entrypoint, start de chat-loop
├── agent.py             # Claude agent met tool use
├── tools/
│   ├── github.py        # tool: genereer runner registratietoken via GitHub API
│   └── proxmox.py       # tool: SSH naar Proxmox en voer deploy script uit
├── requirements.txt
└── .env.example
```

---

## Benodigde environment variables (`.env`)

```
ANTHROPIC_API_KEY=        # Anthropic API sleutel
GH_PAT=                   # GitHub fine-grained PAT (Administration: Read & write)
PROXMOX_HOST=             # IP of hostname van de Proxmox host
PROXMOX_USER=             # SSH gebruiker (bijv. root)
PROXMOX_SSH_KEY=          # pad naar private SSH key
```

---

## Tool definities voor de agent

### Tool 1 — `get_runner_token`

```python
{
    "name": "get_runner_token",
    "description": "Haalt een GitHub Actions runner registratietoken op via de GitHub API voor een repo of organisatie.",
    "input_schema": {
        "type": "object",
        "properties": {
            "repo_url": {
                "type": "string",
                "description": "Volledige GitHub URL, bijv. https://github.com/org/repo of https://github.com/org"
            }
        },
        "required": ["repo_url"]
    }
}
```

Implementatie: parse de URL, bepaal of het repo of org is, POST naar de juiste GitHub API endpoint met de `GH_PAT`.

### Tool 2 — `deploy_runner`

```python
{
    "name": "deploy_runner",
    "description": "Deployt een GitHub Actions runner op de Proxmox host via SSH.",
    "input_schema": {
        "type": "object",
        "properties": {
            "runner_name": {
                "type": "string",
                "description": "Unieke naam voor de runner. Genereer een UUID als de gebruiker geen naam opgeeft."
            },
            "runner_repo": {
                "type": "string",
                "description": "Volledige GitHub URL waarvoor de runner geregistreerd wordt."
            },
            "runner_token": {
                "type": "string",
                "description": "Registratietoken verkregen via get_runner_token."
            }
        },
        "required": ["runner_name", "runner_repo", "runner_token"]
    }
}
```

Implementatie: SSH naar de Proxmox host via `paramiko`, voer `deploy-runner.sh` uit met de juiste env vars, stream de output terug naar de gebruiker.

---

## Agent flow (`agent.py`)

```python
import anthropic

client = anthropic.Anthropic()

SYSTEM_PROMPT = """
Je bent een DevOps-assistent die GitHub Actions self-hosted runners deployt op een Proxmox host.
Wanneer de gebruiker een runner wil deployen:
1. Vraag om de repo-URL als die ontbreekt.
2. Genereer automatisch een runner naam met UUID als de gebruiker er geen opgeeft.
3. Roep eerst get_runner_token aan, dan deploy_runner.
4. Bevestig aan de gebruiker dat de runner actief is.
"""

def run_agent(user_message: str):
    messages = [{"role": "user", "content": user_message}]

    while True:
        response = client.messages.create(
            model="claude-opus-4-7",
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            tools=[get_runner_token_tool, deploy_runner_tool],
            messages=messages
        )

        if response.stop_reason == "end_turn":
            print(response.content[0].text)
            break

        if response.stop_reason == "tool_use":
            messages.append({"role": "assistant", "content": response.content})
            tool_results = []
            for block in response.content:
                if block.type == "tool_use":
                    result = execute_tool(block.name, block.input)
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block.id,
                        "content": result
                    })
            messages.append({"role": "user", "content": tool_results})
```

---

## `main.py` — simpele CLI chat-loop

```python
def main():
    print("Runner Agent gestart. Typ 'exit' om te stoppen.")
    while True:
        user_input = input("\nJij: ").strip()
        if user_input.lower() == "exit":
            break
        run_agent(user_input)

if __name__ == "__main__":
    main()
```

---

## `requirements.txt`

```
anthropic>=0.40.0
paramiko>=3.4.0
httpx>=0.27.0
python-dotenv>=1.0.0
```

---

## Implementatievolgorde

1. Maak de mapstructuur aan
2. Implementeer `tools/github.py` — token ophalen (dezelfde logica als in de bestaande workflow)
3. Implementeer `tools/proxmox.py` — SSH verbinding + script uitvoeren via `paramiko`
4. Implementeer `agent.py` — Claude agent met tool use loop
5. Implementeer `main.py` — CLI entrypoint
6. Schrijf `.env.example`
7. Test: *"Deploy een runner voor https://github.com/devpijnenburg/auto-github-runner"*
8. Commit en push naar `feature/ai-runner-agent`
