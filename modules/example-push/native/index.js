// The notification inbox, natively.
//
// Read, archive, and delete are three different things and the screen keeps
// them apart: read is "I have seen this", archive is "I am done with it but it
// happened", and only delete loses anything. The confirmation is on the one
// that does.
import React, { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View
} from "react-native";

import { usePushRegistration, useIncoming } from "./notifications";

export function NotificationInbox({ siberian }) {
  const [notes, setNotes] = useState(null);
  const [archived, setArchived] = useState(false);
  const [error, setError] = useState(null);
  const registration = usePushRegistration(siberian);

  const load = useCallback(async () => {
    try {
      const response = await siberian.call(`api/notifications?state=${archived ? "archived" : "inbox"}`);
      if (!response.ok) throw new Error(`the module answered ${response.status}`);

      const payload = await response.json();
      setNotes(payload.notifications || []);
      setError(null);
    } catch (problem) {
      setError(problem.message);
      setNotes([]);
    }
  }, [siberian, archived]);

  useEffect(() => {
    load();
  }, [load]);

  // Arriving is not the same as being fetched: the list is stale the moment
  // something lands, so it reloads rather than guessing what changed.
  useIncoming(useCallback(() => load(), [load]));

  const act = async (id, path, method = "POST") => {
    await siberian.call(`api/notifications/${id}${path}`, { method });
    load();
  };

  const remove = (note) =>
    Alert.alert("Delete this notification?", "Archiving keeps it. Deleting does not.", [
      { text: "Cancel", style: "cancel" },
      { text: "Delete", style: "destructive", onPress: () => act(note.id, "", "DELETE") }
    ]);

  if (notes === null) return <ActivityIndicator style={styles.centre} />;

  return (
    <View style={styles.fill}>
      <Registration state={registration} />

      <View style={styles.tabs}>
        <Tab label="Inbox" on={!archived} onPress={() => setArchived(false)} />
        <Tab label="Archived" on={archived} onPress={() => setArchived(true)} />
      </View>

      {error ? <Text style={styles.error}>{error}</Text> : null}

      <FlatList
        data={notes}
        keyExtractor={(note) => String(note.id)}
        refreshControl={<RefreshControl refreshing={false} onRefresh={load} />}
        ListEmptyComponent={
          <Text style={styles.empty}>{archived ? "Nothing archived." : "No notifications."}</Text>
        }
        renderItem={({ item }) => (
          <NotificationRow
            note={item}
            archived={archived}
            onRead={() => act(item.id, item.read ? "/unread" : "/read")}
            onArchive={() => act(item.id, archived ? "/unarchive" : "/archive")}
            onDelete={() => remove(item)}
          />
        )}
      />
    </View>
  );
}

export function NotificationRow({ note, archived, onRead, onArchive, onDelete }) {
  return (
    <View style={[styles.row, !note.read && styles.unread]}>
      <Text style={styles.title}>{note.title}</Text>
      {note.body ? <Text style={styles.body}>{note.body}</Text> : null}

      <View style={styles.actions}>
        <Text style={styles.when}>{(note.created_at || "").slice(0, 16).replace("T", " ")}</Text>
        <View style={styles.grow} />
        {!archived ? (
          <Action label={note.read ? "Unread" : "Read"} onPress={onRead} />
        ) : null}
        <Action label={archived ? "Inbox" : "Archive"} onPress={onArchive} />
        <Action label="Delete" onPress={onDelete} destructive />
      </View>
    </View>
  );
}

// What the operating system said, in the one place somebody would look for it.
// A screen that silently never registers is a screen that looks like it works.
function Registration({ state }) {
  if (state.status === "registered") return null;

  const message = {
    asking: "Asking whether this app may notify you...",
    declined: state.detail,
    failed: `This device could not register: ${state.detail}`
  }[state.status];

  return (
    <Pressable style={styles.banner} onPress={state.retry}>
      <Text style={styles.bannerText}>{message}</Text>
      {state.status !== "asking" ? <Text style={styles.bannerHint}>Tap to try again</Text> : null}
    </Pressable>
  );
}

function Tab({ label, on, onPress }) {
  return (
    <Pressable style={[styles.tab, on && styles.tabOn]} onPress={onPress}>
      <Text style={[styles.tabLabel, on && styles.tabLabelOn]}>{label}</Text>
    </Pressable>
  );
}

function Action({ label, onPress, destructive }) {
  return (
    <Pressable style={styles.action} onPress={onPress}>
      <Text style={[styles.actionLabel, destructive && styles.destructive]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  centre: { flex: 1, justifyContent: "center" },
  grow: { flex: 1 },
  banner: { padding: 12, backgroundColor: "#fef3c7", borderRadius: 8, margin: 12 },
  bannerText: { color: "#92400e", fontSize: 14 },
  bannerHint: { color: "#92400e", fontSize: 12, marginTop: 4, fontWeight: "600" },
  tabs: { flexDirection: "row", gap: 8, paddingHorizontal: 12, paddingBottom: 8 },
  tab: { paddingHorizontal: 14, paddingVertical: 6, borderRadius: 999, backgroundColor: "#f3f4f6" },
  tabOn: { backgroundColor: "#2563eb" },
  tabLabel: { fontWeight: "600", color: "#374151" },
  tabLabelOn: { color: "#fff" },
  row: { paddingHorizontal: 16, paddingVertical: 12, borderBottomWidth: 1, borderBottomColor: "#f3f4f6" },
  unread: { backgroundColor: "#eff6ff" },
  title: { fontSize: 16, fontWeight: "600" },
  body: { fontSize: 14, color: "#4b5563", marginTop: 2 },
  actions: { flexDirection: "row", alignItems: "center", marginTop: 8, gap: 12 },
  when: { fontSize: 12, color: "#9ca3af" },
  action: { paddingVertical: 4 },
  actionLabel: { fontSize: 13, fontWeight: "600", color: "#2563eb" },
  destructive: { color: "#b3261e" },
  empty: { padding: 24, textAlign: "center", color: "#6b7280" },
  error: { margin: 12, padding: 12, backgroundColor: "#fef2f2", color: "#991b1b", borderRadius: 8 }
});
