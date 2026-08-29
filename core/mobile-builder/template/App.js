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
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useColorScheme,
  View
} from "react-native";
import { WebView } from "react-native-webview";
import { NavigationContainer } from "@react-navigation/native";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";

import { screens } from "./modules.generated";
import config from "./siberian.config";

const Tab = createBottomTabNavigator();

// A tab bar stops being navigation somewhere around five. Everything installed
// is still reachable from Home, which is the one tab that is always there.
const MAX_TABS = 4;

// Which of the palettes to render in.
//
// Three things get a say, in this order.
//
// The query string, on the web only. That is how the Backoffice preview tries a
// theme on without a build. On a phone there is no address bar to reach it from,
// so honouring it there would be a setting with no way to change it.
//
// Then the phone's own light or dark setting, when the operator left that on. A
// theme here is a palette rather than a light-or-dark decision, so the chosen
// one is kept whenever its scheme matches: an app set to Meadow stays Meadow on
// every phone set to light, and only a phone asking for dark moves. The
// alternative is showing a light app to somebody who set their phone to dark at
// eleven at night.
//
// Then the theme the operator chose, which is the answer whenever nothing above
// had an opinion.
function activeThemeKey(deviceScheme) {
  if (Platform.OS === "web" && typeof window !== "undefined") {
    const asked = new URLSearchParams(window.location.search).get("theme");
    if (asked && config.themes && config.themes[asked]) return asked;
  }

  if (config.followDeviceScheme && deviceScheme && config.themes) {
    const chosen = config.themes[config.theme];
    if (chosen && chosen.scheme === deviceScheme) return config.theme;

    const match = Object.keys(config.themes).find(
      (key) => config.themes[key].scheme === deviceScheme
    );
    if (match) return match;
  }

  return config.theme;
}

function paletteFor(key) {
  const theme = (config.themes && config.themes[key]) || {};
  // Every field has a fallback, so a theme added with a missing colour renders
  // in something reasonable rather than in nothing. A blank screen is a worse
  // way to learn about a typo than an off palette.
  return {
    background: theme.background || "#f7f8fa",
    surface: theme.surface || "#ffffff",
    text: theme.text || "#111827",
    muted: theme.muted || "#6b7280",
    line: theme.line || "#e5e7eb",
    accent: theme.accent || "#2563eb",
    onAccent: theme.onAccent || "#ffffff",
    danger: theme.danger || "#b3261e",
    dangerSurface: theme.dangerSurface || "#fee2e2",
    scheme: theme.scheme || "light"
  };
}

function bridgeFor(screen, theme) {
  return {
    domain: config.domain,
    capabilities: config.capabilities,
    // A native screen draws in the app's colours rather than its own, which is
    // the difference between a module inside an app and a module beside one.
    theme,
    call(path, options = {}) {
      const base = `${config.api.base_url}${screen.apiBase}`.replace(/\/$/, "");
      return fetch(`${base}/${String(path).replace(/^\//, "")}`, {
        credentials: "include",
        ...options
      });
    }
  };
}

// A module's web face, told which colours to render in.
//
// Without this an embedded page is the one part of the app that ignores the
// theme, which is exactly where it is most obvious: a dark app with a white
// page in the middle of it. The palette travels as query parameters because a
// module's stylesheet already uses CSS variables, so applying them is a few
// lines rather than a redesign, and a module that ignores them still works.
function themedUrl(url, key, theme) {
  const separator = url.includes("?") ? "&" : "?";
  const parameters = new URLSearchParams({ theme: key });
  Object.keys(theme).forEach((field) => parameters.set(`theme_${field}`, theme[field]));
  return `${url}${separator}${parameters.toString()}`;
}

// One header for every screen, so the way back is in the same place on all of
// them. On Home the left side is empty rather than a button that goes where you
// already are.
function TopBar({ route, navigation, options, styles, theme }) {
  const home = route.name === "Home";

  return (
    <View style={styles.top}>
      <View style={styles.topSide}>
        {!home ? (
          <Pressable onPress={() => navigation.navigate("Home")} style={styles.back}>
            <Text style={styles.backLabel}>Home</Text>
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

function Home({ navigation, styles }) {
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
    <ScrollView contentContainerStyle={styles.list} style={styles.fill}>
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

function WebScreen({ url, styles, theme }) {
  const [loading, setLoading] = React.useState(true);

  // React Native for Web has no WebView. An iframe is the same thing on the
  // web, and pretending otherwise would leave the preview with a blank panel
  // exactly where a module without native code should appear.
  if (Platform.OS === "web") {
    return (
      <View style={styles.fill}>
        {React.createElement("iframe", {
          src: url,
          style: { border: 0, width: "100%", height: "100%", background: theme.background }
        })}
      </View>
    );
  }

  return (
    <View style={styles.fill}>
      <WebView source={{ uri: url }} sharedCookiesEnabled onLoadEnd={() => setLoading(false)} style={styles.fill} />
      {loading ? <ActivityIndicator style={styles.spinner} color={theme.accent} /> : null}
    </View>
  );
}

function screenComponent(screen, key, theme, styles) {
  if (screen.kind === "native" && screen.component) {
    const Native = screen.component;
    return (props) => <Native {...props} siberian={bridgeFor(screen, theme)} />;
  }

  const url = themedUrl(screen.url, key, theme);
  return () => <WebScreen url={url} styles={styles} theme={theme} />;
}

export default function App() {
  // Re-renders when somebody changes their phone from light to dark, which is
  // the whole reason this is a hook rather than a value read once at startup.
  const deviceScheme = useColorScheme();
  const key = activeThemeKey(deviceScheme);
  const theme = useMemo(() => paletteFor(key), [key]);
  const styles = useMemo(() => sheet(theme), [theme]);

  const tabs = useMemo(() => screens.slice(0, MAX_TABS), []);
  const rest = useMemo(() => screens.slice(MAX_TABS), []);

  // The navigator's own surfaces, so the frame around a screen is themed as
  // well as the screen. Without this a dark app has a white gap behind every
  // transition.
  const navigationTheme = useMemo(
    () => ({
      dark: theme.scheme === "dark",
      colors: {
        primary: theme.accent,
        background: theme.background,
        card: theme.surface,
        text: theme.text,
        border: theme.line,
        notification: theme.danger
      },
      fonts: {
        regular: { fontFamily: "System", fontWeight: "400" },
        medium: { fontFamily: "System", fontWeight: "500" },
        bold: { fontFamily: "System", fontWeight: "700" },
        heavy: { fontFamily: "System", fontWeight: "800" }
      }
    }),
    [theme]
  );

  return (
    <NavigationContainer theme={navigationTheme}>
      <Tab.Navigator
        screenOptions={{
          header: (props) => <TopBar {...props} styles={styles} theme={theme} />,
          tabBarActiveTintColor: theme.accent,
          tabBarInactiveTintColor: theme.muted,
          tabBarStyle: styles.tabBar,
          tabBarLabelStyle: styles.tabLabel,
          sceneContainerStyle: { backgroundColor: theme.background }
        }}
      >
        <Tab.Screen name="Home" options={{ title: config.domain }}>
          {(props) => <Home {...props} styles={styles} />}
        </Tab.Screen>

        {tabs.map((screen) => (
          <Tab.Screen
            key={`${screen.module}:${screen.capability}`}
            name={screen.capability}
            component={screenComponent(screen, key, theme, styles)}
            options={{ title: screen.title, tabBarLabel: screen.title }}
          />
        ))}

        {/* Past the tab bar's useful width, but still reachable from Home. */}
        {rest.map((screen) => (
          <Tab.Screen
            key={`${screen.module}:${screen.capability}`}
            name={screen.capability}
            component={screenComponent(screen, key, theme, styles)}
            options={{ title: screen.title, tabBarButton: () => null }}
          />
        ))}
      </Tab.Navigator>
    </NavigationContainer>
  );
}

const sheet = (t) =>
  StyleSheet.create({
    fill: { flex: 1, backgroundColor: t.background },
    spinner: { position: "absolute", top: "50%", left: 0, right: 0 },
    top: {
      flexDirection: "row", alignItems: "center", paddingHorizontal: 12,
      paddingTop: Platform.OS === "web" ? 12 : 48, paddingBottom: 12,
      backgroundColor: t.surface, borderBottomWidth: 1, borderBottomColor: t.line
    },
    topSide: { width: 88, justifyContent: "center" },
    back: { paddingVertical: 4 },
    backLabel: { fontSize: 15, fontWeight: "600", color: t.accent },
    topTitle: { flex: 1, textAlign: "center", fontSize: 16, fontWeight: "700", color: t.text },
    tabBar: { borderTopColor: t.line, backgroundColor: t.surface },
    tabLabel: { fontSize: 11, fontWeight: "600" },
    lead: { fontSize: 13, color: t.muted, marginBottom: 6 },
    list: { padding: 16, gap: 10 },
    row: { padding: 16, borderRadius: 12, backgroundColor: t.surface, borderWidth: 1, borderColor: t.line },
    rowTitle: { fontSize: 16, fontWeight: "600", color: t.text },
    rowMeta: { fontSize: 12, color: t.muted, marginTop: 4 },
    empty: { flex: 1, alignItems: "center", justifyContent: "center", padding: 32, backgroundColor: t.background },
    emptyTitle: { fontSize: 18, fontWeight: "600", color: t.text },
    emptyBody: { fontSize: 14, color: t.muted, textAlign: "center", marginTop: 8 }
  });
