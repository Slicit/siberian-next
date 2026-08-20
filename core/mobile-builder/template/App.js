// The shell.
//
// This is the Base App for phones: it shows one tab per feature, and a module
// that ships native code gets its own screen while one that does not gets a
// WebView on the same UI the Base App frames in a browser. The fallback is not
// a lesser path and the shell does not present it as one.
//
// The same file renders on the web through React Native for Web, which is what
// the preview is: not a mock of the app, the app.
import React, { useMemo } from "react";
import { ActivityIndicator, Platform, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { WebView } from "react-native-webview";
import { NavigationContainer } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";

import { screens } from "./modules.generated";
import config from "./siberian.config";

const Tab = createBottomTabNavigator();

// A tab bar stops being navigation somewhere around five. Everything installed
// is still reachable from Home, which is the one tab that is always there.
const MAX_TABS = 4;

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

// One header for every screen, so the way back is in the same place on all of
// them. On Home the left side is empty rather than a button that goes where you
// already are.
function TopBar({ route, navigation, options }) {
  const home = route.name === "Home";

  return (
    <View style={styles.top}>
      <View style={styles.topSide}>
        {!home ? (
          <Pressable onPress={() => navigation.navigate("Home")} style={styles.back}>
            <Text style={styles.backLabel}>‹ Home</Text>
          </Pressable>
        ) : null}
      </View>

      <Text style={styles.topTitle} numberOfLines={1}>
        {options?.title || route.name}
      </Text>

      <View style={styles.topSide} />
    </View>
  );
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
      <Text style={styles.lead}>{config.domain}</Text>

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
  const [loading, setLoading] = React.useState(true);

  // React Native for Web has no WebView. An iframe is the same thing on the
  // web, and pretending otherwise would leave the preview with a blank panel
  // exactly where a module without native code should appear.
  if (Platform.OS === "web") {
    return <View style={styles.fill}>{React.createElement("iframe", { src: url, style: { border: 0, width: "100%", height: "100%" } })}</View>;
  }

  return (
    <View style={styles.fill}>
      <WebView source={{ uri: url }} sharedCookiesEnabled onLoadEnd={() => setLoading(false)} style={styles.fill} />
      {loading ? <ActivityIndicator style={styles.spinner} /> : null}
    </View>
  );
}

function screenComponent(screen) {
  if (screen.kind === "native" && screen.component) {
    const Native = screen.component;
    return (props) => <Native {...props} siberian={bridgeFor(screen)} />;
  }

  return () => <WebScreen url={screen.url} />;
}

export default function App() {
  const tabs = useMemo(() => screens.slice(0, MAX_TABS), []);
  const rest = useMemo(() => screens.slice(MAX_TABS), []);

  return (
    <NavigationContainer>
      <Tab.Navigator
        screenOptions={{
          header: (props) => <TopBar {...props} />,
          tabBarActiveTintColor: "#2563eb",
          tabBarInactiveTintColor: "#6b7280",
          tabBarStyle: styles.tabBar,
          tabBarLabelStyle: styles.tabLabel
        }}
      >
        <Tab.Screen name="Home" component={Home} options={{ title: config.domain }} />

        {tabs.map((screen) => (
          <Tab.Screen
            key={`${screen.module}:${screen.capability}`}
            name={screen.capability}
            component={screenComponent(screen)}
            options={{ title: screen.title, tabBarLabel: screen.title }}
          />
        ))}

        {/* Past the tab bar's useful width, but still reachable from Home. */}
        {rest.map((screen) => (
          <Tab.Screen
            key={`${screen.module}:${screen.capability}`}
            name={screen.capability}
            component={screenComponent(screen)}
            options={{ title: screen.title, tabBarButton: () => null }}
          />
        ))}
      </Tab.Navigator>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  spinner: { position: "absolute", top: "50%", left: 0, right: 0 },
  top: {
    flexDirection: "row", alignItems: "center", paddingHorizontal: 12,
    paddingTop: Platform.OS === "web" ? 12 : 48, paddingBottom: 12,
    backgroundColor: "#ffffff", borderBottomWidth: 1, borderBottomColor: "#e5e7eb"
  },
  topSide: { width: 88, justifyContent: "center" },
  back: { paddingVertical: 4 },
  backLabel: { fontSize: 15, fontWeight: "600", color: "#2563eb" },
  topTitle: { flex: 1, textAlign: "center", fontSize: 16, fontWeight: "700" },
  tabBar: { borderTopColor: "#e5e7eb", backgroundColor: "#ffffff" },
  tabLabel: { fontSize: 11, fontWeight: "600" },
  lead: { fontSize: 13, color: "#6b7280", marginBottom: 6 },
  list: { padding: 16, gap: 10 },
  row: { padding: 16, borderRadius: 12, backgroundColor: "#f3f4f6" },
  rowTitle: { fontSize: 16, fontWeight: "600" },
  rowMeta: { fontSize: 12, color: "#6b7280", marginTop: 4 },
  empty: { flex: 1, alignItems: "center", justifyContent: "center", padding: 32 },
  emptyTitle: { fontSize: 18, fontWeight: "600" },
  emptyBody: { fontSize: 14, color: "#6b7280", textAlign: "center", marginTop: 8 }
});
