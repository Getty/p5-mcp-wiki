# CLAUDE.md

**MCP::Wiki** ist ein stdio-MCP-Server, der ein Verzeichnis voller Markdown-Dateien als
Wiki verwaltet: TOC extrahieren, Abschnitte absatzweise lesen und schreiben, optional
pro Änderung committen und Abschnitte aus der Git-Historie zurückholen. Eine
Distribution, ein Einstiegspunkt (`bin/mcp-wiki`), Auslieferung über CPAN und ein
Docker-Image.

## Projektstruktur

```
lib/MCP/Wiki/Server.pm       # Moo; registriert die 9 MCP-Tools, on_change, Auto-Commit
lib/MCP/Wiki/Document.pm     # eine Seite lesen/schreiben
lib/MCP/Wiki/TOC/Parser.pm   # zeilenbasierter ATX-Parser -> Entry-Liste
lib/MCP/Wiki/TOC/Entry.pm    # Wertobjekt; as_hash ist die Wire-Form der TOC
lib/MCP/Wiki/Git/History.pm  # Git::Raw: Section-Historie, Restore, Auto-Commit
lib/MCP/Wiki/Git.pm          # Altbestand, vom Server nicht benutzt
bin/mcp-wiki                 # CLI-Runner
t/                           # Test::More, tempdir-basiert, laufen ohne Git::Raw
```

Adressiert wird eine Section über ihren `heading_path` (`Intro#Background`), nie über
Zeilennummern — die gelten nur für den einen Parse-Lauf, aus dem sie stammen.

## Key Commands

```bash
prove -lr t/            # kanonisch — rekursiv; plain `prove -l t/` überspringt Unterverzeichnisse stumm
prove -lv t/10-toc.t    # Einzeltest
dzil build              # Distribution bauen
```

`Git::Raw` ist auf dieser Maschine nicht installiert, und die Suite muss ohne es grün
bleiben: `git_history` liefert dann `undef` und die Historie-Tools antworten sauber mit
"not available". Das ist Feature, nicht Lücke.

## Stand des Codes

`PLAN.md` ist der ursprüngliche Entwurf, keine Beschreibung des Ist-Zustands — Content
Hashing, Conflict-Marker, `Git::Blame` und Async-Callbacks darin existieren nicht. Bei
Widerspruch gewinnt `lib/`.

Vier verifizierte Defekte sind bekannt und als karr-Tickets erfasst (heading_path sammelt
Geschwister statt Vorfahren, get/set_paragraph sind nicht round-trip-fähig,
restore_section wendet seinen Patch doppelt an, der wiki-root-Check ist ein reiner
String-Präfix). Mechanik und Blast Radius stehen im Skill `mcp-wiki-core`; nicht
nebenbei mitfixen.

## Delegation

Behavior-relevanten Code nicht selbst anfassen, sondern an den passenden Agent geben —
Prinzip und Lane stehen in `.claude/rules/mcp-wiki-rules.md`.

| Aufgabe | Agent |
|---|---|
| Implementieren / refactoren / debuggen, Docker | `mcp-wiki-worker` (default) |
| Tests schreiben oder erweitern | `mcp-wiki-test-writer` |
| Pre-Release-Audit | `mcp-wiki-release-checker` |

Die Agents bekommen ihre Skills über `briefing.skills` (siehe `.claude/agents/`); der
Main-Agent delegiert, statt sie selbst zu laden. Skill-Quellen liegen unter
`.claude/skills/`.
