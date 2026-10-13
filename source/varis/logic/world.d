/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.logic.world;

import varis.types;
import varis.table;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.store : FactTable, engineCounters;
import std.format : format;
import std.conv : to;
import core.thread : Fiber;
import varis.fiber : VarisFiber, currentLuaFiber;
public import varis.fiber : beginNoYieldScope, endNoYieldScope, isNoYieldScope, beginNotificationDispatch,
    endNotificationDispatch, isNotificationDispatch, beginReadOnlyEvaluation, endReadOnlyEvaluation, isReadOnlyEvaluation;
import varis.state : LuaState, stateCreatedHooks, FrameScope;

// The Lua core keeps the world model's per-state objects as opaque references (see
// LuaState.globalWorldObject); these accessors give them their types back. They are found by
// UFCS, so `state.globalWorld` and `state.callWorld = w` read as before.

/// The state's global world (`logic.global`).
World globalWorld(LuaState state) {
    return cast(World) cast(void*) state.globalWorldObject;
}

/// ditto
void globalWorld(LuaState state, World world) {
    state.globalWorldObject = world;
}

/// The lexical world of the call in progress.
World callWorld(LuaState state) {
    return cast(World) cast(void*) state.callWorldObject;
}

/// ditto
void callWorld(LuaState state, World world) {
    state.callWorldObject = world;
}

/// Hook that prepares a newly created world (set by the quality library). Returns null, or the
/// message of the problem that makes the world unusable.
ref string delegate(World) configureWorld(LuaState state) {
    auto holder = cast(WorldConfiguration) cast(void*) state.worldConfigurationObject;
    if (holder is null) {
        holder = new WorldConfiguration;
        state.worldConfigurationObject = holder;
    }
    return holder.configure;
}

private final class WorldConfiguration {
    string delegate(World) configure;
}

shared static this() {
    // Every state owns a global world from the moment it exists.
    stateCreatedHooks ~= (LuaState state) { state.globalWorldObject = new World(); };
}

private size_t g_nextRelId = 1;
private size_t g_nextWorldId = 1;
private size_t g_nextRuleId = 1;

size_t getNextRuleId() {
    return g_nextRuleId++;
}

/// Transaction state is coroutine-specific; overlays never modify committed relations.
private Transaction[Fiber] activeTransactions;
Transaction currentTransaction() {
    return activeTransactions.get(Fiber.getThis(), null);
}

void checkMutationWorld(World world) {
    if (world.notifyingDepth)
        throw new LuaException("cannot mutate notifying world from an observer callback");
    if (world.readOnlyDepth || isReadOnlyEvaluation())
        throw new LuaException("world mutation prohibited during read-only narrative evaluation");
    auto transaction = currentTransaction();
    if (world.transactionOwner !is null && world.transactionOwner !is transaction && (transaction is null || transaction
            .world !is world))
        throw new LuaException("world is locked by another transaction");
    if (transaction !is null && transaction.world !is world)
        throw new LuaException("cross-world mutation during a transaction");
}

void prohibitProgramChange() {
    if (isReadOnlyEvaluation())
        throw new LuaException("program registration prohibited during read-only narrative evaluation");
    if (currentTransaction() !is null)
        throw new LuaException("schema and rule registration prohibited during a transaction");
}

/// A participant stages its state alongside facts and nested savepoints.
abstract class TransactionParticipant {
    abstract Object committedState();
    abstract Object copyState(Object state);
    abstract void prepareCommit(Transaction transaction, Object state);
    abstract void publishState(Object state);
}

class Transaction : FrameScope {
    World world;
    Transaction parent;
    Relation[Relation] overlays;
    Object[TransactionParticipant] participants;
    void delegate()[] afterCommit;
    void delegate()[] invalidateIterators;
    VarisFiber fiber;
    bool previousYieldAllowed;
    bool finished;

    this(World world) {
        parent = currentTransaction();
        if (parent !is null && parent.world !is world)
            throw new LuaException("nested transaction must use the same world");
        checkMutationWorld(world);
        if (world.transactionOwner !is null && parent is null)
            throw new LuaException("world is locked by another transaction");
        this.world = world;
        if (parent is null)
            world.transactionOwner = this;
        fiber = currentLuaFiber();
        if (fiber !is null) {
            previousYieldAllowed = fiber.isYieldAllowed;
            fiber.isYieldAllowed = false;
        }
        activeTransactions[Fiber.getThis()] = this;
        beginNoYieldScope();
    }

    Relation read(Relation original) {
        if (auto entry = original in overlays)
            return *entry;
        return parent !is null ? parent.read(original) : original;
    }

    Relation write(Relation original) {
        if (auto entry = original in overlays)
            return *entry;
        auto source = read(original);
        auto copy = new Relation(original.id, original.name, original.arity);
        copy.protectedRelation = source.protectedRelation;
        copy.validateTuple = source.validateTuple;
        copy.clampTuple = source.clampTuple;
        copy.columns = source.columns.dup;
        copy.keyColumns = source.keyColumns.dup;
        copy.baseFacts = source.baseFacts.dup;
        copy.keyIndex = source.keyIndex.dup;
        copy.rules = source.rules.dup;
        copy.version_ = source.version_;
        overlays[original] = copy;
        return copy;
    }

    Object readParticipant(TransactionParticipant participant) {
        if (auto state = participant in participants)
            return *state;
        return parent !is null ? parent.readParticipant(participant) : participant.committedState();
    }

    Object writeParticipant(TransactionParticipant participant) {
        if (auto state = participant in participants)
            return *state;
        auto copy = participant.copyState(readParticipant(participant));
        participants[participant] = copy;
        return copy;
    }

    void finish(bool commit) {
        bool publishedFacts;
        if (finished)
            return;
        assert(currentTransaction() is this);
        if (commit) {
            if (parent !is null) {
                foreach (original, copy; overlays)
                    parent.overlays[original] = copy;
                parent.invalidateIterators ~= invalidateIterators;
                foreach (participant, value; participants)
                    parent.participants[participant] = value;
                parent.afterCommit ~= afterCommit;
            } else {
                // Prepare all participants before any state is published.
                foreach (participant, value; participants)
                    participant.prepareCommit(this, value);
                bool changed;
                foreach (original, copy; overlays) {
                    if (original.version_ == copy.version_)
                        continue;
                    original.adoptFacts(copy);
                    changed = true;
                }
                if (changed) {
                    world.version_++;
                    publishedFacts = true;
                }
                foreach (participant, value; participants)
                    participant.publishState(value);
            }
        } else
            foreach (invalidate; invalidateIterators)
                invalidate();
        if (parent is null)
            world.transactionOwner = null;
        if (parent is null)
            activeTransactions.remove(Fiber.getThis());
        else
            activeTransactions[Fiber.getThis()] = parent;
        if (fiber !is null)
            fiber.isYieldAllowed = previousYieldAllowed;
        finished = true;
        endNoYieldScope();
        if (commit && parent is null) {
            // Observers and deferred callbacks see the fully published state.
            // Finish all callbacks even if one fails; report the first error.
            Exception firstError;
            if (publishedFacts)
                try {
                    world.notifyCommittedChange();
                } catch (Exception error) {
                    firstError = error;
                }
            foreach (callback; afterCommit)
                try {
                    callback();
                } catch (Exception error) {
                    if (firstError is null)
                        firstError = error;
                }
            if (firstError !is null)
                throw firstError;
        }
    }
}

Relation visibleRelation(Relation relation) {
    auto transaction = currentTransaction();
    if (transaction !is null && relation.ownerWorld is transaction.world)
        return transaction.read(relation);
    return relation;
}

/// A relation instance owned by a world or local scope
class Relation {
    size_t id;
    string name;
    int arity;
    World ownerWorld; // null if local relation
    bool[RelTuple] baseFacts;
    /// `baseFacts` and `keyIndex` are shared with another relation (a world snapshot): copy before
    /// the first write. Both sharers carry the flag.
    bool factsShared;
    /// Immutable table of the base facts, built on demand and shared with snapshots and queries.
    private FactTable cachedTable;
    /// Set on a query's snapshot relation: the facts as they were at query construction.
    FactTable frozenTable;
    Rule[] rules;
    string[] columns;
    size_t[] keyColumns;
    RelTuple[RelTuple] keyIndex;
    ulong version_ = 1;
    bool isLocal = false;
    bool protectedRelation;
    void delegate(RelTuple) validateTuple;
    /// Saturates a tuple at declared bounds (quality only); null where bounds are not supported.
    RelTuple delegate(RelTuple) clampTuple;

    this(size_t id, string name, int arity, World ownerWorld = null, bool isLocal = false) {
        this.id = id;
        this.name = name;
        this.arity = arity;
        this.ownerWorld = ownerWorld;
        this.isLocal = isLocal;
        this.version_ = 1;
    }

    /// The base facts as an immutable table. It is rebuilt only after the facts changed, so
    /// queries, snapshots and worlds cloned from this one share it instead of copying facts.
    FactTable factTable() {
        if (frozenTable !is null)
            return frozenTable;
        // Every write goes through ownFacts/adoptFacts/clearFacts, which drop the table. The length
        // test is a second line of defence for code that fills `baseFacts` directly after clearFacts.
        if (cachedTable is null || cachedTable.rows.length != baseFacts.length) {
            cachedTable = FactTable.frozenFrom(baseFacts.keys, arity);
            engineCounters.tableRows += cachedTable.rows.length;
        }
        return cachedTable;
    }

    /// Transaction commit: take over the overlay's facts (the overlay is not used afterwards).
    void adoptFacts(Relation overlay) {
        baseFacts = overlay.baseFacts;
        keyIndex = overlay.keyIndex;
        factsShared = overlay.factsShared;
        version_ = overlay.version_;
        cachedTable = null;
    }

    /// Discards all base facts (restore paths that refill the relation directly).
    void clearFacts() {
        baseFacts = null;
        factsShared = false;
        cachedTable = null;
    }

    /// Called before every write to `baseFacts` or `keyIndex`.
    private void ownFacts() {
        if (factsShared) {
            engineCounters.factsCopied += baseFacts.length;
            baseFacts = baseFacts.dup;
            keyIndex = keyIndex.dup;
            factsShared = false;
        }
        cachedTable = null;
    }

    RelTuple tupleKey(RelTuple tuple) {
        LuaValue[] values;
        foreach (column; keyColumns)
            values ~= tuple.values[column];
        return RelTuple(values);
    }

    void requireKey(RelTuple key) {
        if (keyColumns.length == 0)
            throw new LuaException(format("relation '%s' is not keyed", name));
        if (key.length != keyColumns.length)
            throw new LuaException(format("relation '%s' expects %d key arguments, got %d", name, keyColumns.length, key
                    .length));
    }

    bool setFact(RelTuple tuple) {
        if (protectedRelation)
            throw new LuaException("cannot modify read-only relation '" ~ name ~ "'");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction())
                return transaction.write(this).setFact(tuple);
        } else if (isLocal && currentTransaction() !is null) {
            throw new LuaException("local relation mutation prohibited during a transaction");
        }
        if (tuple.length != cast(size_t) arity)
            throw new LuaException(format("relation '%s' expects arity %d, got %d", name, arity, tuple.length));
        if (validateTuple !is null)
            validateTuple(tuple);
        auto key = tupleKey(tuple);
        requireKey(key);
        if (auto old = key in keyIndex) {
            if (*old == tuple)
                return false;
            ownFacts();
            baseFacts.remove(*(key in keyIndex));
        }
        ownFacts();
        keyIndex[key] = tuple;
        baseFacts[tuple] = true;
        version_++;
        return true;
    }

    bool deleteKey(RelTuple key) {
        if (protectedRelation)
            throw new LuaException("cannot modify read-only relation '" ~ name ~ "'");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction())
                return transaction.write(this).deleteKey(key);
        } else if (isLocal && currentTransaction() !is null) {
            throw new LuaException("local relation mutation prohibited during a transaction");
        }
        requireKey(key);
        if (auto old = key in keyIndex)
            return retractFact(*old);
        return false;
    }

    bool adjustKey(RelTuple key, LuaValue delta, bool clamp = false) {
        if (protectedRelation)
            throw new LuaException("cannot modify read-only relation '" ~ name ~ "'");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction())
                return transaction.write(this).adjustKey(key, delta, clamp);
        } else if (isLocal && currentTransaction() !is null) {
            throw new LuaException("local relation mutation prohibited during a transaction");
        }
        requireKey(key);
        if (arity != keyColumns.length + 1)
            throw new LuaException(format("relation '%s' requires exactly one non-key column for adjust", name));
        auto old = key in keyIndex;
        if (old is null)
            throw new LuaException(format("relation '%s': adjust key is absent", name));
        size_t valueColumn;
        foreach (i; 0 .. cast(size_t) arity) {
            bool isKey;
            foreach (k; keyColumns)
                if (k == i)
                    isKey = true;
            if (!isKey)
                valueColumn = i;
        }
        auto value = old.values[valueColumn];
        if ((!isInteger(value) && !isFloat(value)) || (!isInteger(delta) && !isFloat(delta)))
            throw new LuaException(format("relation '%s': adjust requires numeric values", name));
        auto values = old.values.dup;
        if (isInteger(value) && isInteger(delta)) {
            values[valueColumn] = LuaValue(value.match!((long x) => x, _ => 0L) + delta.match!((long x) => x, _ => 0L));
        } else {
            double number(LuaValue v) {
                return v.match!((long x) => cast(double) x, (double x) => x, _ => 0.0);
            }

            values[valueColumn] = LuaValue(number(value) + number(delta));
        }
        if (clamp) {
            if (clampTuple is null)
                throw new LuaException(format("relation '%s' has no declared bounds to clamp to", name));
            return setFact(clampTuple(RelTuple(values)));
        }
        return setFact(RelTuple(values));
    }

    /// Add a base fact. Returns true if newly inserted, false if duplicate.
    bool addFact(RelTuple tuple) {
        if (protectedRelation)
            throw new LuaException("cannot modify read-only relation '" ~ name ~ "'");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction())
                return transaction.write(this).addFact(tuple);
        } else if (isLocal && currentTransaction() !is null) {
            throw new LuaException("local relation mutation prohibited during a transaction");
        }
        if (tuple.length != cast(size_t) arity) {
            throw new LuaException(format("relation '%s' expects arity %d, got %d", name, arity, tuple.length));
        }
        if (validateTuple !is null)
            validateTuple(tuple);
        if (tuple in baseFacts) {
            return false;
        }
        if (keyColumns.length) {
            auto key = tupleKey(tuple);
            if (key in keyIndex)
                throw new LuaException(format("relation '%s': conflicting fact for existing key", name));
            ownFacts();
            keyIndex[key] = tuple;
        }
        ownFacts();
        baseFacts[tuple] = true;
        version_++;
        return true;
    }

    /// Retract a base fact. Returns true if removed, false if not found.
    bool retractFact(RelTuple tuple) {
        if (protectedRelation)
            throw new LuaException("cannot modify read-only relation '" ~ name ~ "'");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction())
                return transaction.write(this).retractFact(tuple);
        } else if (isLocal && currentTransaction() !is null) {
            throw new LuaException("local relation mutation prohibited during a transaction");
        }
        if (tuple.length != cast(size_t) arity) {
            throw new LuaException(format("relation '%s' expects arity %d, got %d", name, arity, tuple.length));
        }
        if (tuple in baseFacts) {
            ownFacts();
            if (keyColumns.length)
                keyIndex.remove(tupleKey(tuple));
            baseFacts.remove(tuple);
            version_++;
            return true;
        }
        return false;
    }

    /// Engine-only append used by committed session history publication.
    void appendSystemFact(RelTuple tuple) {
        if (tuple.length != arity)
            throw new LuaException("invalid system tuple arity");
        if (ownerWorld !is null) {
            checkMutationWorld(ownerWorld);
            if (auto transaction = currentTransaction()) {
                transaction.write(this).appendSystemFact(tuple);
                return;
            }
        }
        if (tuple !in baseFacts) {
            ownFacts();
            baseFacts[tuple] = true;
            version_++;
        }
    }

    /// Add a rule definition
    void addRule(Rule r) {
        if (ownerWorld !is null)
            checkMutationWorld(ownerWorld);
        prohibitProgramChange();
        if (protectedRelation)
            throw new LuaException("read-only relation cannot be a rule head: " ~ name);
        if (keyColumns.length)
            throw new LuaException(format("keyed relation '%s' cannot be a rule head", name));
        rules ~= r;
        version_++;
    }

    /// Clone relation for a new world
    Relation cloneForWorld(World newOwner) {
        auto clone = new Relation(g_nextRelId++, name, arity, newOwner, isLocal);
        clone.protectedRelation = protectedRelation;
        clone.validateTuple = validateTuple;
        clone.clampTuple = clampTuple;
        clone.columns = columns.dup;
        clone.keyColumns = keyColumns.dup;
        // Share the fact set; whichever side writes first makes its own copy (see ownFacts).
        clone.keyIndex = keyIndex;
        clone.baseFacts = baseFacts;
        clone.factsShared = factsShared = baseFacts !is null || keyIndex !is null;
        clone.version_ = this.version_;
        clone.cachedTable = factTable();
        return clone;
    }
}

/// The base facts of a world at one moment (see `World.captureFacts`).
final class FactSnapshot {
    struct Entry {
        Relation relation;
        bool[RelTuple] baseFacts;
        RelTuple[RelTuple] keyIndex;
        ulong version_;
    }

    Entry[] entries;
    ulong worldVersion;
}

/// A logical world containing named relations, base facts, and rules
class World {
    size_t readOnlyDepth;
    size_t notifyingDepth;
    void delegate() committedChange;
    Object observerState;
    void notifyCommittedChange() {
        if (committedChange !is null)
            committedChange();
    }

    Transaction transactionOwner;
    Object narrativeOwner;
    private string idText_;

    /// `id` as text (the world qualifier of relation references), computed once.
    string idText() {
        if (idText_.length == 0)
            idText_ = id.to!string;
        return idText_;
    }

    string persistentIdentity;
    string narrativeProgramVersion;
    string narrativeProgramFingerprint;
    size_t id;
    ulong version_ = 1;
    Relation[string] relations;
    Rule[] rules;

    this(size_t id = 0) {
        this.id = (id > 0) ? id : g_nextWorldId++;
        this.version_ = 1;
    }

    /// Explicit relation declaration
    Relation declareRelation(string name, int arity) {
        checkMutationWorld(this);
        prohibitProgramChange();
        if (arity < 0) {
            throw new LuaException("relation arity must be nonnegative");
        }
        if (auto p = name in relations) {
            if (p.arity != arity) {
                throw new LuaException(format("relation '%s' already declared with arity %d, got %d", name, p.arity, arity));
            }
            return *p;
        }
        auto rel = new Relation(g_nextRelId++, name, arity, this, false);
        relations[name] = rel;
        version_++;
        return rel;
    }

    Relation declareNamedRelation(string name, string[] columns, string[] keys) {
        checkMutationWorld(this);
        prohibitProgramChange();
        bool[string] seen;
        foreach (column; columns) {
            if (column in seen)
                throw new LuaException(format("relation '%s': duplicate column '%s'", name, column));
            seen[column] = true;
        }
        size_t[] indices;
        bool[string] seenKeys;
        foreach (key; keys) {
            if (key in seenKeys)
                throw new LuaException(format("relation '%s': duplicate key column '%s'", name, key));
            seenKeys[key] = true;
            bool found;
            foreach (i, column; columns)
                if (column == key) {
                    indices ~= i;
                    found = true;
                }
            if (!found)
                throw new LuaException(format("relation '%s': unknown key column '%s'", name, key));
        }
        if (auto existing = getRelation(name)) {
            if (existing.arity != cast(int) columns.length || existing.columns != columns || existing.keyColumns != indices)
                throw new LuaException(format("relation '%s': conflicting schema redeclaration", name));
            return existing;
        }
        auto relation = new Relation(g_nextRelId++, name, cast(int) columns.length, this);
        relation.columns = columns.dup;
        relation.keyColumns = indices;
        relations[name] = relation;
        version_++;
        return relation;
    }

    bool updateFact(string name, RelTuple arguments, string operation, LuaValue delta = LuaValue.init,
            bool clamp = false) {
        checkMutationWorld(this);
        auto relation = getRelation(name);
        if (relation is null)
            throw new LuaException(format("unknown relation '%s'", name));
        bool changed;
        switch (operation) {
        case "set":
            changed = relation.setFact(arguments);
            break;
        case "delete":
            changed = relation.deleteKey(arguments);
            break;
        case "adjust":
            changed = relation.adjustKey(arguments, delta, clamp);
            break;
        default:
            throw new LuaException("unknown relation update");
        }
        if (changed && currentTransaction() is null) {
            version_++;
            notifyCommittedChange();
        }
        return changed;
    }

    /// Get existing relation by name
    Relation getRelation(string name) {
        if (auto p = name in relations) {
            return *p;
        }
        return null;
    }

    /// Get or create relation implicitly with given arity
    Relation getOrCreateRelation(string name, int arity) {
        if (auto p = name in relations) {
            if (p.arity != arity) {
                throw new LuaException(format("relation '%s' expects arity %d, got %d", name, p.arity, arity));
            }
            return *p;
        }
        return declareRelation(name, arity);
    }

    /// Insert a base fact atomically
    bool addFact(string name, RelTuple tuple) {
        checkMutationWorld(this);
        auto rel = getOrCreateRelation(name, cast(int) tuple.length);
        if (rel.addFact(tuple)) {
            if (currentTransaction() is null) {
                version_++;
                notifyCommittedChange();
            }
            return true;
        }
        return false;
    }

    /// Retract a base fact atomically
    bool retractFact(string name, RelTuple tuple) {
        checkMutationWorld(this);
        auto rel = getRelation(name);
        if (rel is null) {
            // Unknown relation: no-op per Milestone 0 specification
            return false;
        }
        if (rel.retractFact(tuple)) {
            if (currentTransaction() is null) {
                version_++;
                notifyCommittedChange();
            }
            return true;
        }
        return false;
    }

    /// Register a validated rule into this world
    void registerRule(Rule rule) {
        checkMutationWorld(this);
        prohibitProgramChange();
        // Ensure head relation exists
        auto head = getOrCreateRelation(rule.headRel.name, rule.headRel.arity);
        if (head.keyColumns.length)
            throw new LuaException(format("keyed relation '%s' cannot be a rule head", head.name));
        if (head.protectedRelation)
            throw new LuaException("read-only relation cannot be a rule head: " ~ head.name);
        rules ~= rule;
        rule.headRel.relId = head.id;
        head.addRule(rule);
        version_++;
        notifyCommittedChange();
    }

    /// Captures the base facts of every relation so `restoreFacts` can put them back in place
    /// (session undo). Fact sets are shared copy-on-write, so a capture costs one copy per
    /// relation that is written afterwards, not a copy of the world.
    FactSnapshot captureFacts() {
        if (transactionOwner !is null)
            throw new LuaException("cannot capture facts during a transaction");
        auto snapshot = new FactSnapshot;
        snapshot.worldVersion = version_;
        foreach (relation; relations.values) {
            relation.factsShared = true;
            snapshot.entries ~= FactSnapshot.Entry(relation, relation.baseFacts, relation.keyIndex, relation.version_);
        }
        return snapshot;
    }

    /// Puts back the facts of a capture. Versions only move forward, so a version number never
    /// names two different states. Rules, schemas and relations declared since are untouched.
    void restoreFacts(FactSnapshot snapshot) {
        if (transactionOwner !is null)
            throw new LuaException("cannot restore facts during a transaction");
        bool changed;
        foreach (entry; snapshot.entries) {
            auto relation = entry.relation;
            // A version only moves when facts are written: an equal one means nothing changed.
            if (relation.version_ == entry.version_)
                continue;
            changed = true;
            relation.baseFacts = entry.baseFacts;
            relation.keyIndex = entry.keyIndex;
            relation.factsShared = true;
            relation.cachedTable = null;
            relation.version_ = (relation.version_ > entry.version_ ? relation.version_ : entry.version_) + 1;
        }
        if (!changed && version_ == snapshot.worldVersion)
            return;
        version_ = (version_ > snapshot.worldVersion ? version_ : snapshot.worldVersion) + 1;
        notifyCommittedChange();
    }

    /// Create snapshot child world inheriting parent state
    World cloneSnapshot() {
        auto child = new World(g_nextWorldId++);
        child.narrativeProgramVersion = narrativeProgramVersion;
        child.narrativeProgramFingerprint = narrativeProgramFingerprint;
        // Clone relations and base facts
        foreach (name, rel; relations) {
            child.relations[name] = visibleRelation(rel).cloneForWorld(child);
        }

        // Rebind and clone rules
        foreach (rule; rules) {
            auto headCloneRel = child.relations.get(rule.headRel.name, null);
            if (headCloneRel is null)
                continue;

            auto reboundHeadRef = new RelationRef(rule.headRel.name, rule.headRel.arity, child.idText, headCloneRel
                    .id);
            reboundHeadRef.resolvedRelation = headCloneRel;

            Goal[] rebound(Goal[] goals) {
                Goal[] reboundGoals;
                foreach (g; goals) {
                    auto newGoal = new Goal(g.kind);
                    if (g.relRef !is null) {
                        auto targetRel = child.relations.get(g.relRef.name, null);
                        size_t targetId = targetRel ? targetRel.id : g.relRef.relId;
                        newGoal.relRef = new RelationRef(g.relRef.name, g.relRef.arity, child.idText, targetId);
                        newGoal.relRef.resolvedRelation = targetRel;
                        newGoal.terms = g.terms.dup;
                    } else if (g.kind == GoalKind.Comparison) {
                        newGoal.leftTerm = g.leftTerm;
                        newGoal.compOp = g.compOp;
                        newGoal.rightTerm = g.rightTerm;
                    } else if (g.kind == GoalKind.Aggregate) {
                        newGoal.aggregateOp = g.aggregateOp;
                        newGoal.resultVariable = g.resultVariable;
                        newGoal.aggregateGoals = rebound(g.aggregateGoals);
                        newGoal.aggregateInputs = g.aggregateInputs.dup;
                        newGoal.aggregateLocals = g.aggregateLocals.dup;
                        newGoal.aggregateExpression = g.aggregateExpression;
                        newGoal.aggregateExpressionVariables = g.aggregateExpressionVariables.dup;
                    } else if (g.kind == GoalKind.Guard) {
                        newGoal.guardFn = g.guardFn;
                        newGoal.guardVarNames = g.guardVarNames.dup;
                        newGoal.guardVarIds = g.guardVarIds.dup;
                    }
                    reboundGoals ~= newGoal;
                }

                return reboundGoals;
            }

            auto reboundGoals = rebound(rule.bodyGoals);

            auto reboundRule = new Rule(reboundHeadRef, rule.headTerms.dup, reboundGoals, g_nextRuleId++);
            reboundRule.origin = rule.origin is null ? rule : rule.origin;
            reboundRule.numVariables = rule.numVariables;
            reboundRule.variableNames = rule.variableNames.dup;

            child.rules ~= reboundRule;
            headCloneRel.rules ~= reboundRule;
            headCloneRel.version_++;
        }

        child.version_ = 1;
        return child;
    }
}

/// Stage implicit declarations until rule validation succeeds. No world versions
/// or namespaces change while building and checking the candidate rule.
class RuleRegistration {
    Relation[string][World] pending;

    Relation resolve(World world, string name, int arity) {
        prohibitProgramChange();
        auto relation = world.getRelation(name);
        if (relation is null)
            relation = pending.get(world, null).get(name, null);
        if (relation !is null) {
            if (relation.arity != arity) {
                throw new LuaException(format("relation '%s' expects arity %d, got %d", name, relation.arity, arity));
            }
            return relation;
        }
        relation = new Relation(g_nextRelId++, name, arity, world);
        pending[world][name] = relation;
        return relation;
    }

    void commit() {
        prohibitProgramChange();
        foreach (world, declarations; pending)
            checkMutationWorld(world);
        foreach (world, declarations; pending) {
            foreach (name, relation; declarations) {
                world.relations[name] = relation;
                world.version_++;
            }
        }
    }
}

/// Include live rule dependencies when validating a local relation graph.
/// The relation map doubles as the visited set for recursive references.
void collectRuleDependencies(Relation relation, ref Relation[size_t] relations, ref Rule[] rules) {
    if (relation is null || relation.id in relations)
        return;
    relations[relation.id] = relation;
    foreach (rule; relation.rules) {
        rules ~= rule;
        foreach (goal; flattenGoals(rule.bodyGoals)) {
            if (goal.relRef !is null) {
                collectRuleDependencies(goal.relRef.resolvedRelation, relations, rules);
            }
        }
    }
}

/// A lexically scoped local relation
class LocalRelation {
    Relation relation;
    World fallbackWorld;

    this(string name, int arity, World fallbackWorld) {
        prohibitProgramChange();
        this.fallbackWorld = fallbackWorld;
        this.relation = new Relation(g_nextRelId++, name, arity, null, true);
    }

    size_t id() const {
        return relation.id;
    }

    string name() const {
        return relation.name;
    }

    int arity() const {
        return relation.arity;
    }

    ulong version_() const {
        return relation.version_;
    }

    bool addFact(RelTuple tuple) {
        return relation.addFact(tuple);
    }

    bool retractFact(RelTuple tuple) {
        return relation.retractFact(tuple);
    }

    void registerRule(Rule rule) {
        prohibitProgramChange();
        rule.headRel.relId = relation.id;
        relation.addRule(rule);
    }
}

/// Wrap a World instance into a LuaUserData object
LuaValue wrapWorld(World w) {
    auto ud = new LuaUserData(w);
    return LuaValue(ud);
}

/// Unwrap a World instance from a LuaValue (or throw if not a world)
World unwrapWorld(LuaValue val) {
    if (val.typeOf() == LuaType.UserData) {
        auto ud = val.match!((LuaUserData u) => u, _ => null);
        if (ud !is null && ud.payload !is null) {
            if (auto w = cast(World) ud.payload) {
                return w;
            }
        }
    }
    throw new LuaException("expected world object");
}

/// Check if a LuaValue is a wrapped World
bool isWorld(LuaValue val) {
    if (val.typeOf() == LuaType.UserData) {
        auto ud = val.match!((LuaUserData u) => u, _ => null);
        if (ud !is null && ud.payload !is null) {
            return (cast(World) ud.payload) !is null;
        }
    }
    return false;
}

/// Wrap a LocalRelation instance into a LuaUserData object
LuaValue wrapLocalRelation(LocalRelation lr) {
    auto ud = new LuaUserData(lr);
    return LuaValue(ud);
}

/// Unwrap a LocalRelation instance from a LuaValue (or null if not local relation)
LocalRelation unwrapLocalRelation(LuaValue val) {
    if (val.typeOf() == LuaType.UserData) {
        auto ud = val.match!((LuaUserData u) => u, _ => null);
        if (ud !is null && ud.payload !is null) {
            return cast(LocalRelation) ud.payload;
        }
    }
    return null;
}

/// Check if a LuaValue is a wrapped LocalRelation
bool isLocalRelation(LuaValue val) {
    if (val.typeOf() == LuaType.UserData) {
        auto ud = val.match!((LuaUserData u) => u, _ => null);
        if (ud !is null && ud.payload !is null) {
            return (cast(LocalRelation) ud.payload) !is null;
        }
    }
    return false;
}
