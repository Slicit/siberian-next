// The native face of the CMS.
//
// Navigation and a page, reading the same API the web UI writes to. It never
// learns a container name, a domain credential, or where the module actually
// runs: every call goes through the bridge the shell hands it, which the
// Router turns into this module and authorises as the person holding the phone.
import React, { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View
} from "react-native";

import { Block } from "./blocks";

export function PageNavigator({ siberian }) {
  const [pages, setPages] = useState(null);
  const [slug, setSlug] = useState(null);
  const [error, setError] = useState(null);

  const loadPages = useCallback(async () => {
    try {
      const response = await siberian.call("api/pages");
      if (!response.ok) throw new Error(`the module answered ${response.status}`);

      const payload = await response.json();
      setPages(payload.pages || []);
      setError(null);
    } catch (problem) {
      // Said plainly rather than swallowed. An empty list because the call
      // failed looks exactly like an empty list.
      setError(problem.message);
      setPages([]);
    }
  }, [siberian]);

  useEffect(() => {
    loadPages();
  }, [loadPages]);

  if (pages === null) return <ActivityIndicator style={styles.centre} />;

  if (slug) {
    return <PageView siberian={siberian} slug={slug} onBack={() => setSlug(null)} />;
  }

  return (
    <View style={styles.fill}>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      <FlatList
        data={pages}
        keyExtractor={(page) => page.slug}
        refreshControl={<RefreshControl refreshing={false} onRefresh={loadPages} />}
        ListEmptyComponent={<Text style={styles.empty}>No pages have been published yet.</Text>}
        renderItem={({ item }) => (
          <Pressable style={styles.row} onPress={() => setSlug(item.slug)}>
            <Text style={styles.rowTitle}>{item.title}</Text>
            <Text style={styles.chevron}>›</Text>
          </Pressable>
        )}
      />
    </View>
  );
}

export function PageView({ siberian, slug, onBack }) {
  const [page, setPage] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const response = await siberian.call(`api/pages/${encodeURIComponent(slug)}`);
      if (!response.ok) throw new Error(`the module answered ${response.status}`);

      const payload = await response.json();
      setPage(payload.page);
      setBlocks(payload.blocks || []);
      setError(null);
    } catch (problem) {
      setError(problem.message);
      setPage({ title: slug });
    }
  }, [siberian, slug]);

  useEffect(() => {
    load();
  }, [load]);

  if (page === null) return <ActivityIndicator style={styles.centre} />;

  return (
    <ScrollView
      style={styles.fill}
      contentContainerStyle={styles.page}
      refreshControl={<RefreshControl refreshing={false} onRefresh={load} />}
    >
      <Pressable onPress={onBack} style={styles.back}>
        <Text style={styles.backLabel}>‹ Pages</Text>
      </Pressable>

      <Text style={styles.heading}>{page.title}</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      {blocks.length === 0 && !error ? (
        <Text style={styles.empty}>This page has no blocks yet.</Text>
      ) : (
        blocks.map((block) => <Block key={block.id} block={block} />)
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  centre: { flex: 1, justifyContent: "center" },
  page: { padding: 16, paddingBottom: 48 },
  back: { paddingVertical: 6 },
  backLabel: { fontSize: 15, color: "#2563eb", fontWeight: "600" },
  heading: { fontSize: 26, fontWeight: "700", marginTop: 4, marginBottom: 12 },
  row: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: 1,
    borderBottomColor: "#f3f4f6"
  },
  rowTitle: { flex: 1, fontSize: 16, fontWeight: "500" },
  chevron: { fontSize: 20, color: "#9ca3af" },
  empty: { padding: 24, textAlign: "center", color: "#6b7280" },
  error: { padding: 12, backgroundColor: "#fef2f2", color: "#991b1b", borderRadius: 8, marginBottom: 12 }
});
