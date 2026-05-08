# skills

All the shared agentic skills.

## Create new skill

1. clone this repo:

```bash
git clone https://github.com/ZDHL-Amazing/skills.git
```

2. running the command below in the repo

```bash
bunx skills init [YOUR_SKILL_NAME]
```


Important: make sure all the skills are flatted directory. if you wanna create a `demo-skill`, the whole project structure should look like:

```
.
├── flyway-migration
│   ├── scripts
│   │   ├── check_filename.ps1
│   │   └── check_filename.sh
│   └── SKILL.md
├── demo-skill              <------- here
│   └── SKILL.md
└── README.md
```

## Table of content

- [flyway-migration](./flyway-migration/): Generate database migration files (flyway) with your favorite agent.
