# Quality gates for the Beacon plugin (bitty-terminal.beacon).
#
# Metadata gates (fmt-check, markdownlint, metadata, hygiene, paths) plus the
# product gates derived from the plugin template: the manifest gate runs the
# authoritative SDK linter (bitty-plugin-lint, pinned by commit), the docs-check
# gate verifies the README Configuration table against `[settings]`, the Lua
# gate parses the entry point with a pinned grammar, and `just test` runs the
# wasmoon + MockHost behavior suite. Dependencies live in package.json and are
# locked in bun.lock.
prettier_version := "3.9.6"
markdownlint_version := "0.23.1"
actionlint_version := "1.7.12"

# Pinned parser version; keep identical to the luaparse devDependency in
# package.json.
luaparse_pin := "0.3.1"

fmt-check:
    bunx --bun prettier@{{prettier_version}} --check . --ignore-unknown

markdownlint:
    bunx --bun markdownlint-cli2@{{markdownlint_version}}

metadata:
    test -s README.md && test -s AGENTS.md && test -s repo.toml && test -s bitty-plugin.toml
    test ! -e TODO.md
    test -s .carryctx/config.toml
    python3 -c 'import tomllib; from pathlib import Path; [tomllib.loads(p.read_text()) for p in [Path("repo.toml"), Path(".carryctx/config.toml"), Path("bitty-plugin.toml")]]'

hygiene:
    #!/usr/bin/env bash
    set -euo pipefail
    bad=0
    while IFS= read -r -d '' f; do
        case "$f" in
            *.sqlite|*.db|*.zst|*.tar|*.tar.gz|*.tgz|node_modules/*|target/*|dist/*|.worktrees/*)
                echo "unexpected artifact tracked: $f" >&2; bad=1 ;;
        esac
    done < <(git ls-files -z --cached --others --exclude-standard)
    test "$bad" -eq 0

paths:
    #!/usr/bin/env bash
    set -euo pipefail
    pattern='(/hom''e/|/Use''rs/|/mn''t/[A-Za-z]|[A-Za-z]:[\\/]Use''rs[\\/])'
    found=0
    while IFS= read -r -d '' f; do
        if grep -nEI "$pattern" "$f"; then found=1; fi
    done < <(git ls-files -z --cached --others --exclude-standard)
    if [ "$found" -ne 0 ]; then
        echo 'hardcoded host path detected (portable-path gate)' >&2
        exit 1
    fi
    echo 'portable-path gate passed'

actionlint:
    @installed="$(actionlint --version | head -n 1)"; test "$installed" = "{{actionlint_version}}" || { echo "actionlint {{actionlint_version}} required; found $installed" >&2; exit 1; }
    actionlint -color -shellcheck=

check:
    just fmt-check
    just markdownlint
    just metadata
    just hygiene
    just paths
    just manifest
    just docs-check
    just lua
    just lua-control
    just test

# Install pinned dev dependencies from bun.lock.
install:
    bun install --frozen-lockfile

# Ensure node_modules is materialized from bun.lock.
deps:
    @test -d node_modules || bun install --frozen-lockfile

# Validate bitty-plugin.toml with the authoritative SDK linter (R-SDK-2),
# pinned by commit in package.json and bun.lock.
manifest: deps
    @test -x node_modules/.bin/bitty-plugin-lint || { echo "bitty-plugin-lint is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-lint bitty-plugin.toml

# Validate README.md against the SDK user-documentation contract and `[settings]`.
docs-check: deps
    @test -x node_modules/.bin/bitty-plugin-docs-check || { echo "bitty-plugin-docs-check is not installed; run 'just install'" >&2; exit 1; }
    bun run bitty-plugin-docs-check .

# Parse the Lua entry point with a pinned Lua 5.1 grammar parser.
lua: deps
    bunx --bun luaparse@{{luaparse_pin}} --quiet --file lua/beacon/init.lua

# Fail-closed control for the `lua` gate: the same pinned parser must reject an
# invalid snippet.
lua-control: deps
    @! bunx --bun luaparse@{{luaparse_pin}} --quiet --code 'local ='

# Run the Beacon behavior and contract suite in wasmoon + MockHost.
test: deps
    bun test

workflows:
    actionlint
    act -n

# Publish a redacted CarryCtx snapshot to refs/heads/carryctx-snapshots.
workflow-publish:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    carryctx export --pack-format dir -o "$tmp" --publication
    git push origin refs/heads/carryctx-snapshots

# Fetch and import the published CarryCtx snapshot (fresh-clone recovery).
workflow-import:
    git fetch origin refs/heads/carryctx-snapshots:refs/remotes/origin/carryctx-snapshots
    carryctx import --from-git refs/remotes/origin/carryctx-snapshots

# Product evidence: manifest, docs, Lua grammar, and behavior gates.
product:
    just manifest
    just docs-check
    just lua
    just lua-control
    just test
