// The shell.
//
// This is the Base App for phones: it signs in against Auth on the domain, then
// shows one entry per module. A module that ships native code gets its own
// component; one that does not gets a WebView on the same UI the Base App
// frames in a browser. The fallback is not a lesser path, and the shell does
// not present it as one.
import React, { useMemo, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { WebView } from "react-native-webview";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";

import { screens } from "./modules.generated";
import config from "./siberian.config";

const Stack = createNativeStackNavigator();

// Every call a module makes is namespaced by path, and the path segment is what
// the Router uses to decide which module a request means. An app has no
// origins, so this is where the boundary is: at the door, not on the device.
function bridgeFor(screen) {
  return {
    domain: config.domain,
    capabilities: config.capabilities,
    call(path, options = {}) {
      const base = `${config.api.base_url}${screen.apiBase}`.replace(/\/$/, "");
      return fetch(`${base}/${String(path).replace(/^\//, "")}`, {
        credentials: "include",
        ...options
      });
    }
  };
}

function Home({ navigation }) {
  if (screens.length === 0) {
    return (
      <View style={styles.empty}>
        <Text style={styles.emptyTitle}>Nothing installed yet</Text>
        <Text style={styles.emptyBody}>
          Modules installed for {config.domain} appear here the next time this app is built.
        </Text>
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.list}>
      {screens.map((screen) => (
        <Pressable
          key={`${screen.module}:${screen.capability}`}
          style={styles.row}
          onPress={() => navigation.navigate(screen.capability)}
        >
          <Text style={styles.rowTitle}>{screen.title}</Text>
          <Text style={styles.rowMeta}>
            {screen.kind === "native" ? "native" : "web"}
            {screen.reason ? ` · ${screen.reason}` : ""}
          </Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

function WebScreen({ url }) {
  const [loading, setLoading] = useState(true);

  return (
    <View style={styles.fill}>
      <WebView
        source={{ uri: url }}
        sharedCookiesEnabled
        onLoadEnd={() => setLoading(false)}
        style={styles.fill}
      />
      {loading ? <ActivityIndicator style={styles.spinner} /> : null}
    </View>
  );
}

export default function App() {
  const routes = useMemo(() => screens, []);

  return (
    <NavigationContainer>
      <Stack.Navigator>
        <Stack.Screen name="Home" component={Home} options={{ title: config.domain }} />
        {routes.map((screen) => {
          const Component =
            screen.kind === "native" && screen.component
              ? (props) => <screen.component {...props} siberian={bridgeFor(screen)} />
              : () => <WebScreen url={screen.url} />;

          return (
            <Stack.Screen
              key={`${screen.module}:${screen.capability}`}
              name={screen.capability}
              component={Component}
              options={{ title: screen.title }}
            />
          );
        })}
      </Stack.Navigator>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  spinner: { position: "absolute", top: "50%", left: 0, right: 0 },
  list: { padding: 16, gap: 10 },
  row: { padding: 16, borderRadius: 12, backgroundColor: "#f3f4f6" },
  rowTitle: { fontSize: 16, fontWeight: "600" },
  rowMeta: { fontSize: 12, color: "#6b7280", marginTop: 4 },
  empty: { flex: 1, alignItems: "center", justifyContent: "center", padding: 32 },
  emptyTitle: { fontSize: 18, fontWeight: "600" },
  emptyBody: { fontSize: 14, color: "#6b7280", textAlign: "center", marginTop: 8 }
});
