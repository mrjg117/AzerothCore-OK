#!/usr/bin/env bash
# =============================================================================
# OK build-patch: zero-config, modules-default-ON
# -----------------------------------------------------------------------------
# Drop this file into:  build-patches/core/zero_config_modules_enable.sh
# It is applied by .github/workflows/build-core.yml  ->  "Apply build-patches"
# which runs every *.sh under build-patches/core/  from the CORE source root
# ($OFF).  This script patches src/common/Configuration/Config.cpp so that:
#
#   1. A *missing* config option that belongs to a module (its name contains
#      '.', e.g. QuestParty.Enable / WarriorAdditions.RendSpread.ProcChance)
#      will NO LONGER halt the server.  It falls back to its safe default and
#      a warning is logged instead.  ("zero-config boot")
#
#   2. Bool module toggles whose name ends with ".Enable" / ".Enabled" default
#      to enabled ("1") when absent.  ("modules default ON")
#
#   3. Core critical options that have NO dot (RealmID / LoginDatabaseInfo /
#      WorldDatabaseInfo / CharacterDatabaseInfo) keep their original Fatal
#      behaviour -- we still refuse to boot without DB info.
#
#   4. Any value the admin sets explicitly (including "X.Enable = 0") is fully
#      respected; the patch only changes the *missing* case.
#
# Idempotent: safe to re-run; applies once.
# Requires: python3 (present in the AC build container).
# =============================================================================
set -e

F="src/common/Configuration/Config.cpp"
if [ ! -f "$F" ]; then
    echo "!! zero_config: $F not found (pwd=$(pwd))"
    exit 1
fi

python3 - "$F" <<'PY'
import sys, os

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARKER = "// === ZERO-CONFIG MODULE ENABLE (OK build-patch) ==="
if MARKER in src:
    print("zero_config: already applied, skip")
    sys.exit(0)

# Two functions share identical body text; we insert a tailored block into each
# by locating the function signature first, then the shared anchor line.
GENERIC_SIG = "T ConfigMgr::GetValueDefault(std::string const& name, T const& def"
STRING_SIG  = "std::string ConfigMgr::GetValueDefault<std::string>(std::string const& name, std::string const& def"
ANCHOR = "ConfigSeverity severity = isCritical ? _policy.criticalOptionSeverity : _policy.missingOptionSeverity;"

def insert(src, sig, block):
    i = src.find(sig)
    if i < 0:
        raise SystemExit("ERROR: signature not found: " + sig)
    a = src.find(ANCHOR, i)
    if a < 0:
        raise SystemExit("ERROR: anchor not found after: " + sig)
    eol = src.find("\n", a)
    return src[:eol+1] + block + src[eol+1:]

# --- Generic <T> specialization: missing module option -> return its safe def
generic_block = '''            // === ZERO-CONFIG MODULE ENABLE (OK build-patch) ===
            // A missing option that belongs to a module (name contains '.') must
            // not halt the server. It falls back to its safe default and a
            // warning is logged. Core critical options (no '.') keep Fatal.
            if (name.find('.') != std::string::npos)
            {
                LOG_WARN("server.loading",
                    "> Config: [zero-config] module option '{}' missing, auto-default (module enabled).",
                    name);
                return def;
            }
            // === END ZERO-CONFIG MODULE ENABLE ===
'''

# --- std::string specialization: same, but bool *.Enable defaults to "1"
string_block = '''            // === ZERO-CONFIG MODULE ENABLE (OK build-patch) ===
            // A missing option that belongs to a module (name contains '.') must
            // not halt the server. Bool *.Enable / *.Enabled toggles default to
            // enabled ("1"); all other module options fall back to their safe
            // default. Core critical options (no '.') keep Fatal.
            if (name.find('.') != std::string::npos)
            {
                auto iends_with = [](std::string const& s, char const* suf) -> bool {
                    size_t sl = s.size(); size_t kl = 0; while (suf[kl]) ++kl;
                    if (kl > sl) return false;
                    for (size_t i = 0; i < kl; ++i) {
                        char a = s[sl - kl + i]; if (a >= 'A' && a <= 'Z') a += 32;
                        char b = suf[i];           if (b >= 'A' && b <= 'Z') b += 32;
                        if (a != b) return false;
                    }
                    return true;
                };
                std::string safeDefault = def;
                if (iends_with(name, ".Enable") || iends_with(name, ".Enabled"))
                    safeDefault = "1";
                LOG_WARN("server.loading",
                    "> Config: [zero-config] module option '{}' missing, auto-default '{}' (module enabled).",
                    name, safeDefault);
                return safeDefault;
            }
            // === END ZERO-CONFIG MODULE ENABLE ===
'''

src = insert(src, GENERIC_SIG, generic_block)
src = insert(src, STRING_SIG, string_block)

# Sanity: the anchor must have existed exactly twice (both specializations)
if src.count(ANCHOR) != 2:
    raise SystemExit("ERROR: unexpected anchor count " + str(src.count(ANCHOR)))

open(path, "w", encoding="utf-8").write(src)
print("zero_config: patched", path)
PY

echo "zero_config_modules_enable.sh done"
