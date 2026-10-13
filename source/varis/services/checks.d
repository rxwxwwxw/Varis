/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Static checks over the project index (AUTHORING_TOOLS_PLAN stage A3). They run nothing.
/// Rule for all of them: when a check cannot be sure, it stays silent or reports a warning. A
/// false error teaches writers to ignore the checker.
module varis.services.checks;

import varis.services.diagnostic;
import varis.services.index;

/// Edit distance, capped: returns `cap + 1` when it exceeds `cap`.
private int editDistance(string a, string b, int cap) {
    if (a.length > b.length + cap || b.length > a.length + cap)
        return cap + 1;
    auto previous = new int[b.length + 1];
    auto current = new int[b.length + 1];
    foreach (j; 0 .. b.length + 1)
        previous[j] = cast(int) j;
    foreach (i; 1 .. a.length + 1) {
        current[0] = cast(int) i;
        foreach (j; 1 .. b.length + 1) {
            int cost = a[i - 1] == b[j - 1] ? 0 : 1;
            int best = previous[j - 1] + cost;
            if (previous[j] + 1 < best)
                best = previous[j] + 1;
            if (current[j - 1] + 1 < best)
                best = current[j - 1] + 1;
            current[j] = best;
        }
        auto swap = previous;
        previous = current;
        current = swap;
    }
    int result = previous[b.length];
    return result > cap ? cap + 1 : result;
}

/// The nearest of `candidates` to `name`, or null when none is close. Names tolerate one
/// edit, long names two; a name is never its own suggestion.
string nearestName(string name, const(string)[] candidates) {
    int cap = name.length >= 10 ? 2 : (name.length >= 3 ? 1 : 0);
    string best;
    int bestDistance = cap + 1;
    foreach (candidate; candidates) {
        if (candidate == name)
            continue;
        int d = editDistance(name, candidate, cap);
        if (d < bestDistance || (d == bestDistance && d <= cap && candidate < best)) {
            bestDistance = d;
            best = candidate;
        }
    }
    return bestDistance <= cap ? best : null;
}

private string join(const(string)[] items, string separator = ", ") {
    string text;
    foreach (i, item; items)
        text ~= (i ? separator : "") ~ item;
    return text;
}

private string place(string file, int line) {
    char[16] buffer;
    import core.stdc.stdio : snprintf;

    auto n = snprintf(buffer.ptr, buffer.length, "%d", line);
    return file ~ ":" ~ buffer[0 .. n].idup;
}

private Diagnostic at(string severity, string code, string file, Range r, string message, string subject) {
    return makeDiagnostic(severity, code, file, r.line, r.column, r.endLine, r.endColumn, message, subject);
}

/// Appends the findings to `found`.
void staticChecks(ref const ProjectIndex index, ref Diagnostic[] found) {
    bool[string] sceneNames, characterNames, attributeNames;
    foreach (ref file; index.files)
        foreach (ref declaration; file.declarations) {
            if (declaration.kind == "scene")
                sceneNames[declaration.name] = true;
            if (declaration.kind == "character")
                characterNames[declaration.name] = true;
            if (declaration.kind == "character-attribute")
                attributeNames[declaration.owner ~ "." ~ declaration.name] = true;
        }
    foreach (ref file; index.files)
        foreach (ref reference; file.references) {
            bool missing;
            if (reference.kind == "scene")
                missing = reference.name !in sceneNames;
            if (reference.kind == "character")
                missing = reference.name !in characterNames;
            if (reference.kind == "character-attribute" && reference.qualifier in characterNames)
                missing = (reference.qualifier ~ "." ~ reference.name) !in attributeNames;
            if (missing)
                found ~= at("error", "unknown-" ~ reference.kind, reference.file, reference.range,
                        "unknown " ~ reference.kind ~ " '" ~ reference.name ~ "'", reference.inside);
            // the battle bridge's data (stage TD3): ability and trigger names, a kind's fields,
            // a trigger's arguments
            if (reference.kind == "battle-ability" || reference.kind == "battle-trigger") {
                static immutable abilities = [
                    "single", "splash", "slow", "chain", "burn", "aura", "shield",
                    "summon", "repair", "taunt"
                ];
                static immutable triggers = [
                    "step", "wave_start", "structure_destroyed", "leak_count", "battle_won",
                    "battle_lost", "hero_downed", "hero_hp_below", "heroes_near", "enemy_kind_seen"
                ];
                immutable names = reference.kind == "battle-ability" ? abilities[] : triggers[];
                bool known;
                foreach (n; names)
                    known = known || n == reference.name;
                if (!known) {
                    auto diagnostic = at("error", reference.kind == "battle-ability" ? "unknown-ability" : "unknown-trigger",
                            reference.file, reference.range, "unknown " ~ (reference.kind == "battle-ability" ? "ability" : "trigger") ~ " \"" ~ reference
                            .name ~ "\" (one of " ~ join(names) ~ ")", reference.inside);
                    diagnostic.suggestion = nearestName(reference.name, names);
                    found ~= diagnostic;
                }
            }
            if (reference.kind == "battle-field")
                found ~= at("error", "missing-battle-field", reference.file, reference.range, reference.qualifier,
                        reference.inside);
            if (reference.kind == "battle-argument")
                found ~= at("error", "bad-battle-argument", reference.file, reference.range, reference.qualifier,
                        reference.inside);
        }
    // Pools of what the project declares.
    bool[string] decks = ["default": true];
    bool[string] qualities;
    bool computedQuality;
    bool[string] relationKnown; // declared, asserted or derived somewhere
    int[string] declaredArity;
    string[string] declaredAt; // relation name -> "file:line"
    bool[string] localRelations;
    bool[string] anyRelation;
    string[] deckNames = ["default"];
    string[] qualityNames;
    string[] topLevelNames;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations) {
            if (d.kind == "deck" && d.name !in decks) {
                decks[d.name] = true;
                deckNames ~= d.name;
            }
            if (d.kind == "quality") {
                if (d.computed)
                    computedQuality = true;
                else if (d.name !in qualities) {
                    qualities[d.name] = true;
                    qualityNames ~= d.name;
                }
            }
            if (d.kind == "relation" || d.kind == "rule" || d.kind == "local-relation") {
                relationKnown[d.name] = true;
                if (d.kind == "local-relation")
                    localRelations[d.name] = true;
                if (d.kind == "relation" && d.name !in declaredArity) {
                    declaredArity[d.name] = d.arity;
                    declaredAt[d.name] = place(d.file, d.range.line);
                }
            }
            if (d.kind == "storylet" || d.kind == "action" || d.kind == "deck" || d.kind == "relation" || d.kind == "quality")
                topLevelNames ~= d.name;
        }
    // Relations the engine declares in every session world: `quality(entity, name, value)`
    // (lib/quality.d) and `narrative_event(seq, turn, kind, args)` (narrative/session.d).
    relationKnown["quality"] = true;
    relationKnown["narrative_event"] = true;
    foreach (ref f; index.files)
        foreach (ref r; f.references)
            if (r.kind == "relation" && (r.role == "assert" || r.role == "update"))
                relationKnown[r.name] = true;

    // duplicate-id: two storylets, actions or decks with one name; two choices of one storylet.
    struct First {
        string file;
        int line;
    }

    First[string] seen;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations) {
            if (d.computed || d.name.length == 0)
                continue;
            string key;
            if (d.kind == "storylet" || d.kind == "action" || d.kind == "deck" || d.kind == "scene" || d.kind == "character")
                key = d.kind ~ " " ~ d.name;
            else if (d.kind == "choice")
                key = "choice " ~ d.owner ~ "." ~ d.name;
            else
                continue;
            if (auto first = key in seen) {
                auto diagnostic = at("error", "duplicate-id", d.file, d.range, d.subject ~ " is declared twice (first at " ~ place(
                        first.file, first.line) ~ ")", d.subject);
                diagnostic.related ~= Related(first.file, first.line, 1, "first declaration");
                found ~= diagnostic;
            } else
                seen[key] = First(d.file, d.range.line);
        }

    // Parameters by definition, for unknown-placeholder.
    string[][string] parameters; // subject -> names
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.kind == "storylet" || d.kind == "action" || d.kind == "scene")
                parameters[d.subject] ~= d.parameters ~ d.exposed;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.kind == "choice") {
                auto owner = "storylet " ~ d.owner;
                string[] names = d.parameters.dup ~ d.exposed.dup;
                if (auto inherited = owner in parameters)
                    names ~= *inherited;
                parameters[d.subject] = names;
            }

    foreach (ref f; index.files) {
        foreach (ref d; f.declarations) {
            // unknown-deck, for a choice's `leads`
            if (d.kind == "choice" && d.leads.length && d.leads !in decks) {
                Range where = d.range;
                foreach (ref r; f.references)
                    if (r.kind == "deck" && r.inside == d.subject && r.name == d.leads)
                        where = r.range;
                auto diagnostic = at("error", "unknown-deck", f.path, where, d.subject ~ " leads to deck :" ~ d.leads
                        ~ ", which no `deck :" ~ d.leads ~ " {...}` declares", d.subject);
                diagnostic.suggestion = nearestName(d.leads, deckNames);
                found ~= diagnostic;
            }
            // unknown-deck
            if (d.kind == "storylet" && d.deck.length && d.deck !in decks) {
                // Find the reference to place the diagnostic on the symbol.
                Range where = d.range;
                foreach (ref r; f.references)
                    if (r.kind == "deck" && r.inside == d.subject && r.name == d.deck)
                        where = r.range;
                auto diagnostic = at("error", "unknown-deck", f.path, where, d.subject ~ " is in deck :" ~ d.deck
                        ~ ", which no `deck :" ~ d.deck ~ " {...}` declares", d.subject);
                diagnostic.suggestion = nearestName(d.deck, deckNames);
                found ~= diagnostic;
            }
        }
        foreach (ref r; f.references) {
            // unknown-placeholder
            if (r.kind == "placeholder") {
                if (auto names = r.inside in parameters) {
                    bool known;
                    foreach (n; *names)
                        if (n == r.name)
                            known = true;
                    if (!known) {
                        auto diagnostic = at("error", "unknown-placeholder", r.file, r.range, "{" ~ r.name ~ "} in "
                                ~ r.inside ~ " is not one of its parameters" ~ (names.length ? " (" ~ join(
                                    *names) ~ ")" : ""), r.inside);
                        diagnostic.suggestion = nearestName(r.name, *names);
                        found ~= diagnostic;
                    }
                }
            }
            if (r.kind == "relation") {
                bool local = r.name in localRelations || r.qualifier.length > 0;
                // relation-arity: a use that disagrees with the declaration.
                // `set`, `adjust` and a key-only `delete` name fewer columns by design.
                if (!local && r.role != "update")
                    if (auto arity = r.name in declaredArity)
                        if (r.arity >= 0 && r.arity != *arity) {
                            auto diagnostic = at("error", "relation-arity", r.file, r.range, "relation " ~ r.name ~ " has "
                                    ~ numberText(
                                        *arity) ~ " column(s) (declared at " ~ declaredAt[r.name] ~ ") but is used with "
                                    ~ numberText(r.arity), r.inside.length ? r.inside : "relation " ~ r.name);
                            found ~= diagnostic;
                        }
                // unknown-relation: read, never declared, asserted or derived.
                if (!local && (r.role == "read" || r.role == "negated") && r.name !in relationKnown) {
                    auto diagnostic = at("warning", "unknown-relation", r.file, r.range, "relation " ~ r.name
                            ~ " is read here but nothing in the project declares, asserts or derives it",
                            r.inside.length ? r.inside : "relation " ~ r.name);
                    diagnostic.suggestion = nearestName(r.name, topLevelNames);
                    found ~= diagnostic;
                }
            }
            // unknown-quality: only when every quality.define is statically known.
            if (r.kind == "quality" && !computedQuality && r.name !in qualities) {
                auto diagnostic = at("warning", "unknown-quality", r.file, r.range, "quality :" ~ r.name
                        ~ " is never defined by quality.define", r.inside.length ? r.inside : "quality :" ~ r.name);
                diagnostic.suggestion = nearestName(r.name, qualityNames);
                found ~= diagnostic;
            }
        }
    }
}

private string numberText(long value) {
    import core.stdc.stdio : snprintf;

    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}

/// Everything a project-wide check finds in the files that parsed: the static checks, text built
/// by code, and symbols written once (the likely typos).
void projectChecks(ref const ProjectIndex index, ref Diagnostic[] problems, const(string)[] declared = null,
        bool strictSymbols = false) {
    staticChecks(index, problems);
    // Display text built by code cannot be extracted for translation.
    foreach (ref f; index.files)
        foreach (ref m; f.messages)
            if (m.computed)
                problems ~= makeDiagnostic("warning", "computed-text", m.file, m.range.line, m.range.column, m.range.endLine,
                        m.range.endColumn, "display text built by code cannot be extracted for translation", m.owner);
    // Strict once the manifest lists `symbols` or any file declares some (`symbols a, b`).
    bool declaredInSource;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            declaredInSource = declaredInSource || d.kind == "symbols";
    if (strictSymbols || declaredInSource) {
        declaredSymbolChecks(index, declared, problems);
        return;
    }
    // A symbol that appears once cannot connect two things: nothing else mentions it.
    struct SymbolUse {
        string file;
        Range range;
        size_t count;
    }

    SymbolUse[string] symbolUses;
    bool[string] identifiers;
    foreach (ref f; index.files) {
        foreach (name, _; f.identifiers)
            identifiers[name] = true;
        foreach (ref r; f.references) {
            if (r.kind != "symbol" || r.role == "engine")
                continue;
            if (auto known = r.name in symbolUses)
                known.count++;
            else
                symbolUses[r.name] = SymbolUse(r.file, r.range, 1);
        }
    }
    // Names a typo is likely to have meant: symbols used more than once, and declared names.
    string[] familiar;
    foreach (name, use; symbolUses)
        if (use.count > 1)
            familiar ~= name;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.kind != "choice" && d.name.length)
                familiar ~= d.name;
    string[] once;
    foreach (name, use; symbolUses)
        if (use.count == 1 && name !in identifiers)
            once ~= name;
    // Sorted, so that output does not depend on hash order.
    foreach (i; 1 .. once.length) {
        auto item = once[i];
        size_t j = i;
        while (j > 0 && once[j - 1] > item) {
            once[j] = once[j - 1];
            --j;
        }
        once[j] = item;
    }
    foreach (name; once) {
        auto use = symbolUses[name];
        auto diagnostic = makeDiagnostic("warning", "symbol-once", use.file, use.range.line, use.range.column,
                use.range.endLine, use.range.endColumn, "symbol :" ~ name ~ " appears only here; is it misspelled?",
                "symbol :" ~ name);
        diagnostic.suggestion = nearestName(name, familiar);
        // A symbol another check already names (an unknown quality) is not reported twice.
        bool covered;
        foreach (ref other; problems)
            if (other.file == diagnostic.file && other.line == diagnostic.line && other.column == diagnostic.column)
                covered = true;
        if (!covered)
            problems ~= diagnostic;
    }
}

/// A source text's plurals use the categories of the project's language (`language` in the
/// manifest, English by default): an English text has `one` and `other`, a Russian one four.
void pluralChecks(ref const ProjectIndex index, string language, ref Diagnostic[] found) {
    import varis.narrative.plural : pluralCategoryAllowed, requiredPluralCategories;
    import varis.narrative.translation : parseTranslation, TranslationTemplate;

    foreach (ref f; index.files)
        foreach (ref m; f.messages) {
            if (m.computed || m.text.indexOf("{#plural") < 0)
                continue;
            TranslationTemplate parsed;
            string error;
            if (!parseTranslation(m.text, parsed, error))
                continue; // the load pass says so, with the engine's words
            foreach (g, kind; parsed.choiceKinds) {
                if (kind != "plural")
                    continue;
                auto labels = parsed.choiceLabels[g];
                foreach (label; labels)
                    if (!pluralCategoryAllowed(language, label))
                        found ~= makeDiagnostic("error", "plural-category", m.file, m.range.line, m.range.column, m.range.endLine,
                                m.range.endColumn, m.owner ~ ": {#" ~ label ~ "} is not a plural category of " ~ language
                                ~ ", the language of the text", m.owner);
                foreach (needed; requiredPluralCategories(language)) {
                    if (needed == "other")
                        continue;
                    bool present;
                    foreach (label; labels)
                        if (label == needed)
                            present = true;
                    if (!present)
                        found ~= makeDiagnostic("error", "plural-category", m.file, m.range.line, m.range.column,
                                m.range.endLine, m.range.endColumn, m.owner ~ ": a plural in " ~ language ~ " needs {#"
                                ~ needed ~ "} (and {#other})", m.owner);
                }
            }
        }
}

private int indexOf(string text, string needle) {
    if (needle.length > text.length)
        return -1;
    foreach (i; 0 .. text.length - needle.length + 1)
        if (text[i .. i + needle.length] == needle)
            return cast(int) i;
    return -1;
}

/// Every name a project declares: the manifest's `symbols`, `symbols a, b` statements and the
/// names of declarations (storylet, action, deck, relation, quality, name, choice).
void knownSymbols(ref const ProjectIndex index, const(string)[] declared, out bool[string] known,
        out string[] candidates) {
    foreach (name; declared)
        known[name] = true;
    candidates = declared.dup;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.name.length && d.kind != "function" && d.kind != "local-function" && d.kind != "label") {
                known[d.name] = true;
                candidates ~= d.name;
            }
}

/// With a `symbols` list in the manifest, a symbol is an error unless it is listed or named by a
/// declaration (storylet, action, deck, relation, quality, name, choice): a mistyped `:keepr` is
/// then an error at its place, not a storylet that silently never appears. Opt-in, no new syntax
/// (ROADMAP milestone 28's "declared entities/symbols", in its smallest reversible form).
void declaredSymbolChecks(ref const ProjectIndex index, const(string)[] declared, ref Diagnostic[] problems) {
    bool[string] known;
    string[] candidates;
    knownSymbols(index, declared, known, candidates);
    bool[string] reported;
    foreach (ref f; index.files)
        foreach (ref r; f.references) {
            if (r.kind != "symbol" || r.role == "engine" || r.name in known)
                continue;
            auto diagnostic = makeDiagnostic("error", "undeclared-symbol", r.file, r.range.line, r.range.column, r.range.endLine,
                    r.range.endColumn, "symbol :" ~ r.name ~ " is not declared: list it with `symbols " ~ r.name ~ "` (or in "
                    ~ "`symbols` of the manifest), or declare the storylet, relation, quality or deck it names", "symbol :" ~ r
                    .name);
            diagnostic.suggestion = nearestName(r.name, candidates);
            problems ~= diagnostic;
        }
}
