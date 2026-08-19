// The native half of the demo module.
//
// What it demonstrates is the contract, not the to-do list. It receives a
// `siberian` bridge from the shell, calls its own API through it, and never
// learns a container name, a domain credential, or another module's anything.
//
// Every call goes to /m/demo-tasks/, which the Router turns into this module.
// The app has no origins, so that path, and the permission behind it, is the
// boundary.
import React, { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, TextInput, View } from "react-native";

export function TaskList({ siberian }) {
  const [tasks, setTasks] = useState(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const response = await siberian.call("tasks.json");
      if (!response.ok) throw new Error(`the module answered ${response.status}`);
      setTasks(await response.json());
      setError(null);
    } catch (problem) {
      // Said plainly rather than swallowed. A list that is empty because the
      // call failed looks exactly like a list that is empty.
      setError(problem.message);
      setTasks([]);
    }
  }, [siberian]);

  useEffect(() => {
    load();
  }, [load]);

  const add = async () => {
    if (!draft.trim()) return;
    await siberian.call("tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: draft })
    });
    setDraft("");
    load();
  };

  if (tasks === null) return <ActivityIndicator style={styles.centre} />;

  return (
    <View style={styles.fill}>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      <View style={styles.composer}>
        <TextInput
          style={styles.input}
          value={draft}
          onChangeText={setDraft}
          placeholder="Add a task"
          onSubmitEditing={add}
        />
        <Pressable style={styles.add} onPress={add}>
          <Text style={styles.addLabel}>Add</Text>
        </Pressable>
      </View>

      <FlatList
        data={tasks}
        keyExtractor={(task) => String(task.id)}
        ListEmptyComponent={<Text style={styles.empty}>Nothing yet.</Text>}
        renderItem={({ item }) => (
          <View style={styles.row}>
            <Text style={item.done ? styles.done : styles.title}>{item.title}</Text>
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  centre: { flex: 1, justifyContent: "center" },
  composer: { flexDirection: "row", padding: 12, gap: 8 },
  input: { flex: 1, borderWidth: 1, borderColor: "#d1d5db", borderRadius: 8, paddingHorizontal: 12, paddingVertical: 8 },
  add: { paddingHorizontal: 16, justifyContent: "center", backgroundColor: "#2563eb", borderRadius: 8 },
  addLabel: { color: "white", fontWeight: "600" },
  row: { paddingHorizontal: 16, paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: "#f3f4f6" },
  title: { fontSize: 15 },
  done: { fontSize: 15, textDecorationLine: "line-through", color: "#9ca3af" },
  empty: { padding: 24, textAlign: "center", color: "#6b7280" },
  error: { padding: 12, backgroundColor: "#fef2f2", color: "#991b1b" }
});
