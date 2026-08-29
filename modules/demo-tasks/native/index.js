// The native half of the demo module.
//
// What it demonstrates is the contract, not the to-do list. It receives a
// `siberian` bridge from the shell, calls its own API through it, and never
// learns a container name, a domain credential, or another module's anything.
//
// Every call goes to /m/demo-tasks/, which the Router turns into this module.
// The app has no origins, so that path, and the permission behind it, is the
// boundary.
//
// It reads the same rows the browser does and offers the same actions. A screen
// that can show a task as done but cannot mark one is not a smaller version of
// the feature, it is a picture of one: the phone is where most people will use
// this, so parity is the requirement rather than the ambition. What is missing
// is attaching a file, which needs a document picker, and it is absent rather
// than half present.
import React, { useCallback, useEffect, useMemo, useState } from "react";
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, TextInput, View } from "react-native";

// Everything this screen sends is JSON, so the module answers in kind rather
// than redirecting to a page a phone cannot render.
const JSON_HEADERS = { "Content-Type": "application/json", Accept: "application/json" };

export function TaskList({ siberian }) {
  const [tasks, setTasks] = useState(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState({});
  const [showArchived, setShowArchived] = useState(false);

  const theme = siberian.theme || {};
  const styles = useMemo(() => sheet(theme), [theme]);

  const load = useCallback(async () => {
    try {
      const query = showArchived ? "tasks.json?archived=1" : "tasks.json";
      const response = await siberian.call(query, { headers: JSON_HEADERS });
      if (!response.ok) throw new Error(`the module answered ${response.status}`);
      setTasks(await response.json());
      setError(null);
    } catch (problem) {
      // Said plainly rather than swallowed. A list that is empty because the
      // call failed looks exactly like a list that is empty.
      setError(problem.message);
      setTasks([]);
    }
  }, [siberian, showArchived]);

  useEffect(() => {
    load();
  }, [load]);

  // One place for every action, so each reports a failure the same way and none
  // of them leaves a row looking as though it worked.
  const act = async (id, path, options) => {
    setBusy((current) => ({ ...current, [id]: true }));
    try {
      const response = await siberian.call(path, { method: "POST", headers: JSON_HEADERS, ...options });
      if (!response.ok) throw new Error(`the module answered ${response.status}`);
      setError(null);
      await load();
    } catch (problem) {
      setError(problem.message);
      await load();
    } finally {
      setBusy((current) => ({ ...current, [id]: false }));
    }
  };

  const add = async () => {
    const title = draft.trim();
    if (!title) return;
    setDraft("");
    await act("new", "tasks", { body: JSON.stringify({ title }) });
  };

  // Optimistic, because a tick that waits for a round trip feels broken on a
  // phone. `load` puts the real answer back either way, including after a
  // failure, so the row never stays showing something that did not happen.
  const toggle = async (task) => {
    setTasks((current) => current.map((t) => (t.id === task.id ? { ...t, done: !t.done } : t)));
    await act(task.id, `tasks/${task.id}/toggle`);
  };

  const setArchived = (task, archived) =>
    act(task.id, `tasks/${task.id}/${archived ? "archive" : "unarchive"}`);

  const remove = (task) => act(task.id, `tasks/${task.id}/delete`);

  if (tasks === null) return <ActivityIndicator style={styles.centre} color={theme.accent} />;

  return (
    <View style={styles.fill}>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      {!showArchived ? (
        <View style={styles.composer}>
          <TextInput
            style={styles.input}
            value={draft}
            onChangeText={setDraft}
            placeholder="Add a task"
            placeholderTextColor={theme.muted}
            onSubmitEditing={add}
            returnKeyType="done"
          />
          <Pressable style={styles.add} onPress={add}>
            <Text style={styles.addLabel}>Add</Text>
          </Pressable>
        </View>
      ) : null}

      <Pressable onPress={() => setShowArchived((on) => !on)} style={styles.tab}>
        <Text style={styles.tabLabel}>{showArchived ? "Back to open tasks" : "Archived"}</Text>
      </Pressable>

      <FlatList
        data={tasks}
        keyExtractor={(task) => String(task.id)}
        ListEmptyComponent={
          <Text style={styles.empty}>{showArchived ? "Nothing archived." : "Nothing yet."}</Text>
        }
        renderItem={({ item }) => (
          <View style={[styles.row, busy[item.id] ? styles.rowBusy : null]}>
            {/* The whole label is the target. A tick box sized for a mouse is a
                miss on a phone. */}
            <Pressable style={styles.tickArea} onPress={() => toggle(item)} disabled={showArchived}>
              <View style={[styles.tick, item.done ? styles.tickOn : null]}>
                {item.done ? <Text style={styles.tickMark}>OK</Text> : null}
              </View>
              <View style={styles.titleArea}>
                <Text style={item.done ? styles.done : styles.title}>{item.title}</Text>
                {item.attachment ? <Text style={styles.meta}>{item.attachment}</Text> : null}
              </View>
            </Pressable>

            <Pressable
              onPress={() => setArchived(item, !showArchived)}
              style={styles.action}
            >
              <Text style={styles.actionLabel}>{showArchived ? "Restore" : "Archive"}</Text>
            </Pressable>

            {showArchived ? (
              <Pressable onPress={() => remove(item)} style={styles.action}>
                <Text style={styles.danger}>Delete</Text>
              </Pressable>
            ) : null}
          </View>
        )}
      />
    </View>
  );
}

// Built from the theme the shell passes rather than from fixed colours, so a
// native screen and the app around it are the same app.
const sheet = (t) =>
  StyleSheet.create({
    fill: { flex: 1, backgroundColor: t.background || "#ffffff" },
    centre: { marginTop: 32 },
    error: {
      margin: 12, padding: 10, borderRadius: 8,
      backgroundColor: t.dangerSurface || "#fee2e2", color: t.danger || "#b3261e", fontSize: 13
    },
    composer: { flexDirection: "row", gap: 8, padding: 12 },
    input: {
      flex: 1, borderWidth: 1, borderColor: t.line || "#e5e7eb", borderRadius: 10,
      paddingHorizontal: 12, paddingVertical: 10, fontSize: 15,
      color: t.text || "#111827", backgroundColor: t.surface || "#ffffff"
    },
    add: {
      paddingHorizontal: 16, justifyContent: "center", borderRadius: 10,
      backgroundColor: t.accent || "#2563eb"
    },
    addLabel: { color: t.onAccent || "#ffffff", fontWeight: "700" },
    tab: { paddingHorizontal: 14, paddingBottom: 6 },
    tabLabel: { color: t.accent || "#2563eb", fontWeight: "600", fontSize: 13 },
    row: {
      flexDirection: "row", alignItems: "center", gap: 6,
      paddingHorizontal: 12, paddingVertical: 10,
      borderBottomWidth: 1, borderBottomColor: t.line || "#e5e7eb"
    },
    rowBusy: { opacity: 0.5 },
    tickArea: { flex: 1, flexDirection: "row", alignItems: "center", gap: 10 },
    tick: {
      width: 26, height: 26, borderRadius: 8, borderWidth: 2,
      borderColor: t.line || "#d1d5db", alignItems: "center", justifyContent: "center"
    },
    tickOn: { backgroundColor: t.accent || "#2563eb", borderColor: t.accent || "#2563eb" },
    tickMark: { color: t.onAccent || "#ffffff", fontSize: 11, fontWeight: "800" },
    titleArea: { flex: 1 },
    title: { fontSize: 15, color: t.text || "#111827" },
    done: { fontSize: 15, color: t.muted || "#6b7280", textDecorationLine: "line-through" },
    meta: { fontSize: 12, color: t.muted || "#6b7280", marginTop: 2 },
    action: { paddingHorizontal: 8, paddingVertical: 6 },
    actionLabel: { fontSize: 12, fontWeight: "600", color: t.muted || "#6b7280" },
    danger: { fontSize: 12, fontWeight: "600", color: t.danger || "#b3261e" },
    empty: { padding: 32, textAlign: "center", color: t.muted || "#6b7280" }
  });
